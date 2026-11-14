# Money Transfers

Небольшой Rails API-сервис, демонстрирующий корректный денежный перевод под конкуренцией. PostgreSQL — не просто хранилище: уникальность ключа идемпотентности, допустимые состояния, неотрицательный баланс, неизменяемость ledger и структура двойной записи защищены на уровне БД.

## Запуск

Нужен только Docker Desktop / Docker Engine с Compose:

```bash
docker compose up -d db
docker compose run --rm app bin/rspec
```

Первый запуск соберёт образ, создаст test database и применит миграции. Для линтера:

```bash
docker compose run --rm app bundle exec rubocop
```

## Карта решения

| Требование | Реализация | Проверка |
| --- | --- | --- |
| Сверка balance с ledger | `sql/01_balance_mismatches.sql`, `BalanceMismatches` | `spec/queries/financial_queries_spec.rb` |
| Ненулевая сумма движений и структурный аудит | `sql/02_*`, `sql/05_*`, `UnbalancedTransfers`, `InvalidTransferLedgers` | query- и concurrency-spec |
| Топ отправителей | `sql/03_top_senders.sql`, `TopSenders` | query-spec |
| Неактивные счета | `sql/04_dormant_accounts.sql`, `DormantAccounts` | query-spec |
| Атомарный конкурентный перевод | `app/services/transfer_money.rb` | service- и concurrency-spec |
| Идемпотентность | UNIQUE index + `INSERT ... ON CONFLICT DO NOTHING` | последовательный и параллельный replay |
| Инварианты БД | миграции, CHECK/FK/UNIQUE и triggers | `spec/db/constraints_spec.rb` |
| Code review | `docs/02_code_review.md` | сценарии отказов + regression specs |
| 10 000 переводов/с | `docs/03_scaling.md` | архитектурное обоснование |

## Контракт `POST /transfers`

Тело: `{"transfer":{"from_account_id":1,"to_account_id":2,"amount":"10.00","idempotency_key":"..."}}`. Денежное значение передаётся decimal-строкой; `Float` сервис отвергает.

| Ситуация | Результат | HTTP |
| --- | --- | ---: |
| Новый ключ, средств хватает | `completed`, ровно два движения | 201 |
| Новый ключ, средств не хватает | стабильный `failed/insufficient_funds`, движений нет | 422 |
| Тот же ключ и те же параметры | ранее сохранённый результат, новых записей нет | 200 |
| Тот же ключ, другие параметры | `IdempotencyConflict` | 409 |
| Невалидная сумма/счета/ключ | типизированная ошибка до записи | 422 |
| Счёт не существует | `AccountNotFound`, rollback | 404 |
| Deadlock/serialization failure/lock timeout после 3 попыток | безопасный retry тем же ключом | 503 + `Retry-After` |

Недостаток средств сохраняется как конечный отказ. Поэтому повтор запроса не начинает внезапно успешно списывать деньги после последующего пополнения. `pending` не коммитится синхронным сервисом.

## Как обеспечивается корректность

1. Ключ захватывается атомарной вставкой под unique index. Конкурирующий replay ждёт исходную транзакцию и затем читает её конечный результат.
2. Оба счёта блокируются `FOR NO KEY UPDATE` всегда по возрастанию `id`. Баланс проверяется только после блокировки.
3. Балансы изменяются SQL-арифметикой, оба ledger entry и конечный статус записываются в одной транзакции.
4. Retry выполняется только вокруг самой внешней транзакции и только для трёх транзиентных ошибок PostgreSQL.
5. Deferred constraint trigger на коммите проверяет, что у `completed` ровно правильные debit/credit, а у `failed` движений нет.

## Инварианты базы

| Инвариант | Механизм |
| --- | --- |
| `balance >= 0`, `amount > 0`, разные счета | CHECK constraints |
| Допустимый статус и согласованный `failure_reason` | CHECK constraints |
| Один глобальный idempotency key — один transfer | UNIQUE index |
| Ссылочная целостность | NOT NULL + foreign keys |
| Одно движение на счёт в переводе | partial UNIQUE `(transfer_id, account_id)` |
| Ledger нельзя изменить/удалить | trigger `ledger_entries_append_only` |
| Идентичность transfer неизменна, статус только `pending → terminal` | trigger переходов |
| `completed` содержит точные `-amount/+amount`; `failed` — ноль движений | deferred constraint triggers |
| Денежная точность | `NUMERIC(18,2)` в PostgreSQL, `BigDecimal` в Ruby |

Равенство `accounts.balance = SUM(ledger_entries.amount)` нельзя выразить обычным row-level constraint между таблицами. Его обеспечивают единственная транзакционная точка записи и регулярная сверка; расхождение считается инцидентом. Начальное пополнение также записывается в ledger.

## Допущения и границы

- Одна валюта; комиссии, FX, авторизация и UI не входят в задачу.
- Ключ идемпотентности глобально уникален. В multi-tenant API индекс был бы `(client_id, key)`; срок хранения должен быть не меньше максимального окна клиентских retry.
- Перевод между двумя счетами одного пользователя всё равно считается исходящим объёмом.
- Demo balances из задания намеренно не согласованы с demo ledger.
- Сервис нельзя вызывать внутри внешней application transaction: транзиентная ошибка должна откатывать и повторять самый внешний transaction boundary.

Следующие production-шаги: авторизация, rate limiting, метрики ожидания locks, outbox/CDC, партиционирование ledger, balance snapshots и нагрузочное тестирование. Асинхронная saga и шардирование нужны только после подтверждения предела одной PostgreSQL измерениями.

