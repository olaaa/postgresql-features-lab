-- Очередь заданий notification_jobs для примеров FOR UPDATE SKIP LOCKED.
-- Выполнять в базе bank_transactions после setup/02_transactions_schema.sql, из корня проекта:
-- psql -d bank_transactions -f skip-locked/01_notification_jobs_schema.sql
-- Разбор и сценарии: for_update_skip_locked.md

-- Задание — «отправить клиенту уведомление об операции» по каналу PUSH или SMS.
-- state: READY — ждёт исполнителя, RUNNING — захвачено, DONE — выполнено, FAILED — исчерпаны попытки.
-- attempt — номер захвата: растёт при каждом захвате и служит fencing token (номером поколения).
-- lease_until — до какого момента захват действителен (аренда).
CREATE TABLE IF NOT EXISTS notification_jobs
(
    id             bigserial PRIMARY KEY,
    transaction_id bigint                   NOT NULL REFERENCES transactions (id),
    channel        text                     NOT NULL CHECK (channel IN ('PUSH', 'SMS')),
    state          text                     NOT NULL DEFAULT 'READY'
        CHECK (state IN ('READY', 'RUNNING', 'DONE', 'FAILED')),
    attempt        integer                  NOT NULL DEFAULT 0,
    worker         text,
    lease_until    timestamp with time zone,
    created_at     timestamp with time zone NOT NULL DEFAULT now(),
    updated_at     timestamp with time zone NOT NULL DEFAULT now(),
    UNIQUE (transaction_id, channel)
);

-- Частичный индекс: исполнитель ищет только готовые задания, а их в очереди обычно мало.
CREATE INDEX IF NOT EXISTS notification_jobs_ready_idx
    ON notification_jobs (id)
    WHERE state = 'READY';
