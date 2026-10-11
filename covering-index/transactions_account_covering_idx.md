# Индекс transactions_account_covering_idx

```sql
CREATE INDEX IF NOT EXISTS transactions_account_covering_idx
    ON transactions (account_id, created_at DESC)
    INCLUDE (amount, currency, direction);
```

Покрывающий индекс под ленту операций счёта: «последние N операций по счёту, от новых к старым». DDL —
в [setup/02_transactions_schema.sql](../setup/02_transactions_schema.sql).

Целевой запрос:

```sql
SELECT created_at, amount, currency, direction
FROM transactions
WHERE account_id = :account_id
ORDER BY created_at DESC
LIMIT :n;
```

## Ключ (account_id, created_at DESC)

Обычный составной B-tree.

- `account_id` стоит первым: по нему идёт поиск на равенство (`Index Cond`). Внутри одного `account_id` записи уже
  упорядочены по `created_at`, поэтому `ORDER BY created_at DESC` берётся из индекса без узла `Sort`, а `LIMIT`
  останавливает чтение после N записей.
- Порядок колонок важен. Запрос без условия на `account_id` (например, только `WHERE created_at > ...`) этот индекс
  эффективно не использует: `created_at` отсортирован только внутри каждого `account_id`. Skip scan по ведущей колонке
  появился только в PostgreSQL 18, здесь — 14.

### Направление DESC у created_at

Для запроса по одному счёту направление не принципиально: B-tree читается в обе стороны, и `ORDER BY created_at ASC`
даст `Index Only Scan Backward` по этому же индексу.

Направление начинает решать при сортировке по нескольким колонкам:

| ORDER BY                          | Нужен Sort                                                    |
|-----------------------------------|---------------------------------------------------------------|
| `account_id, created_at DESC`     | нет, прямой обход                                             |
| `account_id DESC, created_at ASC` | нет, обратный обход                                           |
| `account_id, created_at`          | да: смешанного порядка (ASC, ASC) обход этого индекса не даёт |

## INCLUDE (amount, currency, direction)

Неключевые колонки, доступны с PostgreSQL 11.

- Хранятся только в листовых записях индекса, во внутренних страницах B-tree их нет.
- Не участвуют в упорядочивании и в поиске. Условие `WHERE amount > 3000` не станет `Index Cond`, а проверится как
  `Filter` по уже прочитанным записям индекса.
- Для `UNIQUE`-индекса уникальность проверялась бы только по ключевым колонкам.
- Зачем они нужны: запрос, который читает только колонки индекса, выполняется как Index Only Scan, то есть без обращения
  к самой таблице (heap).

## Как проверить

На 20 строках планировщик выберет `Seq Scan`, поэтому для демонстрации последовательное сканирование нужно отключить:

```sql
SET enable_seqscan = off;

EXPLAIN (ANALYZE)
SELECT created_at, amount, currency, direction
FROM transactions
WHERE account_id = 1001
ORDER BY created_at DESC
LIMIT 5;
```

Ожидаемый план:

```
Limit
  ->  Index Only Scan using transactions_account_covering_idx on transactions
        Index Cond: (account_id = 1001)
        Heap Fetches: 0
```

Фильтр по INCLUDE-колонке:

```sql
EXPLAIN (ANALYZE)
SELECT created_at, amount
FROM transactions
WHERE account_id = 1001
  AND amount > 3000
ORDER BY created_at DESC;
```

```
Index Only Scan using transactions_account_covering_idx on transactions
  Index Cond: (account_id = 1001)
  Filter: (amount > '3000'::numeric)
  Heap Fetches: 0
```

## Ограничения и цена

- Index Only Scan не ходит в таблицу только для страниц, отмеченных в visibility map как all-visible. Свежеизменённые
  страницы до `VACUUM` дают `Heap Fetches > 0`.
- `SELECT *` индекс не покрывает: `id`, `status`, `description`, `counterparty_id` в нём нет. Будет обычный Index Scan —
  порядок и `LIMIT` по-прежнему из индекса, но за каждой строкой идёт чтение из таблицы.
- Каждый `INSERT` обновляет и этот индекс. INCLUDE-колонки делают его крупнее, чем индекс только по ключу.
- HOT-обновления (без записи в индексы) возможны, только если `UPDATE` не меняет ни одну колонку индекса, включая
  INCLUDE. Поэтому смена `status` из [idempotent_update_insert.sql](../returning-is-distinct-from/idempotent_update_insert.sql) может пройти как HOT, а смена `amount` или `currency` — уже нет.
