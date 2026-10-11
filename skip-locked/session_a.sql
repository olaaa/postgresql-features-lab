-- Сессия A для сценариев из for_update_skip_locked.md.
-- Открой в DataGrip две консоли к базе bank_transactions: session_a.sql и session_b.sql из папки skip-locked.
-- Перед каждым сценарием выполни 02_notification_jobs_data.sql. Шаги выполняй по одному в порядке номеров,
-- переключаясь между консолями: шаг 1.3 идёт после 1.2, даже если он в другой консоли.
-- Транзакции открываются явно (BEGIN) и закрываются COMMIT или ROLLBACK.

-- Сценарий 1. Без блокировки: два исполнителя берут одно задание
-- 1.1
BEGIN;
-- 1.2 → (1, 1, PUSH)
SELECT id, transaction_id, channel
FROM notification_jobs
WHERE state = 'READY'
ORDER BY id
LIMIT 1;
-- (1.3, 1.4 — в сессии B)
-- 1.5
ROLLBACK;
-- (1.6 — в сессии B)

-- Сценарий 2. FOR UPDATE: второй ждёт первого
-- 2.1
BEGIN;
-- 2.2 → (1, 1, PUSH)
SELECT id, transaction_id, channel
FROM notification_jobs
WHERE state = 'READY'
ORDER BY id
LIMIT 1
FOR UPDATE;
-- (2.3, 2.4 — в сессии B)
-- 2.5
UPDATE notification_jobs
SET state      = 'RUNNING',
    worker     = 'A',
    updated_at = now()
WHERE id = 1;
-- 2.6
COMMIT;
-- (2.7 — в сессии B)

-- Сценарий 3. FOR UPDATE NOWAIT: ошибка вместо ожидания
-- 3.1
BEGIN;
-- 3.2 → (1, 1, PUSH)
SELECT id, transaction_id, channel
FROM notification_jobs
WHERE state = 'READY'
ORDER BY id
LIMIT 1
FOR UPDATE;
-- (3.3, 3.4, 3.5 — в сессии B)
-- 3.6
ROLLBACK;

-- Сценарий 4. Только условный UPDATE: оптимистичный захват без блокировки
-- 4.1
BEGIN;
-- 4.2 → (1, 1, PUSH)
SELECT id, transaction_id, channel
FROM notification_jobs
WHERE state = 'READY'
ORDER BY id
LIMIT 1;
-- (4.3, 4.4 — в сессии B)
-- 4.5 → (1, 1)
UPDATE notification_jobs
SET state      = 'RUNNING',
    attempt    = attempt + 1,
    worker     = 'A',
    updated_at = now()
WHERE id = 1
  AND state = 'READY'
RETURNING id, attempt;
-- (4.6 — в сессии B)
-- 4.7
COMMIT;
-- (4.8, 4.9, 4.10 — в сессии B)

-- Сценарий 5. FOR UPDATE SKIP LOCKED: каждый берёт своё
-- 5.1
BEGIN;
-- 5.2 → (1, 1, PUSH)
SELECT id, transaction_id, channel
FROM notification_jobs
WHERE state = 'READY'
ORDER BY id
LIMIT 1
FOR UPDATE SKIP LOCKED;
-- (5.3, 5.4 — в сессии B)
-- 5.5
ROLLBACK;
-- (5.6 — в сессии B)

-- Сценарий 6. Блокировка живёт только до конца транзакции
-- 6.1
BEGIN;
-- 6.2 → (1, 1, PUSH)
SELECT id, transaction_id, channel
FROM notification_jobs
WHERE state = 'READY'
ORDER BY id
LIMIT 1
FOR UPDATE SKIP LOCKED;
-- 6.3 → A ушёл отправлять SMS вне транзакции
COMMIT;
-- (6.4, 6.5, 6.6 — в сессии B)

-- Сценарий 7. SKIP LOCKED + условный UPDATE: захват, который переживает транзакцию
-- 7.1
BEGIN;
-- 7.2 → (1)
SELECT id
FROM notification_jobs
WHERE state = 'READY'
ORDER BY id
LIMIT 1
FOR UPDATE SKIP LOCKED;
-- 7.3 → (1, 1)
UPDATE notification_jobs
SET state       = 'RUNNING',
    attempt     = attempt + 1,
    worker      = 'A',
    lease_until = now() + interval '5 seconds',
    updated_at  = now()
WHERE id = 1
  AND state = 'READY'
RETURNING id, attempt;
-- (7.4 — в сессии B)
-- 7.5 → захват зафиксирован статусом RUNNING; A работает вне транзакции
COMMIT;
-- 7.6 → (1)
UPDATE notification_jobs
SET state       = 'DONE',
    lease_until = NULL,
    updated_at  = now()
WHERE id = 1
  AND state = 'RUNNING'
  AND attempt = 1
RETURNING id;
-- (7.7 — в сессии B)

-- Сценарий 8. Аренда и номер попытки: защита от зависшего исполнителя
-- 8.1 → (1, 1)
WITH next_job AS (
    SELECT id
    FROM notification_jobs
    WHERE state = 'READY'
    ORDER BY id
    LIMIT 1
    FOR UPDATE SKIP LOCKED
)
UPDATE notification_jobs AS job
SET state       = 'RUNNING',
    attempt     = job.attempt + 1,
    worker      = 'A',
    lease_until = now() + interval '5 seconds',
    updated_at  = now()
FROM next_job
WHERE job.id = next_job.id
RETURNING job.id, job.attempt;
-- 8.2 → A «завис» дольше аренды
SELECT pg_sleep(6);
-- (8.3, 8.4 — в сессии B)
-- 8.5 → пусто
UPDATE notification_jobs
SET state       = 'DONE',
    lease_until = NULL,
    updated_at  = now()
WHERE id = 1
  AND state = 'RUNNING'
  AND attempt = 1
RETURNING id;
-- 8.6 → (1)
UPDATE notification_jobs
SET state       = 'DONE',
    lease_until = NULL,
    updated_at  = now()
WHERE id = 1
  AND state = 'RUNNING'
RETURNING id;
-- (8.7 — в сессии B)

-- Сценарий 9. JOIN без OF блокирует строки всех таблиц
-- 9.1
BEGIN;
-- 9.2 → (1, 1, PUSH, 50000.00)
SELECT job.id, job.transaction_id, job.channel, t.amount
FROM notification_jobs AS job
         JOIN transactions AS t ON t.id = job.transaction_id
WHERE job.state = 'READY'
ORDER BY job.id
LIMIT 1
FOR UPDATE SKIP LOCKED;
-- (9.3, 9.4, 9.5 — в сессии B)
-- 9.6
ROLLBACK;
-- (9.7 — в сессии B)
