# PostgreSQL 18 HA Cluster (Patroni + etcd + HAProxy)

Отказоустойчивый кластер PostgreSQL 18 из 3 узлов на базе Debian 12 (QEMU/KVM) с автоматическим фейловером, синхронной репликацией и автотестами гарантий.

## Архитектура

* **ОС:** Debian 12 (Bookworm, genericcloud), 3 ВМ по 1 vCPU и 512 МБ ОЗУ (тонкие CoW-диски `qcow2`).
* **ПО:** PostgreSQL 18.7 (PGDG), Patroni, etcd (v3 API), HAProxy.
* **Параметры Patroni:** `ttl: 20`, `loop_wait: 2`, `retry_timeout: 5`, `synchronous_mode: true`, `use_pg_rewind: true`, `data-checksums`.

| Узел | IP | Порты |
| :--- | :--- | :--- |
| `pg-node1` | `192.168.122.11` | `5000` (HAProxy RW), `5001` (HAProxy RO) |
| `pg-node2` | `192.168.122.12` | `5432` (PostgreSQL), `8008` (Patroni REST API) |
| `pg-node3` | `192.168.122.13` | `2379` / `2380` (etcd client / peer) |

## Требования на хосте

* `libvirt`, `qemu-full` (или `qemu-kvm`), `virt-install`, `dosfstools`, `acl`, `wget`, `openssh`
* Python 3.10+ (для запуска автотестов)

## Развертывание

Полный цикл (скачивание образа, создание 3 ВМ, установка пакетов, настройка и старт кластера):

```bash
chmod +x deploy.sh
./deploy.sh
```

Повторный запуск и перенастройка уже созданных ВМ (без пересоздания дисков):

```bash
./deploy.sh --configure-only
```

Проверка состояния кластера:

```bash
ssh -i lab_key root@192.168.122.11 "patronictl -c /etc/patroni/config.yml list"
```

## Автотесты гарантий (`pytest`)

Установка зависимостей и запуск:

```bash
python -m venv .venv
source .venv/bin/activate
pip install pytest "psycopg[binary]" requests
pytest -v -s test_guarantees.py
```

Проверяемые гарантии:

| Тест | Гарантия | Что проверяется |
| :--- | :--- | :--- |
| `test_g1` | Маршрутизация HAProxy | В кластере 1 лидер; порт `5000` ведет на лидера (RW), порт `5001` балансирует чтение по обеим репликам (RO). |
| `test_g2_and_g3` | $\text{RTO} \le 25\text{ с}$, $\text{RPO} = 0$ | При `virsh destroy` лидера под нагрузкой выбирается новый лидер без потери подтвержденных `COMMIT`. |
| `test_g4` | Возврат через `pg_rewind` | После `virsh start` бывший лидер сам синхронизируется и входит в кластер репликой на новом timeline. |
| `test_g5` | Защита от Split-Brain | При изоляции лидера (`iptables DROP`) он снимает полномочия и блокирует запись, а кворум выбирает нового лидера. |

## Результаты проверки

```text
test_guarantees.py::test_g1_single_leader_and_haproxy_routing
[G1] Лидер (5000): pg-node1 | Реплики (5001): ['pg-node2', 'pg-node3']
PASSED

test_guarantees.py::test_g2_and_g3_failover_rto_and_zero_rpo
[G2/G3] Отказ: pg-node1 -> Новый лидер: pg-node2
[G2/G3] RTO: 23.45 с | Подтверждено: 61 | Потеряно (RPO): 0
PASSED

test_guarantees.py::test_g4_old_leader_rejoins_via_pg_rewind
[G4] Узел pg-node1 вернулся в кластер: role=replica, timeline=10
PASSED

test_guarantees.py::test_g5_split_brain_protection
[G5] Изолированный pg-node2 -> demoted (запись заблокирована) | Новый лидер большинства: ['pg-node3']
PASSED

============================== 4 passed in 88.26s ==============================
```

Состояние кластера после завершения всех тестов:

```text
+ Cluster: pg18-ha (7711030576126154007) --+-----------+----+-------------+-----+------------+-----+
| Member   | Host           | Role         | State     | TL | Receive LSN | Lag | Replay LSN | Lag |
+----------+----------------+--------------+-----------+----+-------------+-----+------------+-----+
| pg-node1 | 192.168.122.11 | Sync Standby | streaming | 11 |   0/4122B50 |   0 |  0/4122B50 |   0 |
| pg-node2 | 192.168.122.12 | Replica      | streaming | 11 |   0/4122B50 |   0 |  0/4122B50 |   0 |
| pg-node3 | 192.168.122.13 | Leader       | running   | 11 |             |     |            |     |
+----------+----------------+--------------+-----------+----+-------------+-----+------------+-----+
```

## Очистка стенда

```bash
for i in 1 2 3; do
  sudo virsh destroy "pg-node$i" 2>/dev/null || true
  sudo virsh undefine "pg-node$i" --nvram 2>/dev/null || true
done
rm -f pg-node*.qcow2 seed-*.img
```