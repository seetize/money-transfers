# Часть 3: масштабирование до 10 000 переводов/с

10 000 tps — это не одно число для приложения. При двойной записи это 20 000 ledger rows/s, 864 млн transfers/day и 1,728 млрд ledger rows/day (до репликации и индексов). Нужны измеримые SLO: p95/p99 latency, доля hot accounts, durability и допустимость async completion.

## Где возникает contention

- **Hot account rows.** Все списания с одного счёта обязаны сериализоваться вокруг точного available balance. Merchant/clearing accounts особенно горячие.
- **WAL/fsync и commit rate.** Отдельная transaction на transfer ограничена storage latency и group commit; индексы умножают write amplification.
- **Connection slots.** PostgreSQL использует backend на connection. Сотни app instances без PgBouncer создают дорогую очередь внутри БД.
- **Indexes.** Unique idempotency index и B-trees ledger получают постоянные page splits/cache churn. Time-sortable UUIDv7 локализует writes лучше случайного UUIDv4.
- **Ledger lifecycle.** Миллиарды строк требуют partition pruning, управляемого autovacuum, архивации и отделения OLTP от отчётности.

## Что дают row locks

Locks сериализуют критическую секцию одного счёта, но независимые пары продолжают параллельно. Это точная гранулярность для check-and-debit без table lock.

Lock находится в PostgreSQL, не в Rails. Если строка удерживается 2 ms, физический предел этой строки порядка 500 операций/с независимо от числа app servers. Горизонтальное масштабирование приложения лишь добавляет waiters, connections, timeouts и tail latency. Оно помогает только пока workload распределён по независимым счетам и сама БД имеет запас.

## Эволюция архитектуры без потери корректности

1. **Сначала измерить и сократить transaction.** Убрать callbacks/I/O, объединить statements в SQL function/CTE, подготовить statements. Никаких HTTP calls под lock.
2. **PgBouncer transaction pooling + admission control.** Ограниченная очередь перед БД дешевле тысяч blocked backends. Применить per-account rate limit/backpressure.
3. **Partition ledger/transfers по времени.** Active partitions остаются малыми; старые становятся read-only/архивируются. Отчёты и сверка читают replicas/warehouse, но решение о списании — только primary.
4. **Async command log при допустимом 202.** Kafka partitions по sender account сохраняют порядок списаний. Consumer micro-batches amortize commit/WAL; каждая command идемпотентна, результат публикуется transactional outbox. Partitioning не освобождает встречный receiver lock автоматически — routing/ownership model должен быть явным.
5. **Разделить debit и credit pressure.** Credit не проверяет overdraft: для сверхгорячего получателя допустим append-only credit с асинхронным materialized balance, если product допускает lag. Debit всегда использует authoritative balance/reservation. Hot merchant можно представить несколькими subaccounts с последующей агрегацией.
6. **Шардирование по account ownership.** Внутри shard — локальная ACID transaction. Cross-shard — не иллюзия distributed transaction, а durable state machine: reserve debit → idempotent credit → finalize; каждый шаг с outbox/inbox, retry и compensating release. Available balance учитывает reservations. Это меняет latency и operation model, поэтому вводится только после исчерпания single-primary.

Нельзя ускорять систему чтением balance с replica, снятием lock/check, `synchronous_commit=off` для подтверждённых денег или at-most-once delivery без reconciliation.

## Аудит и сверка

Ledger — append-only source of truth, `accounts.balance` — materialized cache для online authorization. Исправления оформляются reversing entries, а не UPDATE.

- Периодические snapshots хранят account balance и монотонную позицию/partition offset. Reconciliation считает snapshot + tail, а не всю историю.
- Инкрементальный job берёт accounts, изменённые после watermark. Balance и ledger читаются в одном consistent snapshot (`REPEATABLE READ`); replica допустима только с зафиксированной replay position, иначе lag создаёт ложные расхождения.
- Проверки идут на трёх уровнях: account balance = ledger sum; terminal transfer имеет точные debit/credit; system-wide transfer net = 0 и total balances объясняются external deposits/withdrawals.
- Найденное расхождение блокирует/помечает счёт и создаёт incident. Автоматически «подправлять balance» нельзя до root-cause; correction — отдельная авторизованная ledger operation.
- CDC/outbox копирует committed ledger в независимое audit storage. Для требований tamper evidence применяются hash chains/Merkle batches, отдельные credentials и immutable retention.

