-- Задания очереди notification_jobs и сброс очереди в исходное состояние.
-- Выполнять в базе bank_transactions после setup/03_transactions_data.sql и 01_notification_jobs_schema.sql,
-- из корня проекта:
-- psql -d bank_transactions -f skip-locked/02_notification_jobs_data.sql
-- Запускать перед каждым сценарием из for_update_skip_locked.md: скрипт можно запускать повторно.

-- Сброс: очередь очищается целиком и заполняется заново, поэтому скрипт можно запускать повторно.
-- TRUNCATE удаляет и задания, добавленные вручную. Если в другой сессии открыта транзакция, которая трогала
-- notification_jobs (например, незавершённый сценарий), TRUNCATE будет ждать её COMMIT или ROLLBACK.
TRUNCATE notification_jobs;

-- По операциям 1 и 2 два задания (PUSH и SMS), по остальным — одно (PUSH).
-- Два задания на одну операцию нужны для сценария 9 (JOIN без OF).
-- id заданы явно: сценарии ссылаются на конкретные номера заданий.
INSERT INTO notification_jobs (id, transaction_id, channel)
VALUES (1, 1, 'PUSH'),
       (2, 1, 'SMS'),
       (3, 2, 'PUSH'),
       (4, 2, 'SMS'),
       (5, 3, 'PUSH'),
       (6, 4, 'PUSH'),
       (7, 5, 'PUSH'),
       (8, 6, 'PUSH'),
       (9, 7, 'PUSH'),
       (10, 8, 'PUSH');

-- id вставлены явно, поэтому сдвигаем последовательность за максимальный id.
SELECT setval(pg_get_serial_sequence('notification_jobs', 'id'), (SELECT max(id) FROM notification_jobs));
