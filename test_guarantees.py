import os
import subprocess
import threading
import time

import psycopg
import requests

NODES = {
    "pg-node1": "192.168.122.11",
    "pg-node2": "192.168.122.12",
    "pg-node3": "192.168.122.13",
}
IP_TO_NODE = {ip: name for name, ip in NODES.items()}
SSH_KEY = os.path.abspath("lab_key")


def dsn(host: str, port: int) -> str:
    return (
        f"host={host} port={port} user=postgres password=PgPass18 "
        f"dbname=postgres connect_timeout=2"
    )


def ssh_cmd(ip: str, cmd: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [
            "ssh", "-i", SSH_KEY,
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR",
            f"root@{ip}", cmd,
        ],
        capture_output=True,
        text=True,
        timeout=15,
    )


def get_cluster_state() -> dict:
    """Опрос Patroni REST API (:8008) на всех узлах. Недоступный узел -> None."""
    state = {}
    for node, ip in NODES.items():
        try:
            r = requests.get(f"http://{ip}:8008/patroni", timeout=1.5)
            state[node] = r.json()
        except Exception:
            state[node] = None
    return state


def find_leaders(state: dict) -> list[str]:
    return [
        node for node, info in state.items()
        if info and info.get("role") in ("master", "primary")
    ]


def get_haproxy_ip(exclude_ip: str | None = None) -> str:
    for ip in NODES.values():
        if ip != exclude_ip:
            return ip
    raise RuntimeError("Нет доступного узла с HAProxy")


def test_g1_single_leader_and_haproxy_routing():
    """G1: один лидер в кластере; порт 5000 ведет на него, порт 5001 — только на реплики."""
    state = get_cluster_state()
    leaders = find_leaders(state)
    assert len(leaders) == 1, f"Ожидался 1 лидер, получено: {leaders}"
    leader = leaders[0]

    gw_ip = get_haproxy_ip()

    # Проверка RW-порта (5000) и подготовка таблицы для следующих тестов
    with psycopg.connect(dsn(gw_ip, 5000), autocommit=True) as conn:
        in_recovery, rw_ip = conn.execute(
            "SELECT pg_is_in_recovery(), host(inet_server_addr());"
        ).fetchone()
        assert in_recovery is False, "Порт 5000 направил запрос на реплику"
        assert IP_TO_NODE[rw_ip] == leader
        conn.execute(
            "DROP TABLE IF EXISTS tx_log; "
            "CREATE TABLE tx_log (id INT PRIMARY KEY, node TEXT);"
        )

    # Проверка RO-порта (5001): round-robin должен затронуть обе реплики
    ro_ips = set()
    for _ in range(6):
        with psycopg.connect(dsn(gw_ip, 5001)) as conn:
            in_recovery, ro_ip = conn.execute(
                "SELECT pg_is_in_recovery(), host(inet_server_addr());"
            ).fetchone()
            assert in_recovery is True, f"Порт 5001 направил запрос на лидера ({ro_ip})"
            ro_ips.add(ro_ip)

    ro_nodes = [IP_TO_NODE[ip] for ip in ro_ips]
    print(f"\n[G1] Лидер (5000): {leader} | Реплики (5001): {ro_nodes}")
    assert len(ro_ips) == 2, f"Ожидались 2 реплики в балансировке, получено: {ro_nodes}"


def test_g2_and_g3_failover_rto_and_zero_rpo():
    """G2/G3: при жестком отключении лидера RTO <= 25 с и RPO == 0."""
    state = get_cluster_state()
    leaders = find_leaders(state)
    assert len(leaders) == 1, f"Ожидался 1 лидер, получено: {leaders}"

    old_leader = leaders[0]
    old_leader_ip = NODES[old_leader]
    gw_ip = get_haproxy_ip(exclude_ip=old_leader_ip)
    rw_dsn = dsn(gw_ip, 5000)

    committed_ids = set()
    stop_writer = threading.Event()
    metrics = {"outage_start": None, "rto": None, "new_leader_ip": None}

    def writer_worker():
        tx_id = 1
        while not stop_writer.is_set():
            try:
                with psycopg.connect(rw_dsn) as conn:
                    with conn.cursor() as cur:
                        cur.execute(
                            "INSERT INTO tx_log (id, node) "
                            "VALUES (%s, host(inet_server_addr())) RETURNING node;",
                            (tx_id,),
                        )
                        handled_ip = cur.fetchone()[0]
                    conn.commit()

                committed_ids.add(tx_id)
                if metrics["outage_start"] is not None and metrics["rto"] is None:
                    metrics["rto"] = time.monotonic() - metrics["outage_start"]
                    metrics["new_leader_ip"] = handled_ip
                tx_id += 1
                time.sleep(0.1)
            except Exception:
                if metrics["outage_start"] is None:
                    metrics["outage_start"] = time.monotonic()
                time.sleep(0.25)

    writer = threading.Thread(target=writer_worker, daemon=True)
    writer.start()

    # Ждем стартовый поток успешных записей перед аварией
    while len(committed_ids) < 15:
        time.sleep(0.1)

    # Имитация мгновенной потери питания лидера
    subprocess.run(["sudo", "virsh", "destroy", old_leader], check=True)

    deadline = time.monotonic() + 28
    while metrics["rto"] is None and time.monotonic() < deadline:
        time.sleep(0.5)

    time.sleep(1.5)
    stop_writer.set()
    writer.join(timeout=5)

    assert metrics["rto"] is not None, "Фейловер не завершился за 28 с"
    assert metrics["rto"] <= 25.0, f"RTO превысил порог (25 с): {metrics['rto']:.2f} с"
    assert metrics["new_leader_ip"] != old_leader_ip, "Лидер не сменился"

    with psycopg.connect(rw_dsn) as conn:
        db_ids = {row[0] for row in conn.execute("SELECT id FROM tx_log;").fetchall()}

    lost = committed_ids - db_ids
    new_leader = IP_TO_NODE[metrics["new_leader_ip"]]
    print(f"\n[G2/G3] Отказ: {old_leader} -> Новый лидер: {new_leader}")
    print(f"[G2/G3] RTO: {metrics['rto']:.2f} с | Подтверждено: {len(committed_ids)} | Потеряно (RPO): {len(lost)}")
    assert len(lost) == 0, f"Потеряны подтвержденные транзакции: {lost}"


def test_g4_old_leader_rejoins_via_pg_rewind():
    """G4: после включения питания бывший лидер возвращается репликой на новом timeline."""
    state = get_cluster_state()
    down_nodes = [node for node, info in state.items() if info is None]
    assert len(down_nodes) == 1, f"Ожидался 1 выключенный узел, найдено: {down_nodes}"
    rejoining_node = down_nodes[0]

    subprocess.run(["sudo", "virsh", "start", rejoining_node], check=True)

    rejoined = False
    for _ in range(40):
        time.sleep(1)
        st = get_cluster_state().get(rejoining_node)
        if st and st.get("state") == "running" and st.get("role") in ("replica", "sync_standby"):
            rejoined = True
            tl = st.get("timeline", 1)
            print(f"\n[G4] Узел {rejoining_node} вернулся в кластер: role={st.get('role')}, timeline={tl}")
            assert tl > 1, f"Ожидался timeline > 1, получено: {tl}"
            break

    assert rejoined, f"Узел {rejoining_node} не вернулся в роли реплики за 40 с"


def test_g5_split_brain_protection():
    """G5: при сетевой изоляции лидер сам снимает полномочия, а кворум выбирает нового."""
    state = get_cluster_state()
    leaders = find_leaders(state)
    assert len(leaders) == 1, f"Ожидался 1 лидер, получено: {leaders}"

    leader = leaders[0]
    leader_ip = NODES[leader]
    other_ips = [ip for node, ip in NODES.items() if node != leader]

    try:
        # Изолируем лидера только от остальных узлов кластера (доступ с хоста сохраняется)
        block_cmd = " && ".join(
            f"iptables -I INPUT -s {ip} -j DROP && iptables -I OUTPUT -d {ip} -j DROP"
            for ip in other_ips
        )
        ssh_cmd(leader_ip, block_cmd)

        # Ждем, пока Patroni на изолированном узле снимет роль лидера (HTTP 503 на /primary)
        demoted = False
        for _ in range(45):
            time.sleep(1)
            try:
                r = requests.get(f"http://{leader_ip}:8008/primary", timeout=1.5)
                if r.status_code != 200:
                    demoted = True
                    break
            except Exception:
                pass

        assert demoted, f"Изолированный лидер {leader} не снял полномочия за 45 с"

        # Проверяем, что запись на изолированный узел невозможна (read-only или БД остановлена)
        write_blocked = False
        try:
            with psycopg.connect(dsn(leader_ip, 5432)) as conn:
                if conn.execute("SELECT pg_is_in_recovery();").fetchone()[0] is True:
                    write_blocked = True
        except Exception:
            write_blocked = True

        assert write_blocked, f"Изолированный {leader} всё ещё принимает запись!"

        # Ждем, пока оставшиеся 2 узла (кворум) выберут нового лидера
        new_leaders = []
        for _ in range(15):
            remaining_state = {
                node: info for node, info in get_cluster_state().items() if node != leader
            }
            new_leaders = find_leaders(remaining_state)
            if len(new_leaders) == 1:
                break
            time.sleep(1)

        print(f"\n[G5] Изолированный {leader} -> demoted (запись заблокирована) | Новый лидер большинства: {new_leaders}")
        assert len(new_leaders) == 1, f"Ожидался 1 новый лидер среди большинства, получено: {new_leaders}"
    finally:
        # Снимаем изоляцию и даем узлу время вернуться в кластер
        ssh_cmd(leader_ip, "iptables -F")
        time.sleep(5)
