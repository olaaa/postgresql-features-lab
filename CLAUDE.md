# CLAUDE.md

Учебные примеры возможностей PostgreSQL на одной базе `bank_transactions` с таблицей операций `transactions`. Карта
тем, список проверяемых возможностей и порядок запуска — [README.md](README.md). Репозиторий публичный:
`olaaa/postgresql-features-lab` (до 2026-10-11 назывался `returning-is_distinct_from`).

## Для кого и зачем

- Пользовательница — Лела, Java Lead/Principal. Обращаться в женском роде, на «ты».
- Цель — разобраться в возможностях PostgreSQL на примерах, которые можно выполнить самой в DataGrip, и готовиться
  к собеседованиям. Глубина и точность важнее скорости.

## Устройство

- `setup/` — общая подготовка: `01` создаёт базу (из служебной базы `postgres`), `02` — таблицу `transactions`
  и покрывающий индекс, `03` — 20 тестовых операций. Все темы зависят от `setup`.
- Тема — отдельная папка: `returning-is-distinct-from/`, `covering-index/`, `skip-locked/`. Скрипты, нужные только
  теме, лежат в её папке (у `skip-locked` — `01_notification_jobs_schema.sql` и `02_notification_jobs_data.sql`).
- Новая тема — новая папка, строка в разделе «Что проверяется» и в «Структуре» README.
- Команды `psql -f` в шапках скриптов и в README даются с путями от корня проекта.

## Правила для скриптов

- Каждый скрипт можно запускать повторно: `CREATE … IF NOT EXISTS`, `INSERT … ON CONFLICT … DO NOTHING`. У
  `CREATE TYPE` нет `IF NOT EXISTS`, поэтому тип создаётся в блоке `DO` с перехватом `duplicate_object`.
- Статусы — перечисляемые типы (`CREATE TYPE … AS ENUM`), а не `text` с `CHECK` (решение Лелы 2026-10-12):
  `transaction_status`, `notification_job_state`. Новый статус — новый enum. `channel` и `direction` — не статусы.
- В шапке скрипта: что он делает, в какой базе и после каких скриптов выполнять, команда `psql`.
- SQL форматируется по строкам: каждое предложение (`SELECT`, `FROM`, `JOIN`, `WHERE`, `AND`, `SET`, `VALUES`,
  `ON CONFLICT`, `RETURNING`) с новой строки. В Markdown запрос — отдельным блоком ` ```sql `, не инлайном.
- Явные `id` в тестовых данных — после вставки сдвигать последовательность (`setval` + `pg_get_serial_sequence`).

## Тема skip-locked

- `session_a.sql` и `session_b.sql` — шаги двух сессий, пронумерованные сквозь оба файла (`-- 2.4 → …`). После
  стрелки в комментарии — ожидаемый результат в виде `(1, 1, PUSH)`, `пусто`, `ошибка 55P03` или
  `зависает, затем …`; иначе это пояснение.
- `for_update_skip_locked.md` повторяет те же шаги с результатами. Сценарий меняется сразу в трёх файлах: в обеих
  сессиях и в Markdown.
- Перед каждым сценарием выполняется `02_notification_jobs_data.sql`: он возвращает очередь в исходное состояние.

## Проверка

- Всё изменённое прогонять, а не только писать: скрипты подготовки (включая повторный запуск), SQL из `.md`, шаги
  сессий на двух настоящих соединениях с проверкой ожиданий и результатов.
- Локальный сервер Лелы — PostgreSQL 14 (Postgres.app, пользователь `olga`, `psql` без параметров). Проверять во
  временной базе (например, `pg14_check`), в конце удалять её. Рабочую базу `bank_transactions` не трогать без
  просьбы Лелы. Вспомогательные файлы и окружения — только в `/tmp`, потом удалять.
- В разборе индекса планы с Index Only Scan и `Heap Fetches: 0` получаются только после `VACUUM ANALYZE
  transactions`; на свежей базе PostgreSQL 14 выбирает Bitmap Heap Scan.

## Связь с edna-patterns-analysis

- `edna-patterns-analysis/tech/for-update-skip-locked.md` ссылается на этот репозиторий, папку `skip-locked`
  и файлы `for_update_skip_locked.md`, `session_a.sql`, `session_b.sql`, а его фрагмент `CREATE TABLE
  notification_jobs` повторяет схему из `skip-locked/01_notification_jobs_schema.sql`. При переименовании или
  смене схемы править и там (по правилам того репозитория, с пересборкой его PDF).
- PDF для чтения вслух из `skip-locked/for_update_skip_locked.md` лежит в
  `edna-patterns-analysis/tts/postgresql-features-lab/for_update_skip_locked-tts.pdf`, лист A4; рецепт сборки —
  в `edna-patterns-analysis/tts/README.md`. После правки `for_update_skip_locked.md` пересобрать его там.

## DataGrip

- Источник данных `bank_transactions@localhost`. Привязки файлов к нему — в `.idea/data_source_mapping.xml`
  (`.idea/` не под git). При переносе или переименовании файлов обновлять пути там; `01_create_database.sql`
  не привязан — он выполняется из базы `postgres`.
- Если проект открыт в DataGrip, файлы переносить осторожно: он может перезаписать `.idea`. Лучше попросить закрыть
  проект.

## Git

- Коммитить и пушить самой сразу по окончании правок, без отдельной просьбы (решение Лелы 2026-10-12). Один коммит на
  законченную задачу, `git add` по именам файлов. Ветка — `master`, не менять; перед пушем `git fetch` и проверка, что
  ветка не отстаёт от `origin`.
- Сообщения коммитов — по-русски.
- Git — только через Desktop Commander на Mac Лелы (`start_process` в
  `/Users/olga/DataGripProjects/postgresql-features-lab`): там её доступ к GitHub. Из `device_bash` git оставляет
  `.git/index.lock`, который оттуда не удалить.
- Репозиторий публичный: никаких паролей, токенов и личных данных в файлах.
