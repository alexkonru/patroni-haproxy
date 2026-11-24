import os
import subprocess
import threading
import time

import psycopg
import pytest
import requests

DB_NODES = {
    "pg-node1": "192.168.122.11",
    "pg-node2": "192.168.122.12",
    "pg-node3": "192.168.122.13",
}
IP_TO_DB_NODE = {ip: name for name, ip in DB_NODES.items()}

LB_NODES = {
    "lb-node1": "192.168.122.21",
    "lb-node2": "192.168.122.22",
}
LB_HOSTS = ",".join(LB_NODES.values())

SSH_KEY = os.path.abspath("lab_key")
APP_USER = "appuser"
APP_PASS = "AppPass18"
APP_DB = "appdb"


@pytest.fixture(scope="session", autouse=True)
def cache_sudo_credentials():
    """Заранее обновляем сессию sudo, чтобы запрос пароля не мешал замерам RTO."""
    subprocess.run(["sudo", "-v"], check=True)


def app_dsn(port: int, hosts: str = LB_HOSTS, connect_timeout: int = 2) -> str:
    return (
        f"host={hosts} port={port} user={APP_USER} password={APP_PASS} "
        f"dbname={APP_DB} connect_timeout={connect_timeout}"
    )


def ssh_run(ip: str, cmd: str, timeout: int = 10) -> subprocess.CompletedProcess:
    return subprocess.run(
        [
            "ssh", "-i", SSH_KEY,
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "ConnectTimeout=3",
            "-o", "LogLevel=ERROR",
            f"root@{ip}", cmd,
        ],
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def get_cluster_state() -> dict:
    """Опрос Patroni REST API (:8008) на всех узлах БД. Недоступный узел -> None."""
    state = {}
    for node, ip in DB_NODES.items():
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


def wait_for_healthy_cluster(timeout_sec: int = 60, require_sync_standby: bool = True) -> dict:
    """Ожидание штатного состояния: 1 лидер, 2 реплики и активный Sync Standby."""
    deadline = time.monotonic() + timeout_sec
    last_state = {}
    while time.monotonic() < deadline:
        last_state = get_cluster_state()
        leaders = find_leaders(last_state)
        replicas = [
            node for node, info in last_state.items()
            if info
            and info.get("role") in ("replica", "sync_standby")
            and info.get("state") in ("running", "streaming")
        ]
        if len(leaders) == 1 and len(replicas) == 2:
            if not require_sync_standby:
                return last_state
            for node in replicas:
                try:
                    r = requests.get(f"http://{DB_NODES[node]}:8008/sync", timeout=1.5)
                    if r.status_code == 200:
                        return last_state
                except Exception:
                    pass
        time.sleep(1)
    raise AssertionError(f"Кластер не пришел в здоровое состояние за {timeout_sec} с: {last_state}")


def get_boot_id(ip: str) -> str | None:
    try:
        res = ssh_run(ip, "cat /proc/sys/kernel/random/boot_id", timeout=5)
        if res.returncode == 0:
            return res.stdout.strip()
    except Exception:
        pass
    return None


def prepare_tx_table():
    with psycopg.connect(app_dsn(5000), autocommit=True) as conn:
        conn.execute(
            "CREATE TABLE IF NOT EXISTS tx_log (id INT PRIMARY KEY, node TEXT); "
            "TRUNCATE TABLE tx_log;"
        )


def test_g1_haproxy_routing_and_isolation():
    """G1: оба HAProxy ведут порт 5000 строго на лидера, а порт 5001 — по обеим репликам."""
    state = wait_for_healthy_cluster(30)
    leader = find_leaders(state)[0]

    # Проверяем каждый балансировщик по отдельности на порт 5000 (RW)
    for lb_name, lb_ip in LB_NODES.items():
        with psycopg.connect(app_dsn(5000, hosts=lb_ip), autocommit=True) as conn:
            in_recovery, rw_ip = conn.execute(
                "SELECT pg_is_in_recovery(), host(inet_server_addr());"
            ).fetchone()
            assert in_recovery is False, f"{lb_name}:5000 направил запрос на реплику"
            assert IP_TO_DB_NODE[rw_ip] == leader, f"{lb_name}:5000 указал не на лидера"

    # Проверяем multi-host подключение на чтение (порт 5001, RO)
    ro_ips = set()
    for _ in range(6):
        with psycopg.connect(app_dsn(5001)) as conn:
            in_recovery, ro_ip = conn.execute(
                "SELECT pg_is_in_recovery(), host(inet_server_addr());"
            ).fetchone()
            assert in_recovery is True, f"Порт 5001 направил запрос на лидера ({ro_ip})"
            ro_ips.add(ro_ip)

    ro_nodes = sorted(IP_TO_DB_NODE[ip] for ip in ro_ips)
    print(f"\n[G1] Лидер (5000): {leader} | Реплики (5001): {ro_nodes} | Балансировщики: OK")
    assert len(ro_ips) == 2, f"Ожидались 2 реплики в балансировке, получено: {ro_nodes}"


def test_g2_and_g3_failover_rto_and_zero_rpo():
    """G2/G3: при отключении питания лидера RTO <= 25 с и RPO == 0 (через HAProxy multi-host)."""
    state = wait_for_healthy_cluster(30)
    old_leader = find_leaders(state)[0]
    old_leader_ip = DB_NODES[old_leader]

    prepare_tx_table()
    rw_dsn = app_dsn(5000)

    committed_ids = set()
    stop_writer = threading.Event()
    kill_triggered = threading.Event()
    metrics = {"outage_start": None, "rto": None, "new_leader_ip": None, "last_error": None}

    def writer_worker():
        tx_id = 1
        while not stop_writer.is_set():
            # Увеличиваем ID до INSERT, чтобы после сбоя mid-commit не зациклиться на UniqueViolation
            current_id = tx_id
            tx_id += 1
            try:
                with psycopg.connect(rw_dsn) as conn:
                    with conn.cursor() as cur:
                        cur.execute(
                            "INSERT INTO tx_log (id, node) "
                            "VALUES (%s, host(inet_server_addr())) RETURNING node;",
                            (current_id,),
                        )
                        handled_ip = cur.fetchone()[0]
                    conn.commit()

                committed_ids.add(current_id)
                if metrics["outage_start"] is not None and metrics["rto"] is None:
                    metrics["rto"] = time.monotonic() - metrics["outage_start"]
                    metrics["new_leader_ip"] = handled_ip
                time.sleep(0.1)
            except Exception as exc:
                metrics["last_error"] = f"{type(exc).__name__}: {exc}"
                if kill_triggered.is_set() and metrics["outage_start"] is None:
                    metrics["outage_start"] = time.monotonic()
                time.sleep(0.25)

    writer = threading.Thread(target=writer_worker, daemon=True)
    writer.start()

    while len(committed_ids) < 15:
        time.sleep(0.1)

    kill_triggered.set()
    subprocess.run(["sudo", "virsh", "destroy", old_leader], check=True)

    deadline = time.monotonic() + 35
    while metrics["rto"] is None and time.monotonic() < deadline:
        time.sleep(0.5)

    time.sleep(1.5)
    stop_writer.set()
    writer.join(timeout=5)

    assert metrics["rto"] is not None, (
        f"Фейловер не завершился за 35 с (последняя ошибка: {metrics['last_error']})"
    )
    assert metrics["rto"] <= 25.0, f"RTO превысил порог (25 с): {metrics['rto']:.2f} с"
    assert metrics["new_leader_ip"] != old_leader_ip, "Лидер не сменился"

    with psycopg.connect(rw_dsn) as conn:
        db_ids = {row[0] for row in conn.execute("SELECT id FROM tx_log;").fetchall()}

    lost = committed_ids - db_ids
    new_leader = IP_TO_DB_NODE[metrics["new_leader_ip"]]
    print(f"\n[G2/G3] Отказ: {old_leader} -> Новый лидер: {new_leader}")
    print(f"[G2/G3] RTO: {metrics['rto']:.2f} с | Подтверждено: {len(committed_ids)} | Потеряно (RPO): {len(lost)}")
    assert len(lost) == 0, f"Потеряны подтвержденные транзакции: {lost}"


def test_g4_old_leader_rejoins_via_pg_rewind():
    """G4: после включения старый лидер возвращается репликой через pg_rewind на новом timeline."""
    state = get_cluster_state()
    down_nodes = [node for node, info in state.items() if info is None]
    assert len(down_nodes) == 1, f"Ожидался 1 выключенный узел, найдено: {down_nodes}"

    rejoining_node = down_nodes[0]
    rejoining_ip = DB_NODES[rejoining_node]

    subprocess.run(["sudo", "virsh", "start", rejoining_node], check=True)

    rejoined = False
    tl = 1
    role = None
    for _ in range(45):
        time.sleep(1)
        st = get_cluster_state().get(rejoining_node)
        if (
            st
            and st.get("state") in ("running", "streaming")
            and st.get("role") in ("replica", "sync_standby")
        ):
            rejoined = True
            tl = st.get("timeline", 1)
            role = st.get("role")
            break

    assert rejoined, f"Узел {rejoining_node} не вернулся в роли реплики за 45 с"
    assert tl > 1, f"Ожидался timeline > 1, получено: {tl}"

    # Проверяем в журнале Patroni после перезагрузки, что pg_rewind реально отработал
    log_res = ssh_run(rejoining_ip, "journalctl -u patroni -b --no-pager | grep -i rewind || true")
    rewind_lines = [line.strip() for line in log_res.stdout.splitlines() if line.strip()]
    rewind_ok = any("pg_rewind" in line.lower() for line in rewind_lines)

    print(f"\n[G4] Узел {rejoining_node} вернулся: role={role}, timeline={tl}")
    if rewind_lines:
        print(f"[G4] Записи pg_rewind в журнале: {rewind_lines[-1]}")
    assert rewind_ok, (
        f"В журнале {rejoining_node} не найдено подтверждение запуска pg_rewind "
        f"(вывод: {rewind_lines})"
    )


def test_g5a_split_brain_network_isolation():
    """G5a: при обрыве сети лидер сам снимает полномочия, а кворум выбирает нового."""
    state = wait_for_healthy_cluster(30)
    leader = find_leaders(state)[0]
    leader_ip = DB_NODES[leader]
    other_ips = [ip for node, ip in DB_NODES.items() if node != leader]

    try:
        # Изолируем лидера только от остальных узлов БД (доступ с хоста сохраняется)
        block_cmd = " && ".join(
            f"iptables -I INPUT -s {ip} -j DROP && iptables -I OUTPUT -d {ip} -j DROP"
            for ip in other_ips
        )
        ssh_run(leader_ip, block_cmd)

        # Ждем, пока Patroni на изолированном узле снимет роль лидера (HTTP != 200 на /primary)
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

        # Убеждаемся, что локальный PostgreSQL на изолированном узле не принимает запись
        write_blocked = False
        try:
            with psycopg.connect(app_dsn(5432, hosts=leader_ip)) as conn:
                if conn.execute("SELECT pg_is_in_recovery();").fetchone()[0] is True:
                    write_blocked = True
        except Exception:
            write_blocked = True

        assert write_blocked, f"Изолированный {leader} продолжает принимать запись"

        # Ждем выбора нового лидера среди оставшихся 2 узлов
        new_leaders = []
        for _ in range(15):
            remaining = {n: info for n, info in get_cluster_state().items() if n != leader}
            new_leaders = find_leaders(remaining)
            if len(new_leaders) == 1:
                break
            time.sleep(1)

        print(f"\n[G5a] Изолированный {leader} -> demoted (запись закрыта) | Новый лидер: {new_leaders}")
        assert len(new_leaders) == 1, f"Ожидался 1 новый лидер, получено: {new_leaders}"
    finally:
        ssh_run(leader_ip, "iptables -F")
        wait_for_healthy_cluster(45)


def test_g5b_split_brain_watchdog_fencing():
    """G5b: при зависании процесса Patroni (SIGSTOP) аппаратный watchdog жестко сбрасывает узел без Split-Brain."""
    state = wait_for_healthy_cluster(45)
    frozen_leader = find_leaders(state)[0]
    frozen_ip = DB_NODES[frozen_leader]

    old_boot_id = get_boot_id(frozen_ip)
    assert old_boot_id is not None, f"Не удалось получить boot_id с {frozen_leader}"

    pid_res = ssh_run(frozen_ip, "systemctl show -p MainPID --value patroni")
    patroni_pid = pid_res.stdout.strip()
    assert patroni_pid.isdigit() and int(patroni_pid) > 0, f"Некорректный PID Patroni: {patroni_pid}"

    freeze_start = time.monotonic()
    ssh_run(frozen_ip, f"kill -STOP {patroni_pid}")

    rebooted = False
    reboot_detected_at = None
    fencing_lost_at = None
    max_leaders_seen = 1
    try:
        deadline = time.monotonic() + 65
        while time.monotonic() < deadline:
            leaders_now = find_leaders(get_cluster_state())
            max_leaders_seen = max(max_leaders_seen, len(leaders_now))

            current_boot_id = get_boot_id(frozen_ip)
            if current_boot_id is None and fencing_lost_at is None:
                fencing_lost_at = time.monotonic() - freeze_start
            if current_boot_id is not None and current_boot_id != old_boot_id:
                rebooted = True
                reboot_detected_at = time.monotonic() - freeze_start
                break
            time.sleep(1)
    finally:
        if not rebooted:
            ssh_run(frozen_ip, f"kill -CONT {patroni_pid}")

    assert rebooted, f"Watchdog не сбросил зависший узел {frozen_leader} за 65 с"
    assert max_leaders_seen <= 1, f"Обнаружен Split-Brain во время зависания: {max_leaders_seen} лидера"

    # Сначала дожидаемся полного старта Patroni и PostgreSQL, затем проверяем журнал загрузки
    new_state = wait_for_healthy_cluster(45)
    new_leader = find_leaders(new_state)[0]

    boot_log = ssh_run(frozen_ip, "journalctl -u patroni -b --no-pager").stdout
    hard_reset_confirmed = any(
        marker in boot_log
        for marker in (
            "Database cluster state: in production",
            "database system was not properly shut down",
            "database system was interrupted",
            "pg_rewind",
        )
    )

    with psycopg.connect(app_dsn(5000), autocommit=True) as conn:
        in_recovery = conn.execute("SELECT pg_is_in_recovery();").fetchone()[0]
        assert in_recovery is False, "После восстановления HAProxy:5000 не принимает запись"

    fencing_info = f"{fencing_lost_at:.1f} с" if fencing_lost_at is not None else "быстрый ребут"
    print(
        f"\n[G5b] Замороженный {frozen_leader} (PID {patroni_pid}) сброшен watchdog "
        f"(hard_reset={hard_reset_confirmed}, потеря SSH={fencing_info}, загрузка={reboot_detected_at:.1f} с) | "
        f"Макс. лидеров: {max_leaders_seen} | Активный лидер: {new_leader}"
    )
    assert hard_reset_confirmed, "Не найдено подтверждение аварийного сброса в журнале после загрузки"


def test_g6_haproxy_failover_via_libpq_multihost():
    """G6: при отказе активного HAProxy (lb-node1) libpq переключается на lb-node2 без потери данных."""
    state = wait_for_healthy_cluster(45)
    leader_before = find_leaders(state)[0]

    prepare_tx_table()
    rw_dsn = app_dsn(5000, connect_timeout=2)

    committed_ids = set()
    stop_writer = threading.Event()
    metrics = {"outage_start": None, "lb_rto": None, "after_kill_commits": 0}
    kill_triggered = threading.Event()

    def writer_worker():
        tx_id = 1
        while not stop_writer.is_set():
            current_id = tx_id
            tx_id += 1
            try:
                with psycopg.connect(rw_dsn) as conn:
                    with conn.cursor() as cur:
                        cur.execute(
                            "INSERT INTO tx_log (id, node) VALUES (%s, host(inet_server_addr()));",
                            (current_id,),
                        )
                    conn.commit()

                committed_ids.add(current_id)
                if kill_triggered.is_set():
                    metrics["after_kill_commits"] += 1
                    if metrics["outage_start"] is not None and metrics["lb_rto"] is None:
                        metrics["lb_rto"] = time.monotonic() - metrics["outage_start"]
                time.sleep(0.1)
            except Exception:
                if kill_triggered.is_set() and metrics["outage_start"] is None:
                    metrics["outage_start"] = time.monotonic()
                time.sleep(0.2)

    writer = threading.Thread(target=writer_worker, daemon=True)
    writer.start()

    try:
        while len(committed_ids) < 10:
            time.sleep(0.1)

        kill_triggered.set()
        subprocess.run(["sudo", "virsh", "destroy", "lb-node1"], check=True)

        deadline = time.monotonic() + 20
        while metrics["after_kill_commits"] < 10 and time.monotonic() < deadline:
            time.sleep(0.2)

        stop_writer.set()
        writer.join(timeout=5)

        assert metrics["after_kill_commits"] >= 10, "Запись через резервный lb-node2 не восстановилась"

        with psycopg.connect(app_dsn(5000, hosts=LB_NODES["lb-node2"])) as conn:
            db_ids = {row[0] for row in conn.execute("SELECT id FROM tx_log;").fetchall()}

        lost = committed_ids - db_ids
        leader_after = find_leaders(get_cluster_state())[0]

        rto_text = f"{metrics['lb_rto']:.2f} с" if metrics["lb_rto"] is not None else "0.00 с (бесшовно)"
        print(
            f"\n[G6] Отказ lb-node1 -> переключение libpq на lb-node2: "
            f"простой {rto_text} | Подтверждено: {len(committed_ids)} | Потеряно (RPO): {len(lost)} | "
            f"Лидер БД не изменился ({leader_after})"
        )
        assert len(lost) == 0, f"Потеряны подтвержденные транзакции при отказе HAProxy: {lost}"
        assert leader_after == leader_before, (
            f"Отказ балансировщика не должен вызывать смену лидера БД "
            f"({leader_before} -> {leader_after})"
        )
    finally:
        stop_writer.set()
        writer.join(timeout=5)
        subprocess.run(["sudo", "virsh", "start", "lb-node1"], check=True)
