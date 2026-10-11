# postgresql-features-lab

Учебные примеры возможностей PostgreSQL на одной базе `bank_transactions` с таблицей операций `transactions`. Каждая
тема — в своей папке; все они работают с одной и той же таблицей `transactions`, поэтому сначала выполняются общие
скрипты из `setup`.

## Что проверяется

**Идемпотентные записи** — [returning-is-distinct-from](returning-is-distinct-from/idempotent_update_insert.sql):

- `UPDATE … RETURNING` и `INSERT … RETURNING`: пустой результат значит «ничего не изменилось»;
- `IS DISTINCT FROM` — сравнение, которое считает `NULL` обычным значением, в условии `UPDATE`;
- `INSERT … ON CONFLICT DO NOTHING`: повторная вставка не падает, а пропускается.

**Покрывающий индекс** — [covering-index](covering-index/transactions_account_covering_idx.md):

- составной B-tree-индекс с направлением `DESC` у колонки и обход индекса в обратную сторону (`Index Only Scan Backward`);
- неключевые колонки `INCLUDE` (с PostgreSQL 11);
- Index Only Scan, `Index Cond` и `Filter` в плане, `Heap Fetches` и visibility map;
- `EXPLAIN (ANALYZE)` и `SET enable_seqscan = off` для демонстрации на маленькой таблице;
- HOT-обновления: когда `UPDATE` не трогает индексы.

**Очередь заданий в таблице** — [skip-locked](skip-locked/for_update_skip_locked.md), девять сценариев на двух сессиях:

- блокировки строк `SELECT … FOR UPDATE`, `FOR UPDATE NOWAIT` (ошибка `55P03`), `FOR UPDATE SKIP LOCKED`;
- `FOR UPDATE OF <таблица>` в запросе с `JOIN`;
- перепроверка условия `WHERE` в `READ COMMITTED` после ожидания блокировки;
- время жизни блокировки строки — до конца транзакции;
- захват задания одним оператором: `WITH … SELECT … FOR UPDATE SKIP LOCKED` + `UPDATE … FROM … RETURNING`;
- условный `UPDATE` (compare-and-set), аренда с уборщиком и номер попытки (fencing token);
- частичный индекс (`WHERE state = 'READY'`), `pg_sleep`.

**Подготовка базы** — [setup](setup):

- `CREATE DATABASE … TEMPLATE template0`;
- `bigserial`, `setval` и `pg_get_serial_sequence` после вставки с явными `id`;
- повторно запускаемые скрипты: `CREATE … IF NOT EXISTS`, `ON CONFLICT (id) DO NOTHING`.

## Подготовка

Команды — из корня проекта:

```
psql -d postgres -f setup/01_create_database.sql
psql -d bank_transactions -f setup/02_transactions_schema.sql
psql -d bank_transactions -f setup/03_transactions_data.sql
```

`01` создаёт базу (выполняется из служебной базы `postgres`), `02` — таблицу `transactions` и покрывающий индекс,
`03` — 20 тестовых операций. `02` и `03` можно запускать повторно.

Таблица `notification_jobs` из темы `skip-locked` ссылается на `transactions` внешним ключом, поэтому эта тема тоже
требует скриптов из `setup`. Свои скрипты у неё — в той же папке.

## Структура

```
setup/
    01_create_database.sql
    02_transactions_schema.sql
    03_transactions_data.sql
returning-is-distinct-from/
    idempotent_update_insert.sql
covering-index/
    transactions_account_covering_idx.md
skip-locked/
    for_update_skip_locked.md          разбор и порядок шагов
    01_notification_jobs_schema.sql    таблица очереди
    02_notification_jobs_data.sql      задания и сброс очереди перед каждым сценарием
    session_a.sql                      шаги сессии A
    session_b.sql                      шаги сессии B
```
