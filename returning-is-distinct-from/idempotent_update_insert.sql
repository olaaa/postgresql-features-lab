-- RETURNING и IS DISTINCT FROM: идемпотентные UPDATE и INSERT.
-- Выполнять в базе bank_transactions после скриптов из папки setup.

SELECT *
FROM transactions
WHERE id = 1;

-- пустой результат
UPDATE transactions
SET status = 'COMPLETED'
WHERE id = 1
  AND status IS DISTINCT FROM 'COMPLETED'
    RETURNING id;

-- при повторной попытке вставить просто игнорируем
-- ничего не вернется
INSERT INTO transactions (id, account_id, amount, currency, direction, status, description, counterparty_id)
 VALUES (1,1001,50000.00,'RUB','C','COMPLETED','Зарплата за январь'
        , 2001)
ON CONFLICT DO NOTHING
RETURNING *;