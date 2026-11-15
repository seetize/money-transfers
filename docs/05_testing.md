# Как тестировать и что считать готовностью

## Быстрая сдача

`docker compose up -d db`, затем `docker compose run --rm --build app bin/rspec`.

Полный gate: `docker compose run --rm app ruby bin/verify --stress`. Он последовательно готовит test database, выполняет suite, RuboCop, negative control и 20 concurrency runs. Любой неожиданный сбой даёт ненулевой exit code.

Без Docker те же bin-команды запускаются через Ruby на локальной PostgreSQL. Переменные: RAILS_ENV=test, DATABASE_HOST, DATABASE_PORT, DATABASE_USER, DATABASE_PASSWORD. `pg_dump` и `psql` должны быть в PATH. Используются только имена test database; тесты очищают финансовые таблицы через TRUNCATE, поэтому не направлять test configuration в рабочую БД.

## Слои проверки

| Слой | Что проверяет | Почему это существенно |
| --- | --- | --- |
| DB constraints | Каждый CHECK по имени, FK, UNIQUE, NOT NULL, append-only, immutable result, deferred commit | Модельные validations обходятся bulk inserts/raw SQL |
| Service | Успех/failed, replay/conflict, invalid input, rollback, retry budget, overflow, nested transaction | Проверяет бизнес-контракт и отсутствие частичной записи |
| PostgreSQL retry | SQLSTATE 40P01/40001/55P03 после обновления balances | Подтверждает реальный rollback transaction и повторное получение key; это fault injection, не нагрузочный deadlock benchmark |
| HTTP | 201/200/409/422/404/503, обязательные поля и malformed JSON values | Ошибка клиента не должна превращаться в 500 |
| SQL/AR parity | Все пять SQL на seed из задания, те же AR-результаты, time boundaries/top5 | Защищает семантику и соответствие demo |
| Concurrency | Overspending, same key, opposing pairs, seeded random 50 commands | Проверяет correctness на реальном MVCC/locks/FK PostgreSQL |
| Negative control | Тот же overspending-тест на исходном алгоритме | Доказывает, что зелёный тест способен обнаружить гонку |
| Stress | 20 отдельных последовательных запусков concurrency suite | Ловит нестабильные гонки, pool/barrier/cleanup failures |
| Fresh copy | Schema load + suite без артефактов work | Проверяет воспроизводимость сдачи |

Для воспроизводимости фиксируется seed случайных пар, но времена и порядок workers не фиксируются. Параллелить целиком RSpec-процессы на одной test database нельзя: cleanup TRUNCATE будет конфликтовать. Для process-parallel тестов потребовались бы отдельные БД.

## Ограничения выводов

Успешные concurrency tests подтверждают проверенные инварианты и сценарии; они не доказывают throughput 10 000 tps или отсутствие всех возможных сбоев. Для производительности нужен отдельный профиль нагрузки с hot accounts, durability/SLO, p95/p99, WAL и lock-wait метриками.

На нативной PostgreSQL 18 при ожидаемом отказе deferred trigger на COMMIT ActiveRecord может дополнительно послать ROLLBACK уже отменённой транзакции; PostgreSQL выводит `there is no transaction in progress`. Это предупреждение негативного теста, а не сохранённый частичный перевод.

CI содержит PostgreSQL 16 service и те же gates. Его статус нельзя считать зелёным, пока workflow действительно не запущен в репозитории. Локальный Docker запуск также следует отличать от локальных native tests; фактическая среда записывается в отчёте сдачи.
