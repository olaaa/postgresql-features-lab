# FOR UPDATE SKIP LOCKED: очередь заданий в таблице

Девять сценариев на двух сессиях: от «двое берут одно задание» до захвата с арендой и номером попытки. Разбор
механизма с мотивацией, альтернативами и примерами из edna — в репозитории edna-patterns-analysis, файл
`tech/for-update-skip-locked.md`.

## Подготовка

Нужны база `bank_transactions` и таблица `transactions` из папки `setup` (см. [README](../README.md)). Затем очередь
заданий, команды — из корня проекта:

```
psql -d bank_transactions -f skip-locked/01_notification_jobs_schema.sql
psql -d bank_transactions -f skip-locked/02_notification_jobs_data.sql
```

Задание в `notification_jobs` — «отправить клиенту уведомление об операции» по каналу PUSH или SMS. По операциям 1 и 2
по два задания (PUSH и SMS), по операциям 3–8 по одному: всего 10 заданий. `02_notification_jobs_data.sql` возвращает
очередь в исходное состояние, его надо выполнять перед каждым сценарием.

Сессия — это отдельное соединение с базой, у каждой своя транзакция. В DataGrip это две консоли:
[session_a.sql](session_a.sql) и [session_b.sql](session_b.sql). Шаги пронумерованы сквозь обе консоли: выполняй их по
одному в порядке номеров. Транзакции в скриптах открываются явно (`BEGIN`) и закрываются `COMMIT` или `ROLLBACK`.

Все сценарии прогнаны скриптом на двух настоящих соединениях к PostgreSQL 16; результаты ниже — из этого прогона. В
документации PostgreSQL 14 поведение `FOR UPDATE`, `NOWAIT` и `SKIP LOCKED` описано так же.

## Сценарии

### 1. Без блокировки: два исполнителя берут одно задание

Обычный `SELECT` ничего не блокирует. Оба исполнителя видят одно и то же первое готовое задание, и уведомление уйдёт
клиенту дважды.

**1.1, сессия A.**

```sql
BEGIN;
```

**1.2, сессия A.**

```sql
SELECT id, transaction_id, channel
FROM notification_jobs
WHERE state = 'READY'
ORDER BY id
LIMIT 1;
```

Результат: `id = 1, transaction_id = 1, channel = PUSH`.

**1.3, сессия B.**

```sql
BEGIN;
```

**1.4, сессия B.**

```sql
SELECT id, transaction_id, channel
FROM notification_jobs
WHERE state = 'READY'
ORDER BY id
LIMIT 1;
```

Результат: `id = 1, transaction_id = 1, channel = PUSH` — то же задание 1.

**1.5, сессия A.**

```sql
ROLLBACK;
```

**1.6, сессия B.**

```sql
ROLLBACK;
```

**Вывод.** Оба получили задание 1. Если дальше каждый отправит уведомление и поставит `DONE`, клиент получит два PUSH.

### 2. FOR UPDATE: второй ждёт первого

`FOR UPDATE` блокирует выбранную строку до конца транзакции. Второй исполнитель с тем же запросом встаёт в очередь за
блокировкой.

**2.1, сессия A.**

```sql
BEGIN;
```

**2.2, сессия A.**

```sql
SELECT id, transaction_id, channel
FROM notification_jobs
WHERE state = 'READY'
ORDER BY id
LIMIT 1
FOR UPDATE;
```

Результат: `id = 1, transaction_id = 1, channel = PUSH`.

**2.3, сессия B.**

```sql
BEGIN;
```

**2.4, сессия B.**

```sql
SELECT id, transaction_id, channel
FROM notification_jobs
WHERE state = 'READY'
ORDER BY id
LIMIT 1
FOR UPDATE;
```

Результат: зависает, пока A не завершит транзакцию; после COMMIT в A возвращает задание 2: `id = 2, transaction_id =
1, channel = SMS`.

**2.5, сессия A.**

```sql
UPDATE notification_jobs
SET state      = 'RUNNING',
    worker     = 'A',
    updated_at = now()
WHERE id = 1;
```

**2.6, сессия A.**

```sql
COMMIT;
```

**2.7, сессия B.**

```sql
ROLLBACK;
```

**Вывод.** Дублей нет, но исполнители работают строго по одному: B простоял всё время, пока A держал строку. После
`COMMIT` в A PostgreSQL перепроверил условие `WHERE` на новой версии строки 1 (она уже `RUNNING`), отбросил её и отдал
B следующую подходящую — задание 2. При десяти исполнителях все десять встанут в очередь за одной строкой.

### 3. FOR UPDATE NOWAIT: ошибка вместо ожидания

`NOWAIT` не ждёт: если строку не удалось заблокировать сразу, оператор падает.

**3.1, сессия A.**

```sql
BEGIN;
```

**3.2, сессия A.**

```sql
SELECT id, transaction_id, channel
FROM notification_jobs
WHERE state = 'READY'
ORDER BY id
LIMIT 1
FOR UPDATE;
```

Результат: `id = 1, transaction_id = 1, channel = PUSH`.

**3.3, сессия B.**

```sql
BEGIN;
```

**3.4, сессия B.**

```sql
SELECT id, transaction_id, channel
FROM notification_jobs
WHERE state = 'READY'
ORDER BY id
LIMIT 1
FOR UPDATE NOWAIT;
```

Результат: ошибка: could not obtain lock on row in relation "notification_jobs" (SQLSTATE 55P03).

**3.5, сессия B.**

```sql
ROLLBACK;
```

**3.6, сессия A.**

```sql
ROLLBACK;
```

**Вывод.** Ждать B не стал, но и задание не получил: ошибка прервала его транзакцию. `NOWAIT` годится, когда нужна
именно эта строка и ждать её нельзя (например, ответить пользователю «запись занята»), но не для разбора очереди.

### 4. Только условный UPDATE: оптимистичный захват без блокировки

Альтернатива без `FOR UPDATE`: найти задание обычным `SELECT`, а захватить условным `UPDATE` (compare-and-set):
«поставь `RUNNING`, только если всё ещё `READY`». Так сделан захват загрузок подписчиков в `server-subscriber` (см.
разбор в edna-patterns-analysis).

**4.1, сессия A.**

```sql
BEGIN;
```

**4.2, сессия A.**

```sql
SELECT id, transaction_id, channel
FROM notification_jobs
WHERE state = 'READY'
ORDER BY id
LIMIT 1;
```

Результат: `id = 1, transaction_id = 1, channel = PUSH`.

**4.3, сессия B.**

```sql
BEGIN;
```

**4.4, сессия B.**

```sql
SELECT id, transaction_id, channel
FROM notification_jobs
WHERE state = 'READY'
ORDER BY id
LIMIT 1;
```

Результат: `id = 1, transaction_id = 1, channel = PUSH`.

**4.5, сессия A.**

```sql
UPDATE notification_jobs
SET state      = 'RUNNING',
    attempt    = attempt + 1,
    worker     = 'A',
    updated_at = now()
WHERE id = 1
  AND state = 'READY'
RETURNING id, attempt;
```

Результат: `id = 1, attempt = 1`.

**4.6, сессия B.**

```sql
UPDATE notification_jobs
SET state      = 'RUNNING',
    attempt    = attempt + 1,
    worker     = 'B',
    updated_at = now()
WHERE id = 1
  AND state = 'READY'
RETURNING id, attempt;
```

Результат: зависает до COMMIT в A, затем возвращает пусто: задание 1 уже не READY.

**4.7, сессия A.**

```sql
COMMIT;
```

**4.8, сессия B.**

```sql
SELECT id, transaction_id, channel
FROM notification_jobs
WHERE state = 'READY'
ORDER BY id
LIMIT 1;
```

Результат: `id = 2, transaction_id = 1, channel = SMS` — повтор: следующее готовое задание.

**4.9, сессия B.**

```sql
UPDATE notification_jobs
SET state      = 'RUNNING',
    attempt    = attempt + 1,
    worker     = 'B',
    updated_at = now()
WHERE id = 2
  AND state = 'READY'
RETURNING id, attempt;
```

Результат: `id = 2, attempt = 1`.

**4.10, сессия B.**

```sql
COMMIT;
```

**Вывод.** Дублей нет: условие `state = 'READY'` пропускает только первого. Но все исполнители по-прежнему целятся в
одну и ту же первую строку, проигравший ждёт коммита победителя, получает пусто и идёт на новый круг. При десятке
исполнителей большая часть их времени уходит на такие круги.

### 5. FOR UPDATE SKIP LOCKED: каждый берёт своё

`SKIP LOCKED` не ждёт и не падает: строки, которые уже заблокированы другими, просто пропускаются.

**5.1, сессия A.**

```sql
BEGIN;
```

**5.2, сессия A.**

```sql
SELECT id, transaction_id, channel
FROM notification_jobs
WHERE state = 'READY'
ORDER BY id
LIMIT 1
FOR UPDATE SKIP LOCKED;
```

Результат: `id = 1, transaction_id = 1, channel = PUSH`.

**5.3, сессия B.**

```sql
BEGIN;
```

**5.4, сессия B.**

```sql
SELECT id, transaction_id, channel
FROM notification_jobs
WHERE state = 'READY'
ORDER BY id
LIMIT 1
FOR UPDATE SKIP LOCKED;
```

Результат: `id = 2, transaction_id = 1, channel = SMS` — сразу, без ожидания: задание 1 занято, берётся 2.

**5.5, сессия A.**

```sql
ROLLBACK;
```

**5.6, сессия B.**

```sql
ROLLBACK;
```

**Вывод.** Исполнители не мешают друг другу и не ждут: каждый получает первое свободное задание. Ради этого `SKIP
LOCKED` и придуман. Документация PostgreSQL прямо говорит, что пропуск строк даёт несогласованную картину данных и не
годится для обычной работы, а годится для таблицы-очереди с несколькими потребителями.

### 6. Блокировка живёт только до конца транзакции

Блокировка строки снимается на `COMMIT` или `ROLLBACK`. Если исполнитель закоммитит выборку и только потом пойдёт
отправлять SMS, задание снова свободно.

**6.1, сессия A.**

```sql
BEGIN;
```

**6.2, сессия A.**

```sql
SELECT id, transaction_id, channel
FROM notification_jobs
WHERE state = 'READY'
ORDER BY id
LIMIT 1
FOR UPDATE SKIP LOCKED;
```

Результат: `id = 1, transaction_id = 1, channel = PUSH`.

**6.3, сессия A.**

```sql
COMMIT;
```

A ушёл отправлять SMS вне транзакции.

**6.4, сессия B.**

```sql
BEGIN;
```

**6.5, сессия B.**

```sql
SELECT id, transaction_id, channel
FROM notification_jobs
WHERE state = 'READY'
ORDER BY id
LIMIT 1
FOR UPDATE SKIP LOCKED;
```

Результат: `id = 1, transaction_id = 1, channel = PUSH` — снова задание 1: оно не заблокировано и всё ещё READY.

**6.6, сессия B.**

```sql
ROLLBACK;
```

**Вывод.** Значит, у `SKIP LOCKED` два способа работы. Первый — делать всю работу внутри транзакции выборки: строка
заблокирована, пока работа идёт, но соединение с базой занято всё это время, и внешний вызов внутри транзакции её
затягивает. Второй — в той же транзакции сменить статус и закоммитить: тогда захват переживает транзакцию. Второй
способ и называют «SKIP LOCKED + условный UPDATE».

### 7. SKIP LOCKED + условный UPDATE: захват, который переживает транзакцию

Выборка с `SKIP LOCKED` и смена статуса в одной транзакции. A делает это двумя операторами (как в коде edna), B —
одним (`WITH … UPDATE … RETURNING`).

**7.1, сессия A.**

```sql
BEGIN;
```

**7.2, сессия A.**

```sql
SELECT id
FROM notification_jobs
WHERE state = 'READY'
ORDER BY id
LIMIT 1
FOR UPDATE SKIP LOCKED;
```

Результат: `id = 1`.

**7.3, сессия A.**

```sql
UPDATE notification_jobs
SET state       = 'RUNNING',
    attempt     = attempt + 1,
    worker      = 'A',
    lease_until = now() + interval '5 seconds',
    updated_at  = now()
WHERE id = 1
  AND state = 'READY'
RETURNING id, attempt;
```

Результат: `id = 1, attempt = 1`.

**7.4, сессия B.**

```sql
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
```

Результат: `id = 2, attempt = 1` — сразу: задание 1 заблокировано A.

**7.5, сессия A.**

```sql
COMMIT;
```

Захват зафиксирован статусом RUNNING; A работает вне транзакции.

**7.6, сессия A.**

```sql
UPDATE notification_jobs
SET state       = 'DONE',
    lease_until = NULL,
    updated_at  = now()
WHERE id = 1
  AND state = 'RUNNING'
  AND attempt = 1
RETURNING id;
```

Результат: `id = 1` — A закончил: DONE.

**7.7, сессия B.**

```sql
UPDATE notification_jobs
SET state       = 'DONE',
    lease_until = NULL,
    updated_at  = now()
WHERE id = 2
  AND state = 'RUNNING'
  AND attempt = 1
RETURNING id;
```

Результат: `id = 2` — B закончил: DONE.

**Вывод.** После `COMMIT` блокировки нет, задание защищает статус `RUNNING`: запрос с `state = 'READY'` его больше не
выберет. Условие `AND state = 'READY'` в `UPDATE` у A внутри той же транзакции всегда истинно, потому что строка уже
заблокирована A. Это страховка на случай, если выборку когда-нибудь вынесут из транзакции. Вариант B одним оператором
делает то же самое и короче. Обрати внимание: B выполнил его без `BEGIN`, оператор сам себе транзакция.

### 8. Аренда и номер попытки: защита от зависшего исполнителя

Исполнитель может упасть или зависнуть с заданием в `RUNNING`. Уборщик возвращает задания с истёкшей арендой в
`READY`. Номер попытки `attempt` не даёт опоздавшему исполнителю перетереть результат нового.

**8.1, сессия A.**

```sql
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
```

Результат: `id = 1, attempt = 1` — аренда на 5 секунд.

**8.2, сессия A.**

```sql
SELECT pg_sleep(6);
```

A «завис» дольше аренды.

**8.3, сессия B.**

```sql
UPDATE notification_jobs
SET state       = 'READY',
    worker      = NULL,
    lease_until = NULL,
    updated_at  = now()
WHERE state = 'RUNNING'
  AND lease_until < now()
RETURNING id, attempt;
```

Результат: `id = 1, attempt = 1` — уборщик вернул задание 1 в очередь.

**8.4, сессия B.**

```sql
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
```

Результат: `id = 1, attempt = 2` — B захватил задание 1, попытка 2.

**8.5, сессия A.**

```sql
UPDATE notification_jobs
SET state       = 'DONE',
    lease_until = NULL,
    updated_at  = now()
WHERE id = 1
  AND state = 'RUNNING'
  AND attempt = 1
RETURNING id;
```

Результат: пусто, 0 строк — A проснулся и пытается закрыть попытку 1, отказ.

**8.6, сессия A.**

```sql
UPDATE notification_jobs
SET state       = 'DONE',
    lease_until = NULL,
    updated_at  = now()
WHERE id = 1
  AND state = 'RUNNING'
RETURNING id;
```

Результат: `id = 1` — без номера попытки: A закрыл чужую попытку.

**8.7, сессия B.**

```sql
UPDATE notification_jobs
SET state       = 'DONE',
    lease_until = NULL,
    updated_at  = now()
WHERE id = 1
  AND state = 'RUNNING'
  AND attempt = 2
RETURNING id;
```

Результат: пусто, 0 строк — B не может закрыть своё задание: его уже закрыл A.

**Вывод.** Условие `attempt = 1` отвергло опоздавший результат A: попытку 2 ведёт B. Это fencing token (Kleppmann,
DDIA, гл. 8): номер поколения растёт при каждом захвате, и запись со старым номером не принимается. Последние два шага
показывают, что бывает без номера: условие только `state = 'RUNNING'` пропускает A, и задание закрыто результатом
зависшего исполнителя.

### 9. JOIN без OF блокирует строки всех таблиц

Запрос с `JOIN` и `FOR UPDATE` без списка таблиц блокирует строки всех таблиц запроса, в том числе `transactions`.

**9.1, сессия A.**

```sql
BEGIN;
```

**9.2, сессия A.**

```sql
SELECT job.id, job.transaction_id, job.channel, t.amount
FROM notification_jobs AS job
         JOIN transactions AS t ON t.id = job.transaction_id
WHERE job.state = 'READY'
ORDER BY job.id
LIMIT 1
FOR UPDATE SKIP LOCKED;
```

Результат: `id = 1, transaction_id = 1, channel = PUSH, amount = 50000.00`.

**9.3, сессия B.**

```sql
BEGIN;
```

**9.4, сессия B.**

```sql
SELECT job.id, job.transaction_id, job.channel, t.amount
FROM notification_jobs AS job
         JOIN transactions AS t ON t.id = job.transaction_id
WHERE job.state = 'READY'
ORDER BY job.id
LIMIT 1
FOR UPDATE SKIP LOCKED;
```

Результат: `id = 3, transaction_id = 2, channel = PUSH, amount = 3200.00` — задание 2 пропущено: строка операции 1
заблокирована A.

**9.5, сессия B.**

```sql
SELECT job.id, job.transaction_id, job.channel, t.amount
FROM notification_jobs AS job
         JOIN transactions AS t ON t.id = job.transaction_id
WHERE job.state = 'READY'
ORDER BY job.id
LIMIT 1
FOR UPDATE OF job SKIP LOCKED;
```

Результат: `id = 2, transaction_id = 1, channel = SMS, amount = 50000.00` — с OF job блокируются только задания,
задание 2 доступно.

**9.6, сессия A.**

```sql
ROLLBACK;
```

**9.7, сессия B.**

```sql
ROLLBACK;
```

**Вывод.** Без `OF` исполнитель A заблокировал и задание 1, и операцию 1. Поэтому B пропустил задание 2, хотя его
никто не брал: оно ссылается на заблокированную операцию. Пока A не закончит, никто не сможет и изменить операцию 1.
`FOR UPDATE OF job` блокирует только строки `notification_jobs`, а `transactions` читается как обычно.

## Что выбрать

- Разбор очереди несколькими исполнителями — `FOR UPDATE SKIP LOCKED` (сценарий 5).
- Работа короткая и только с базой — делать её внутри транзакции выборки, статус «в работе» не нужен (сценарий 6).
- Работа долгая или с внешним вызовом — захват статусом в той же транзакции, работа вне её (сценарий 7), плюс аренда,
  уборщик и номер попытки (сценарий 8).
- В запросе с `JOIN` — всегда `FOR UPDATE OF <таблица заданий>` (сценарий 9).
- Нужна именно эта строка, а ждать нельзя — `NOWAIT` (сценарий 3).
