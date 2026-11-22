#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
SSH_OPTS="-i $PWD/lab_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -o LogLevel=ERROR"

if [[ "${1:-}" != "--configure-only" ]]; then
    echo "=== [1/5] Подготовка базового образа Debian 12 и сети libvirt ==="
    sudo virsh net-destroy default >/dev/null 2>&1 || true
    sudo virsh net-undefine default >/dev/null 2>&1 || true
    sudo rm -f /var/lib/libvirt/dnsmasq/virbr0.*

    cat << 'NETXML' > default-net.xml
<network>
  <name>default</name>
  <forward mode='nat'/>
  <bridge name='virbr0' stp='on' delay='0'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.122.100' end='192.168.122.254'/>
      <host mac='52:54:00:00:00:11' name='pg-node1' ip='192.168.122.11'/>
      <host mac='52:54:00:00:00:12' name='pg-node2' ip='192.168.122.12'/>
      <host mac='52:54:00:00:00:13' name='pg-node3' ip='192.168.122.13'/>
    </dhcp>
  </ip>
</network>
NETXML

    sudo virsh net-define default-net.xml >/dev/null
    sudo virsh net-start default >/dev/null
    sudo virsh net-autostart default >/dev/null
    rm -f default-net.xml

    sudo iptables -C INPUT -i virbr0 -j ACCEPT 2>/dev/null || sudo iptables -I INPUT -i virbr0 -j ACCEPT
    sudo iptables -C FORWARD -i virbr0 -j ACCEPT 2>/dev/null || sudo iptables -I FORWARD -i virbr0 -j ACCEPT
    sudo iptables -C FORWARD -o virbr0 -j ACCEPT 2>/dev/null || sudo iptables -I FORWARD -o virbr0 -j ACCEPT

    # Даем права прохода пользователю libvirt-qemu по всей цепочке каталогов
    setfacl -m u:libvirt-qemu:x "$HOME" "$(dirname "$(dirname "$PWD")")" "$(dirname "$PWD")" "$PWD" 2>/dev/null || true

    if [ ! -f debian-12-base.qcow2 ]; then
        wget -q --show-progress -O debian-12-base.qcow2 \
            https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2
        qemu-img resize -q debian-12-base.qcow2 8G
    fi
    chmod 444 debian-12-base.qcow2
    setfacl -m u:libvirt-qemu:r debian-12-base.qcow2

    if [ ! -f lab_key ]; then
        ssh-keygen -q -t ed25519 -N "" -f lab_key -C "pg18-lab"
    fi
    PUBKEY=$(cat lab_key.pub)

    echo "=== [2/5] Создание и запуск 3 виртуальных машин (по 512 МБ ОЗУ) ==="
    for i in 1 2 3; do
        NODE="pg-node${i}"
        IP="192.168.122.1${i}"
        MAC="52:54:00:00:00:1${i}"

        sudo virsh destroy "$NODE" >/dev/null 2>&1 || true
        sudo virsh undefine "$NODE" --nvram >/dev/null 2>&1 || true
        rm -f "${NODE}.qcow2" "seed-${i}.img"

        qemu-img create -q -f qcow2 -F qcow2 -b "$PWD/debian-12-base.qcow2" "${NODE}.qcow2"
        setfacl -m u:libvirt-qemu:rw "${NODE}.qcow2"

        mkdir -p "cidata-${i}"
        printf 'instance-id: %s\nlocal-hostname: %s\n' "${NODE}-v1" "${NODE}" > "cidata-${i}/meta-data"

        printf '%s\n' \
            "#cloud-config" \
            "hostname: ${NODE}" \
            "fqdn: ${NODE}" \
            "disable_root: false" \
            "ssh_authorized_keys:" \
            "  - ${PUBKEY}" \
            "users:" \
            "  - default" \
            "  - name: root" \
            "    ssh_authorized_keys:" \
            "      - ${PUBKEY}" \
            "runcmd:" \
            "  - mkdir -p /root/.ssh" \
            "  - echo '${PUBKEY}' > /root/.ssh/authorized_keys" \
            "  - chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys" \
            "  - sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config" \
            "  - systemctl restart ssh" > "cidata-${i}/user-data"

        # Создаем постоянный FAT-диск cidata (не требует cdrtools/xorriso, работает на любом Linux из коробки)
        truncate -s 2M "seed-${i}.img"
        mkfs.vfat -n CIDATA "seed-${i}.img" >/dev/null
        mcopy -i "seed-${i}.img" "cidata-${i}/user-data" "cidata-${i}/meta-data" ::/ 2>/dev/null || {
            mkdir -p "mnt-${i}"
            sudo mount -o loop "seed-${i}.img" "mnt-${i}"
            sudo cp "cidata-${i}/user-data" "cidata-${i}/meta-data" "mnt-${i}/"
            sudo umount "mnt-${i}"
            rmdir "mnt-${i}"
        }
        rm -rf "cidata-${i}"
        setfacl -m u:libvirt-qemu:r "seed-${i}.img"

        sudo virt-install \
            --quiet \
            --name "$NODE" \
            --memory 512 \
            --vcpus 1 \
            --disk "path=$PWD/${NODE}.qcow2,format=qcow2" \
            --disk "path=$PWD/seed-${i}.img,format=raw,readonly=on" \
            --os-variant debian12 \
            --network "network=default,mac=${MAC},model=virtio" \
            --graphics none \
            --noautoconsole \
            --import >/dev/null
        echo "  -> Виртуальная машина $NODE ($IP) запущена"
    done
else
    echo "=== Включение существующих ВМ ==="
    sudo virsh net-start default >/dev/null 2>&1 || true
    for i in 1 2 3; do
        sudo virsh start "pg-node${i}" >/dev/null 2>&1 || true
    done
fi

echo "=== [3/5] Ожидание готовности SSH ==="
for i in 1 2 3; do
    IP="192.168.122.1${i}"
    echo -n "  -> Ждем $IP "
    until ssh $SSH_OPTS root@$IP "true" 2>/dev/null || ssh $SSH_OPTS debian@$IP "sudo cp /home/debian/.ssh/authorized_keys /root/.ssh/authorized_keys" 2>/dev/null; do
        echo -n "."
        sleep 2
    done
    echo " ОК"
done

echo "=== [4/5] Установка пакетов (PostgreSQL 18, Patroni, etcd, HAProxy) ==="
echo "  -> Скачивание и установка на pg-node1..."
ssh $SSH_OPTS root@192.168.122.11 "bash -s" << 'EOF'
set -e
export DEBIAN_FRONTEND=noninteractive
if ! command -v patroni >/dev/null; then
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates gnupg lsb-release iptables >/dev/null
    install -d /usr/share/postgresql-common/pgdg
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list
    apt-get update -qq
    apt-get install -y -qq -o APT::Keep-Downloaded-Packages=true \
        postgresql-18 patroni etcd-server etcd-client haproxy python3-psycopg2 python3-etcd3 >/dev/null
fi
systemctl stop patroni haproxy etcd postgresql 2>/dev/null || true
systemctl disable postgresql >/dev/null 2>&1 || true
pg_dropcluster 18 main --stop >/dev/null 2>&1 || true
EOF

for i in 2 3; do
    IP="192.168.122.1${i}"
    echo "  -> Локальная установка пакетов на pg-node${i} ($IP)..."
    ssh $SSH_OPTS root@192.168.122.11 "tar -cf - /etc/apt/sources.list.d/pgdg.list /usr/share/postgresql-common/pgdg /var/lib/apt/lists /var/cache/apt/archives 2>/dev/null" \
      | ssh $SSH_OPTS root@$IP "tar -xf - -C /"

    ssh $SSH_OPTS root@$IP "bash -s" << 'EOF'
set -e
export DEBIAN_FRONTEND=noninteractive
if ! command -v patroni >/dev/null; then
    apt-get install -y -qq --no-download \
        curl ca-certificates gnupg lsb-release iptables \
        postgresql-18 patroni etcd-server etcd-client haproxy python3-psycopg2 python3-etcd3 >/dev/null 2>&1 || \
    apt-get install -y -qq \
        postgresql-18 patroni etcd-server etcd-client haproxy python3-psycopg2 python3-etcd3 iptables >/dev/null
fi
systemctl stop patroni haproxy etcd postgresql 2>/dev/null || true
systemctl disable postgresql >/dev/null 2>&1 || true
pg_dropcluster 18 main --stop >/dev/null 2>&1 || true
EOF
done

echo "=== [5/5] Настройка и запуск кластера (etcd + Patroni + HAProxy) ==="
for i in 1 2 3; do
    NODE="pg-node${i}"
    IP="192.168.122.1${i}"
    ssh $SSH_OPTS root@$IP "bash -s -- $NODE $IP" << 'EOF'
set -e
NODE="$1"
IP="$2"

systemctl stop patroni haproxy etcd 2>/dev/null || true
rm -rf /var/lib/etcd/* /var/lib/postgresql/18/patroni

cat <<ETCD > /etc/default/etcd
ETCD_NAME="${NODE}"
ETCD_DATA_DIR="/var/lib/etcd/default.etcd"
ETCD_LISTEN_PEER_URLS="http://${IP}:2380"
ETCD_LISTEN_CLIENT_URLS="http://${IP}:2379,http://127.0.0.1:2379"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://${IP}:2380"
ETCD_ADVERTISE_CLIENT_URLS="http://${IP}:2379"
ETCD_INITIAL_CLUSTER="pg-node1=http://192.168.122.11:2380,pg-node2=http://192.168.122.12:2380,pg-node3=http://192.168.122.13:2380"
ETCD_INITIAL_CLUSTER_TOKEN="pg18-cluster"
ETCD_INITIAL_CLUSTER_STATE="new"
ETCD_QUOTA_BACKEND_BYTES="67108864"
ETCD

systemctl enable etcd >/dev/null 2>&1
systemctl start --no-block etcd

mkdir -p /etc/patroni /var/lib/postgresql/18/patroni
chown -R postgres:postgres /etc/patroni /var/lib/postgresql
chmod 700 /var/lib/postgresql/18/patroni

cat <<PATRONI > /etc/patroni/config.yml
scope: pg18-ha
namespace: /service
name: ${NODE}

restapi:
  listen: ${IP}:8008
  connect_address: ${IP}:8008

etcd3:
  hosts:
    - 192.168.122.11:2379
    - 192.168.122.12:2379
    - 192.168.122.13:2379

bootstrap:
  dcs:
    ttl: 20
    loop_wait: 2
    retry_timeout: 5
    maximum_lag_on_failover: 1048576
    synchronous_mode: true
    synchronous_mode_strict: false
    synchronous_node_count: 1
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        max_connections: 40
        shared_buffers: 64MB
        work_mem: 4MB
        wal_level: replica
        hot_standby: "on"
        wal_keep_size: 64MB
        wal_log_hints: "on"

  initdb:
    - encoding: UTF8
    - locale: C.UTF-8
    - data-checksums

  pg_hba:
    - local all all trust
    - host replication replicator 127.0.0.1/32 scram-sha-256
    - host replication replicator 192.168.122.0/24 scram-sha-256
    - host all all 0.0.0.0/0 scram-sha-256

postgresql:
  listen: 0.0.0.0:5432
  connect_address: ${IP}:5432
  data_dir: /var/lib/postgresql/18/patroni
  bin_dir: /usr/lib/postgresql/18/bin
  authentication:
    replication:
      username: replicator
      password: RepPass18
    superuser:
      username: postgres
      password: PgPass18
PATRONI

chown postgres:postgres /etc/patroni/config.yml
chmod 600 /etc/patroni/config.yml

cat <<HAPROXY > /etc/haproxy/haproxy.cfg
global
    maxconn 200

defaults
    mode tcp
    retries 2
    timeout client 10m
    timeout connect 2s
    timeout server 10m
    timeout check 1s

listen pg_rw
    bind 0.0.0.0:5000
    option httpchk GET /primary
    http-check expect status 200
    default-server inter 1s fall 2 rise 2 on-marked-down shutdown-sessions
    server pg-node1 192.168.122.11:5432 check port 8008
    server pg-node2 192.168.122.12:5432 check port 8008
    server pg-node3 192.168.122.13:5432 check port 8008

listen pg_ro
    bind 0.0.0.0:5001
    balance roundrobin
    option httpchk GET /replica
    http-check expect status 200
    default-server inter 1s fall 2 rise 2
    server pg-node1 192.168.122.11:5432 check port 8008
    server pg-node2 192.168.122.12:5432 check port 8008
    server pg-node3 192.168.122.13:5432 check port 8008
HAPROXY

systemctl enable patroni haproxy >/dev/null 2>&1
systemctl start --no-block patroni haproxy
EOF
    echo "  -> Сервисы на $NODE запущены"
done

echo -n "=== Ожидание инициализации лидера и реплик PostgreSQL 18 "
for _ in {1..30}; do
    OUT=$(ssh $SSH_OPTS root@192.168.122.11 "patronictl -c /etc/patroni/config.yml list" 2>/dev/null || true)
    if echo "$OUT" | grep -q "Leader" && [ "$(echo "$OUT" | grep -c "streaming")" -eq 2 ]; then
        echo " ОК ==="
        break
    fi
    echo -n "."
    sleep 2
done

echo ""
ssh $SSH_OPTS root@192.168.122.11 "patronictl -c /etc/patroni/config.yml list"
