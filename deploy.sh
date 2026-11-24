#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Конфигурация стенда
# ==============================================================================
WORK_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$WORK_DIR"

BASE_IMAGE="debian-12-generic-base.qcow2"
BASE_IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
SSH_KEY="${WORK_DIR}/lab_key"

SSH_OPTIONS=(
    -i "$SSH_KEY"
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=3
    -o LogLevel=ERROR
)

# Узлы баз данных (PostgreSQL 18 + Patroni + etcd + Watchdog)
DB_NAMES=("pg-node1" "pg-node2" "pg-node3")
DB_IPS=("192.168.122.11" "192.168.122.12" "192.168.122.13")
DB_MACS=("52:54:00:00:00:11" "52:54:00:00:00:12" "52:54:00:00:00:13")
DB_RAM_MB=512

# Выделенные узлы балансировки (HAProxy)
LB_NAMES=("lb-node1" "lb-node2")
LB_IPS=("192.168.122.21" "192.168.122.22")
LB_MACS=("52:54:00:00:00:21" "52:54:00:00:00:22")
LB_RAM_MB=384

# Учетные данные PostgreSQL
PG_SUPER_PASS="PgPass18"
PG_REPL_PASS="RepPass18"
PG_REWIND_PASS="RewPass18"
APP_USER="appuser"
APP_PASS="AppPass18"
APP_DB="appdb"

# ==============================================================================
# Вспомогательные функции
# ==============================================================================

grant_qemu_access() {
    # Даем пользователю libvirt-qemu право прохода к рабочему каталогу
    local current_dir="$WORK_DIR"
    while [[ "$current_dir" != "/" ]]; do
        setfacl -m u:libvirt-qemu:x "$current_dir" 2>/dev/null || true
        current_dir="$(dirname "$current_dir")"
    done
}

remove_vm_if_exists() {
    local vm_name="$1"
    if sudo virsh dominfo "$vm_name" >/dev/null 2>&1; then
        sudo virsh destroy "$vm_name" >/dev/null 2>&1 || true
        sudo virsh undefine "$vm_name" --nvram >/dev/null 2>&1 || true
    fi
}

setup_libvirt_network() {
    echo "=== [1/6] Настройка сети libvirt и базового образа Debian 12 ==="

    sudo virsh net-destroy default >/dev/null 2>&1 || true
    sudo virsh net-undefine default >/dev/null 2>&1 || true
    sudo rm -f /var/lib/libvirt/dnsmasq/virbr0.*

    cat << 'EOF' > default-net.xml
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
      <host mac='52:54:00:00:00:21' name='lb-node1' ip='192.168.122.21'/>
      <host mac='52:54:00:00:00:22' name='lb-node2' ip='192.168.122.22'/>
    </dhcp>
  </ip>
</network>
EOF

    sudo virsh net-define default-net.xml >/dev/null
    sudo virsh net-start default >/dev/null
    sudo virsh net-autostart default >/dev/null
    rm -f default-net.xml

    # Разрешаем прохождение трафика на мосту virbr0
    if ! sudo iptables -C INPUT -i virbr0 -j ACCEPT 2>/dev/null; then
        sudo iptables -I INPUT -i virbr0 -j ACCEPT
    fi
    if ! sudo iptables -C FORWARD -i virbr0 -j ACCEPT 2>/dev/null; then
        sudo iptables -I FORWARD -i virbr0 -j ACCEPT
    fi
    if ! sudo iptables -C FORWARD -o virbr0 -j ACCEPT 2>/dev/null; then
        sudo iptables -I FORWARD -o virbr0 -j ACCEPT
    fi
}

prepare_base_image_and_keys() {
    grant_qemu_access

    if [[ ! -f "$BASE_IMAGE" ]]; then
        echo "  -> Скачивание базового образа Debian 12 (generic)..."
        wget -q --show-progress -O "$BASE_IMAGE" "$BASE_IMAGE_URL"
        qemu-img resize -q "$BASE_IMAGE" 8G
    fi
    chmod 444 "$BASE_IMAGE"
    setfacl -m u:libvirt-qemu:r "$BASE_IMAGE"

    if [[ ! -f "$SSH_KEY" ]]; then
        ssh-keygen -q -t ed25519 -N "" -f "$SSH_KEY" -C "pg18-ha-lab"
    fi
}

create_cloud_init_disk() {
    local node_name="$1"
    local seed_img="${WORK_DIR}/seed-${node_name}.img"
    local temp_dir="${WORK_DIR}/cidata-${node_name}"
    local pubkey
    pubkey="$(cat "${SSH_KEY}.pub")"

    rm -rf "$temp_dir" "$seed_img"
    mkdir -p "$temp_dir"

    cat << EOF > "${temp_dir}/meta-data"
instance-id: ${node_name}-v1
local-hostname: ${node_name}
EOF

    cat << EOF > "${temp_dir}/user-data"
#cloud-config
hostname: ${node_name}
fqdn: ${node_name}
disable_root: false
ssh_authorized_keys:
  - ${pubkey}
users:
  - default
  - name: root
    ssh_authorized_keys:
      - ${pubkey}
runcmd:
  - mkdir -p /root/.ssh
  - echo '${pubkey}' > /root/.ssh/authorized_keys
  - chmod 700 /root/.ssh
  - chmod 600 /root/.ssh/authorized_keys
  - sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  - systemctl restart ssh
EOF

    truncate -s 2M "$seed_img"
    mkfs.vfat -n CIDATA "$seed_img" >/dev/null

    if command -v mcopy >/dev/null 2>&1; then
        mcopy -i "$seed_img" "${temp_dir}/user-data" "${temp_dir}/meta-data" ::/
    else
        local mount_dir="${WORK_DIR}/mnt-${node_name}"
        mkdir -p "$mount_dir"
        sudo mount -o loop "$seed_img" "$mount_dir"
        sudo cp "${temp_dir}/user-data" "${temp_dir}/meta-data" "$mount_dir/"
        sudo umount "$mount_dir"
        rmdir "$mount_dir"
    fi

    rm -rf "$temp_dir"
    setfacl -m u:libvirt-qemu:r "$seed_img"
}

create_db_vm() {
    local node_name="$1"
    local ip="$2"
    local mac="$3"

    local root_disk="${WORK_DIR}/${node_name}.qcow2"
    local etcd_disk="${WORK_DIR}/${node_name}-etcd.qcow2"
    local seed_img="${WORK_DIR}/seed-${node_name}.img"

    remove_vm_if_exists "$node_name"
    rm -f "$root_disk" "$etcd_disk"

    # Основной диск системы и PostgreSQL
    qemu-img create -q -f qcow2 -F qcow2 -b "${WORK_DIR}/${BASE_IMAGE}" "$root_disk"
    setfacl -m u:libvirt-qemu:rw "$root_disk"

    # Отдельный диск под данные etcd, чтобы снизить конкуренцию I/O с WAL
    qemu-img create -q -f qcow2 "$etcd_disk" 1G
    setfacl -m u:libvirt-qemu:rw "$etcd_disk"

    create_cloud_init_disk "$node_name"

    sudo virt-install \
        --quiet \
        --name "$node_name" \
        --memory "$DB_RAM_MB" \
        --vcpus 1 \
        --disk "path=${root_disk},format=qcow2,bus=virtio,cache=none" \
        --disk "path=${etcd_disk},format=qcow2,bus=virtio,cache=none,serial=etcd-disk" \
        --disk "path=${seed_img},format=raw,readonly=on" \
        --watchdog "i6300esb,action=reset" \
        --os-variant debian12 \
        --network "network=default,mac=${mac},model=virtio" \
        --graphics none \
        --noautoconsole \
        --import >/dev/null

    echo "  -> ВМ БД ${node_name} (${ip}) запущена [Watchdog: i6300esb]"
}

create_lb_vm() {
    local node_name="$1"
    local ip="$2"
    local mac="$3"

    local root_disk="${WORK_DIR}/${node_name}.qcow2"
    local seed_img="${WORK_DIR}/seed-${node_name}.img"

    remove_vm_if_exists "$node_name"
    rm -f "$root_disk"

    qemu-img create -q -f qcow2 -F qcow2 -b "${WORK_DIR}/${BASE_IMAGE}" "$root_disk"
    setfacl -m u:libvirt-qemu:rw "$root_disk"

    create_cloud_init_disk "$node_name"

    sudo virt-install \
        --quiet \
        --name "$node_name" \
        --memory "$LB_RAM_MB" \
        --vcpus 1 \
        --disk "path=${root_disk},format=qcow2,bus=virtio,cache=none" \
        --disk "path=${seed_img},format=raw,readonly=on" \
        --os-variant debian12 \
        --network "network=default,mac=${mac},model=virtio" \
        --graphics none \
        --noautoconsole \
        --import >/dev/null

    echo "  -> ВМ балансировщика ${node_name} (${ip}) запущена"
}

wait_for_ssh() {
    local node_name="$1"
    local ip="$2"

    echo -n "  -> Ждем SSH на ${node_name} (${ip}) "
    while true; do
        if ssh "${SSH_OPTIONS[@]}" "root@${ip}" "true" 2>/dev/null; then
            break
        fi
        # Резервное копирование ключа, если cloud-init успел положить его только пользователю debian
        if ssh "${SSH_OPTIONS[@]}" "debian@${ip}" "sudo cp /home/debian/.ssh/authorized_keys /root/.ssh/authorized_keys" 2>/dev/null; then
            break
        fi
        echo -n "."
        sleep 2
    done
    echo " ОК"
}

install_db_packages() {
    echo "=== [4/6] Установка пакетов ==="
    echo "  -> Скачивание и установка PostgreSQL 18, Patroni и etcd на ${DB_NAMES[0]}..."

    ssh "${SSH_OPTIONS[@]}" "root@${DB_IPS[0]}" "bash -s" << 'EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if ! command -v patroni >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates gnupg lsb-release iptables >/dev/null

    install -d /usr/share/postgresql-common/pgdg
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
        -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc

    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list

    apt-get update -qq
    apt-get install -y -qq -o APT::Keep-Downloaded-Packages=true \
        postgresql-18 patroni etcd-server etcd-client python3-psycopg2 python3-etcd3 >/dev/null
fi

systemctl stop patroni etcd postgresql 2>/dev/null || true
systemctl disable postgresql >/dev/null 2>&1 || true
pg_dropcluster 18 main --stop >/dev/null 2>&1 || true
EOF

    # Копируем кэш пакетов на остальные узлы БД, чтобы не качать их повторно
    for i in 1 2; do
        local node_name="${DB_NAMES[$i]}"
        local ip="${DB_IPS[$i]}"
        echo "  -> Локальная установка пакетов на ${node_name} (${ip})..."

        ssh "${SSH_OPTIONS[@]}" "root@${DB_IPS[0]}" \
            "tar -cf - /etc/apt/sources.list.d/pgdg.list /usr/share/postgresql-common/pgdg /var/lib/apt/lists /var/cache/apt/archives 2>/dev/null" \
            | ssh "${SSH_OPTIONS[@]}" "root@${ip}" "tar -xf - -C /"

        ssh "${SSH_OPTIONS[@]}" "root@${ip}" "bash -s" << 'EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if ! command -v patroni >/dev/null 2>&1; then
    if ! apt-get install -y -qq --no-download \
        curl ca-certificates gnupg lsb-release iptables \
        postgresql-18 patroni etcd-server etcd-client python3-psycopg2 python3-etcd3 >/dev/null 2>&1; then
        apt-get install -y -qq \
            curl ca-certificates gnupg lsb-release iptables \
            postgresql-18 patroni etcd-server etcd-client python3-psycopg2 python3-etcd3 >/dev/null
    fi
fi

systemctl stop patroni etcd postgresql 2>/dev/null || true
systemctl disable postgresql >/dev/null 2>&1 || true
pg_dropcluster 18 main --stop >/dev/null 2>&1 || true
EOF
    done
}

install_lb_packages() {
    for i in 0 1; do
        local node_name="${LB_NAMES[$i]}"
        local ip="${LB_IPS[$i]}"
        echo "  -> Установка HAProxy на ${node_name} (${ip})..."

        ssh "${SSH_OPTIONS[@]}" "root@${ip}" "bash -s" << 'EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if ! command -v haproxy >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq haproxy iptables >/dev/null
fi
systemctl stop haproxy 2>/dev/null || true
EOF
    done
}

configure_db_node() {
    local node_name="$1"
    local ip="$2"

    ssh "${SSH_OPTIONS[@]}" "root@${ip}" \
        "bash -s" -- "$node_name" "$ip" "$PG_SUPER_PASS" "$PG_REPL_PASS" "$PG_REWIND_PASS" << 'EOF'
set -euo pipefail

NODE_NAME="$1"
NODE_IP="$2"
PG_SUPER_PASS="$3"
PG_REPL_PASS="$4"
PG_REWIND_PASS="$5"

systemctl stop patroni etcd 2>/dev/null || true

# 1. Подключаем выделенный диск для данных etcd
ETCD_DISK="/dev/disk/by-id/virtio-etcd-disk"
if [[ -b "$ETCD_DISK" ]]; then
    if ! blkid "$ETCD_DISK" 2>/dev/null | grep -q 'TYPE="ext4"'; then
        mkfs.ext4 -q -F "$ETCD_DISK"
    fi
    mkdir -p /var/lib/etcd
    if ! mountpoint -q /var/lib/etcd; then
        mount "$ETCD_DISK" /var/lib/etcd
    fi
    if ! grep -q "$ETCD_DISK" /etc/fstab; then
        echo "${ETCD_DISK} /var/lib/etcd ext4 defaults,noatime 0 2" >> /etc/fstab
    fi
fi

rm -rf /var/lib/etcd/default.etcd /var/lib/postgresql/18/patroni
chown -R etcd:etcd /var/lib/etcd
chmod 700 /var/lib/etcd

# 2. Настраиваем аппаратный watchdog (i6300esb) и выдаем права пользователю postgres
echo "i6300esb" > /etc/modules-load.d/watchdog.conf
modprobe i6300esb 2>/dev/null || true
if [[ ! -e /dev/watchdog ]]; then
    echo "softdog" > /etc/modules-load.d/watchdog.conf
    modprobe softdog
fi

cat << 'UDEV' > /etc/udev/rules.d/99-watchdog.rules
KERNEL=="watchdog*", OWNER="postgres", GROUP="postgres", MODE="0660"
UDEV
udevadm control --reload-rules
udevadm trigger --sysname-match="watchdog*"
chown postgres:postgres /dev/watchdog*
chmod 660 /dev/watchdog*

# 3. Конфигурация etcd
cat << ETCD > /etc/default/etcd
ETCD_NAME="${NODE_NAME}"
ETCD_DATA_DIR="/var/lib/etcd/default.etcd"
ETCD_LISTEN_PEER_URLS="http://${NODE_IP}:2380"
ETCD_LISTEN_CLIENT_URLS="http://${NODE_IP}:2379,http://127.0.0.1:2379"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://${NODE_IP}:2380"
ETCD_ADVERTISE_CLIENT_URLS="http://${NODE_IP}:2379"
ETCD_INITIAL_CLUSTER="pg-node1=http://192.168.122.11:2380,pg-node2=http://192.168.122.12:2380,pg-node3=http://192.168.122.13:2380"
ETCD_INITIAL_CLUSTER_TOKEN="pg18-cluster"
ETCD_INITIAL_CLUSTER_STATE="new"
ETCD_QUOTA_BACKEND_BYTES="67108864"
ETCD

systemctl enable etcd >/dev/null 2>&1
systemctl start --no-block etcd

# 4. Конфигурация Patroni (строго по документации)
mkdir -p /etc/patroni /var/lib/postgresql/18/patroni
chown -R postgres:postgres /etc/patroni /var/lib/postgresql
chmod 700 /var/lib/postgresql/18/patroni

cat << PATRONI > /etc/patroni/config.yml
scope: pg18-ha
namespace: /service
name: ${NODE_NAME}

restapi:
  listen: ${NODE_IP}:8008
  connect_address: ${NODE_IP}:8008

etcd3:
  hosts:
    - 192.168.122.11:2379
    - 192.168.122.12:2379
    - 192.168.122.13:2379

watchdog:
  mode: required
  device: /dev/watchdog
  safety_margin: 5

bootstrap:
  dcs:
    ttl: 20
    loop_wait: 2
    retry_timeout: 5
    maximum_lag_on_failover: 1048576
    check_timeline: true
    synchronous_mode: true
    synchronous_mode_strict: false
    synchronous_node_count: 1
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        max_connections: 50
        shared_buffers: 64MB
        work_mem: 4MB
        wal_level: replica
        hot_standby: "on"
        wal_keep_size: 64MB
        wal_log_hints: "on"
        full_page_writes: "on"

  initdb:
    - encoding: UTF8
    - locale: C.UTF-8
    - data-checksums

  pg_hba:
    - local all all trust
    - host replication replicator 127.0.0.1/32 scram-sha-256
    - host replication replicator 192.168.122.0/24 scram-sha-256
    - host all all 127.0.0.1/32 scram-sha-256
    - host all all 192.168.122.0/24 scram-sha-256

postgresql:
  listen: 0.0.0.0:5432
  connect_address: ${NODE_IP}:5432
  data_dir: /var/lib/postgresql/18/patroni
  bin_dir: /usr/lib/postgresql/18/bin
  authentication:
    replication:
      username: replicator
      password: ${PG_REPL_PASS}
    superuser:
      username: postgres
      password: ${PG_SUPER_PASS}
    rewind:
      username: rewinder
      password: ${PG_REWIND_PASS}
PATRONI

chown postgres:postgres /etc/patroni/config.yml
chmod 600 /etc/patroni/config.yml

systemctl enable patroni >/dev/null 2>&1
systemctl start --no-block patroni
EOF

    echo "  -> Сервисы etcd + Patroni (Watchdog: required) на ${node_name} запущены"
}

configure_lb_node() {
    local node_name="$1"
    local ip="$2"

    ssh "${SSH_OPTIONS[@]}" "root@${ip}" "bash -s" << 'EOF'
set -euo pipefail

cat << 'HAPROXY' > /etc/haproxy/haproxy.cfg
global
    log /dev/log local0
    maxconn 200
    user haproxy
    group haproxy
    daemon

defaults
    log global
    mode tcp
    retries 2
    timeout client 10m
    timeout connect 2s
    timeout server 10m
    timeout check 1s

listen stats
    mode http
    bind 0.0.0.0:7000
    stats enable
    stats uri /

listen pg_rw
    bind 0.0.0.0:5000
    option httpchk
    http-check send meth GET uri /primary ver HTTP/1.1 hdr Host patroni
    http-check expect status 200
    default-server inter 1s fall 2 rise 2 on-marked-down shutdown-sessions
    server pg-node1 192.168.122.11:5432 check port 8008
    server pg-node2 192.168.122.12:5432 check port 8008
    server pg-node3 192.168.122.13:5432 check port 8008

listen pg_ro
    bind 0.0.0.0:5001
    balance roundrobin
    option httpchk
    http-check send meth GET uri /replica?lag=10MB ver HTTP/1.1 hdr Host patroni
    http-check expect status 200
    default-server inter 1s fall 2 rise 2 on-marked-down shutdown-sessions
    server pg-node1 192.168.122.11:5432 check port 8008
    server pg-node2 192.168.122.12:5432 check port 8008
    server pg-node3 192.168.122.13:5432 check port 8008
HAPROXY

haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null
systemctl enable haproxy >/dev/null 2>&1
systemctl restart haproxy
EOF

    echo "  -> HAProxy на ${node_name} (${ip}) настроен и запущен"
}

wait_for_cluster_ready() {
    echo -n "=== [6/6] Ожидание инициализации кластера PostgreSQL 18 "

    local ready=false
    for _ in $(seq 1 45); do
        local output
        output="$(ssh "${SSH_OPTIONS[@]}" "root@${DB_IPS[0]}" "patronictl -c /etc/patroni/config.yml list" 2>/dev/null || true)"
        local streaming_count
        streaming_count="$(echo "$output" | grep -c "streaming" || true)"

        if echo "$output" | grep -q "Leader" && [[ "$streaming_count" -eq 2 ]]; then
            ready=true
            break
        fi
        echo -n "."
        sleep 2
    done

    if [[ "$ready" == "true" ]]; then
        echo " ОК ==="
    else
        echo " ТАЙМАУТ ==="
        echo "Предупреждение: не все реплики успели перейти в streaming."
    fi
}

create_application_user() {
    echo "  -> Создание непривилегированного пользователя '${APP_USER}' и БД '${APP_DB}' через HAProxy..."

    # Ждем до 10 секунд, пока HAProxy отметит нового лидера как UP
    local connected=false
    for _ in $(seq 1 10); do
        if ssh "${SSH_OPTIONS[@]}" "root@${DB_IPS[0]}" \
            "PGPASSWORD='${PG_SUPER_PASS}' /usr/lib/postgresql/18/bin/psql -h ${LB_IPS[0]} -p 5000 -U postgres -d postgres -c 'SELECT 1;' >/dev/null 2>&1"; then
            connected=true
            break
        fi
        sleep 1
    done

    if [[ "$connected" != "true" ]]; then
        echo "Ошибка: HAProxy (${LB_IPS[0]}:5000) не принял подключение к лидеру."
        exit 1
    fi

    ssh "${SSH_OPTIONS[@]}" "root@${DB_IPS[0]}" \
        "bash -s" -- "${LB_IPS[0]}" "$PG_SUPER_PASS" "$APP_USER" "$APP_PASS" "$APP_DB" << 'EOF'
set -euo pipefail
LB_IP="$1"
PG_SUPER_PASS="$2"
APP_USER="$3"
APP_PASS="$4"
APP_DB="$5"

export PGPASSWORD="$PG_SUPER_PASS"
PSQL="/usr/lib/postgresql/18/bin/psql -h ${LB_IP} -p 5000 -U postgres -v ON_ERROR_STOP=1"

$PSQL -d postgres << SQL >/dev/null
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${APP_USER}') THEN
        CREATE ROLE ${APP_USER} WITH LOGIN PASSWORD '${APP_PASS}';
    END IF;
END
\$\$;
SQL

if ! $PSQL -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '${APP_DB}'" | grep -q 1; then
    $PSQL -d postgres -c "CREATE DATABASE ${APP_DB} OWNER ${APP_USER};" >/dev/null
fi
EOF
}

# ==============================================================================
# Основной сценарий запуска
# ==============================================================================
main() {
    local mode="${1:-full}"

    if [[ "$mode" != "--configure-only" ]]; then
        setup_libvirt_network
        prepare_base_image_and_keys

        echo "=== [2/6] Создание и запуск 5 виртуальных машин (3 БД + 2 HAProxy) ==="
        for i in 0 1 2; do
            create_db_vm "${DB_NAMES[$i]}" "${DB_IPS[$i]}" "${DB_MACS[$i]}"
        done
        for i in 0 1; do
            create_lb_vm "${LB_NAMES[$i]}" "${LB_IPS[$i]}" "${LB_MACS[$i]}"
        done
    else
        echo "=== Включение существующих ВМ ==="
        sudo virsh net-start default >/dev/null 2>&1 || true
        for name in "${DB_NAMES[@]}" "${LB_NAMES[@]}"; do
            sudo virsh start "$name" >/dev/null 2>&1 || true
        done
    fi

    echo "=== [3/6] Ожидание готовности SSH ==="
    for i in 0 1 2; do
        wait_for_ssh "${DB_NAMES[$i]}" "${DB_IPS[$i]}"
    done
    for i in 0 1; do
        wait_for_ssh "${LB_NAMES[$i]}" "${LB_IPS[$i]}"
    done

    install_db_packages
    install_lb_packages

    echo "=== [5/6] Настройка etcd, Patroni (Watchdog) и HAProxy ==="
    for i in 0 1 2; do
        configure_db_node "${DB_NAMES[$i]}" "${DB_IPS[$i]}"
    done
    for i in 0 1; do
        configure_lb_node "${LB_NAMES[$i]}" "${LB_IPS[$i]}"
    done

    wait_for_cluster_ready
    create_application_user

    echo ""
    ssh "${SSH_OPTIONS[@]}" "root@${DB_IPS[0]}" "patronictl -c /etc/patroni/config.yml list"
    echo ""
    echo "Точки входа HAProxy (libpq multi-host):"
    echo "  RW (запись): host=${LB_IPS[0]},${LB_IPS[1]} port=5000 user=${APP_USER} dbname=${APP_DB}"
    echo "  RO (чтение): host=${LB_IPS[0]},${LB_IPS[1]} port=5001 user=${APP_USER} dbname=${APP_DB}"
    echo "  Статистика:  http://${LB_IPS[0]}:7000 и http://${LB_IPS[1]}:7000"
}

main "$@"
