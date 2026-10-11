-- Шаг 1. Создание отдельной базы bank_transactions.
-- Выполнять, подключившись к служебной базе postgres
-- (CREATE DATABASE нельзя выполнить внутри транзакции и из самой создаваемой базы).
-- psql -d postgres -f setup/01_create_database.sql   (из корня проекта)

CREATE DATABASE bank_transactions
    ENCODING 'UTF8'
    TEMPLATE template0;
