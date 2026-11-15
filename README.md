# Money Transfers

Rails API / ActiveRecord / PostgreSQL. Денежные значения — `NUMERIC(18,2)` и `BigDecimal`. Сервис защищает атомарность, конкурентное списание, идемпотентность и двойную запись; тесты используют настоящую PostgreSQL.

## Запуск в две команды

Нужен Docker Engine/Desktop с Compose. Видеокарта для серверных контейнеров не нужна; на Windows нужны работающий Linux backend/виртуализация.

```sh
docker compose up -d db
docker compose run --rm --build app bin/rspec
```

Compose использует PostgreSQL 16, ждёт healthcheck, собирает Ruby 3.3.12 с Gemfile.lock. Entrypoint выполняет `db:prepare`. Исходники находятся внутри image, bind mount не перекрывает executable bits. Порт БД наружу не публикуется, поэтому локальная PostgreSQL не конфликтует с контейнером.

Полная проверка, включая контроль ошибочного алгоритма и 20 повторов concurrency:

```sh
docker compose run --rm app ruby bin/verify --stress
```

Без Docker: Ruby 3.3.12, PostgreSQL 16+ и `pg_dump`/`psql` в PATH. Задать DATABASE_HOST, DATABASE_PORT, DATABASE_USER, DATABASE_PASSWORD; RAILS_ENV=test. Затем `bundle install`, `ruby bin/verify --stress`. На Windows запускать bin-скрипты через `ruby`. В тестовом сервере нужно не менее 60 доступных соединений; приложение использует pool 60, самый большой сценарий — 50 workers.

## Карта решения

| Пункт | Реализация | Проверка |
| --- | --- | --- |
| Сверка balance и ledger | `sql/01_*`, `BalanceMismatches` | `spec/queries/financial_queries_spec.rb`, `sql_parity_spec.rb` |
| Net и структура transfer ledger | `sql/02_*`, `sql/05_*`, query objects | SQL parity, DB constraints, concurrency |
| Топ-5 пользователей | `sql/03_*`, `TopSenders` | Несколько счетов, tie-break, limit, 30-day boundary, failed |
| Неактивные счета | `sql/04_*`, `DormantAccounts` | Пустые счета, старые записи, 90-day boundary |
| Атомарность и ошибки | `TransferMoney` | service specs; сбой ledger откатывает balances/key |
| Идемпотентность | Unique index + ON CONFLICT | Сервисный и HTTP replay, conflict, одновременный key |
| Конкуренция | Ordered FOR NO KEY UPDATE | 20 списаний, встречные переводы, 50 workers/5 accounts |
| DB invariants | 3 миграции, `structure.sql` | `spec/db/*`: конкретные CHECK/UNIQUE/FK, NOT NULL и triggers |
| Retry после rollback | Bounded retry + jitter | Моки бюджета и реальные PostgreSQL SQLSTATE после обновления balances |
| Чувствительность теста к гонке | `bin/prove-race` | Ошибочный read/check/write проводит 20 вместо 10 переводов |
| Масштабирование и защита | `docs/03_scaling.md`, `docs/04_defense.md` | Письменное обоснование, без заявления о достигнутых 10k tps |

## Контракт

`POST /transfers`, JSON:

```json
{"transfer":{"from_account_id":1,"to_account_id":2,"amount":"10.00","idempotency_key":"client-request-123"}}
```

Amount — decimal-строка; сервис также принимает Integer/BigDecimal. Float, NaN/Infinity, сумма <=0, лишняя точность и выход за NUMERIC(18,2) отвергаются. ID — положительный Integer либо строка десятичных цифр в диапазоне bigint; дробные ID не округляются. Ключ — непустая строка до 255 символов, регистр и пробелы внутри значимы.

| Ситуация | Результат | HTTP |
| --- | --- | ---: |
| Новый key, средств хватает | completed + ровно 2 движения | 201 |
| Средств недостаточно | failed / insufficient_funds, без движений | 422 |
| Баланс получателя переполнится | failed / balance_limit_exceeded, без движений | 422 |
| Replay с теми же from/to/amount | Тот же id и конечный результат | 200 |
| Key с изменёнными параметрами | IdempotencyConflict | 409 |
| Невалидные/пропущенные поля | Типизированная ошибка | 422 |
| Счёт отсутствует | AccountNotFound, полный rollback | 404 |
| Deadlock/serialization failure/lock timeout | До 3 полных попыток, затем Retry-After: 1 | 503 |

Результат business failure сохраняется навсегда: пополнение после failed не меняет старую попытку; нужна новая попытка с новым key. Сервис синхронный, pending не коммитит. Неожиданные integrity/infrastructure errors откатывают транзакцию и не маскируются как нехватка денег. При неизвестном результате commit клиент повторяет тот же key.

Сервис отвергает вызов внутри внешней транзакции (`NestedTransaction`): retry должен владеть внешним transaction boundary. Это ошибка интеграции приложения, не пользовательский HTTP input.

## Инварианты и границы защиты

| Инвариант | Защита |
| --- | --- |
| Balance >=0, amount >0, числа не NaN | CHECK + NUMERIC bounds + input validation |
| Разные счета, допустимые status/reason | CHECK |
| Один key — одна неизменная попытка | UNIQUE + immutable transfer identity/status + запрет DELETE |
| Существующие объекты | FK/NOT NULL |
| Не больше одной стороны на account/transfer | Partial UNIQUE |
| Ledger append-only | BEFORE UPDATE/DELETE trigger |
| Terminal transfer имеет точные debit/credit; failed без движений | DEFERRABLE INITIALLY DEFERRED constraint triggers |
| Balance равен сумме ledger | Единственный транзакционный writer + сверка; это не обычный row CHECK |

Пополнение — положительный `deposit` без transfer_id. Demo seed намеренно содержит несогласованные остатки из задания, его нельзя использовать как корректный стартовый денежный баланс. `db:seed` предназначен для пустой demo-базы; рабочие тесты пополняют счета вместе с ledger.

В production runtime DB role не должен владеть таблицами или иметь TRUNCATE/DDL/disable-trigger права. Тестовый role использует TRUNCATE для очистки. Одна валюта; global key без TTL; переводы между разными счетами одного user входят в outgoing volume.

Сознательно не реализованы авторизация, UI, комиссии, мультивалютность, очереди и шардирование. Следующие шаги зависят от измерений: мониторинг lock waits/p99, outbox/CDC, балансные snapshots, partitioning. При time partitioning нужен отдельный глобальный idempotency registry.

Подробности: `docs/01_sql.md`, `docs/02_code_review.md`, `docs/03_scaling.md`, `docs/04_defense.md`, `docs/05_testing.md`. CI настроен на PostgreSQL 16; локальные фактические результаты и ограничения проверки записаны в отчёте сдачи.
