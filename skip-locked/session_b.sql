-- Сессия B для сценариев из for_update_skip_locked.md.
-- Открой в DataGrip две консоли к базе bank_transactions: session_a.sql и session_b.sql из папки skip-locked.
-- Перед каждым сценарием выполни 02_notification_jobs_data.sql. Шаги выполняй по одному в порядке номеров,
-- переключаясь между консолями: шаг 1.3 идёт после 1.2, даже если он в другой консоли.
-- Транзакции открываются явно (BEGIN) и закрываются COMMIT или ROLLBACK.

-- Сценарий 1. Без блокировки: два исполнителя берут одно задание
-- (1.1, 1.2 — в сессии A)
-- 1.3
BEGIN;
-- 1.4 → (1, 1, PUSH)
SELECT id, transaction_id, channel
FROM notification_jobs
WHERE state = 'READY'
ORDER BY id
LIMIT 1;
-- (1.5 — в сессии A)
-- 1.6
ROLLBACK;

-- Сценарий 2. FOR UPDATE: второй ждёт первого
-- (2.1, 2.2 — в сессии A)
-- 2.3
BEGIN;
-- 2.4 → зависает, затем выберет (2, 1, SMS)
SELECT id, transaction_id, channel
FROM notification_jobs
WHERE state = 'READY'
ORDER BY id
LIMIT 1
FOR UPDATE;
-- (2.5, 2.6 — в сессии A)
-- 2.7
ROLLBACK;

-- Сценарий 3. FOR UPDATE NOWAIT: ошибка вместо ожидания
-- (3.1, 3.2 — в сессии A)
-- 3.3
BEGIN;
-- 3.4 → ошибка 55P03
SELECT id, transaction_id, channel
FROM notification_jobs
WHERE state = 'READY'
ORDER BY id
LIMIT 1
FOR UPDATE NOWAIT;
-- 3.5
ROLLBACK;
-- (3.6 — в сессии A)

-- Сценарий 4. Только условный UPDATE: оптимистичный захват без блокировки
-- (4.1, 4.2 — в сессии A)
-- 4.3
BEGIN;
-- 4.4 → (1, 1, PUSH) выбрано то же, что в сессии A
SELECT id, transaction_id, channel
FROM notification_jobs
WHERE state = 'READY'
ORDER BY id
LIMIT 1;
-- (4.5 — в сессии A)
-- 4.6 → зависает до коммита в сессии A, затем пусто
UPDATE notification_jobs
SET state      = 'RUNNING',
    attempt    = attempt + 1,
    worker     = 'B',
    updated_at = now()
WHERE id = 1
  AND state = 'READY'
RETURNING id, attempt;
-- (4.7 — в сессии A)
-- 4.8 идёт на новый круг → (2, 1, SMS)
SELECT id, transaction_id, channel
FROM notification_jobs
WHERE state = 'READY'
ORDER BY id
LIMIT 1;
-- 4.9 → (2, 1)
UPDATE notification_jobs
SET state      = 'RUNNING',
    attempt    = attempt + 1,
    worker     = 'B',
    updated_at = now()
WHERE id = 2
  AND state = 'READY'
RETURNING id, attempt;
-- 4.10
COMMIT;

-- Сценарий 5. FOR UPDATE SKIP LOCKED: каждый берёт своё
-- (5.1, 5.2 — в сессии A)
-- 5.3
BEGIN;
-- 5.4 → (2, 1, SMS)
SELECT id, transaction_id, channel
FROM notification_jobs
WHERE state = 'READY'
ORDER BY id
LIMIT 1
FOR UPDATE SKIP LOCKED;
-- (5.5 — в сессии A)
-- 5.6
ROLLBACK;

-- Сценарий 6. Блокировка живёт только до конца транзакции
-- (6.1, 6.2, 6.3 — в сессии A)
-- 6.4
BEGIN;
-- 6.5 → (1, 1, PUSH)
SELECT id, transaction_id, channel
FROM notification_jobs
WHERE state = 'READY'
ORDER BY id
LIMIT 1
FOR UPDATE SKIP LOCKED;
-- 6.6
ROLLBACK;

-- Сценарий 7. SKIP LOCKED + условный UPDATE: захват, который переживает транзакцию
-- (7.1, 7.2, 7.3 — в сессии A)
-- 7.4 → (2, 1)
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
    worker      = 'B',
    lease_until = now() + interval '5 seconds',
    updated_at  = now()
FROM next_job
WHERE job.id = next_job.id
RETURNING job.id, job.attempt;
-- (7.5, 7.6 — в сессии A)
-- 7.7 → (2)
UPDATE notification_jobs
SET state       = 'DONE',
    lease_until = NULL,
    updated_at  = now()
WHERE id = 2
  AND state = 'RUNNING'
  AND attempt = 1
RETURNING id;

-- Сценарий 8. Аренда и номер попытки: защита от зависшего исполнителя
-- (8.1, 8.2 — в сессии A)
-- 8.3 → (1, 1)
UPDATE notification_jobs
SET state       = 'READY',
    worker      = NULL,
    lease_until = NULL,
    updated_at  = now()
WHERE state = 'RUNNING'
  AND lease_until < now()
RETURNING id, attempt;
-- 8.4 → (1, 2)
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
    worker      = 'B',
    lease_until = now() + interval '5 seconds',
    updated_at  = now()
FROM next_job
WHERE job.id = next_job.id
RETURNING job.id, job.attempt;
-- (8.5, 8.6 — в сессии A)
-- 8.7 → пусто
UPDATE notification_jobs
SET state       = 'DONE',
    lease_until = NULL,
    updated_at  = now()
WHERE id = 1
  AND state = 'RUNNING'
  AND attempt = 2
RETURNING id;

-- Сценарий 9. JOIN без OF блокирует строки всех таблиц
-- (9.1, 9.2 — в сессии A)
-- 9.3
BEGIN;
-- 9.4 (без `OF job`) → (3, 2, PUSH, 3200.00)
SELECT job.id, job.transaction_id, job.channel, t.amount
FROM notification_jobs AS job
         JOIN transactions AS t ON t.id = job.transaction_id
WHERE job.state = 'READY'
ORDER BY job.id
LIMIT 1
FOR UPDATE SKIP LOCKED;
-- 9.5 (c `OF job`) → (2, 1, SMS, 50000.00)
SELECT job.id, job.transaction_id, job.channel, t.amount
FROM notification_jobs AS job
         JOIN transactions AS t ON t.id = job.transaction_id
WHERE job.state = 'READY'
ORDER BY job.id
LIMIT 1
FOR UPDATE OF job SKIP LOCKED;
-- (9.6 — в сессии A)
-- 9.7
ROLLBACK;
