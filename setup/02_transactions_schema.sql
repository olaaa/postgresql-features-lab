-- Шаг 2. DDL таблицы transactions.
-- Выполнять в базе bank_transactions:
-- psql -d bank_transactions -f setup/02_transactions_schema.sql   (из корня проекта)
-- Таблица создаётся в схеме public, поэтому запросы во всех папках проекта работают без указания схемы.

-- Статус операции: PENDING — создана, PROCESSING — в обработке, COMPLETED — проведена.
-- У CREATE TYPE нет IF NOT EXISTS, поэтому тип создаётся в блоке DO: при повторном запуске ошибка duplicate_object
-- перехватывается, и скрипт можно запускать повторно.
DO
$$
    BEGIN
        CREATE TYPE transaction_status AS ENUM ('PENDING', 'PROCESSING', 'COMPLETED');
    EXCEPTION
        WHEN duplicate_object THEN NULL;
    END
$$;

CREATE TABLE IF NOT EXISTS transactions
(
    id              bigserial PRIMARY KEY,
    account_id      bigint                   NOT NULL,
    amount          numeric(18, 2)           NOT NULL,
    currency        char(3)                  NOT NULL,
    direction       char(1)                  NOT NULL,
    created_at      timestamp with time zone NOT NULL DEFAULT now(),
    status          transaction_status       NOT NULL,
    description     text,
    counterparty_id bigint                   NOT NULL
);

-- Покрывающий индекс под ленту операций счёта, разбор: covering-index/transactions_account_covering_idx.md
CREATE INDEX IF NOT EXISTS transactions_account_covering_idx
    ON transactions (account_id, created_at DESC)
    INCLUDE (amount, currency, direction);
