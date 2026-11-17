#!/usr/bin/env python3
"""
Загрузка сообщений диспетчерского управления из messages.csv в таблицу disp_messages.

Таблица создаётся скриптом 03_create_disp_messages.sql. В файле два столбца:
nomer (-> m_id) и tekstsoobshcheniya (-> message). Текст сообщения многострочный и
заключён в кавычки, поэтому файл читается модулем csv, а не построчно.

Примеры запуска:
    python load_messages.py
    python load_messages.py --truncate
    python load_messages.py --host localhost --port 5432 --user ships --password my_super_secret
"""
from __future__ import annotations

import argparse
import csv
import logging
import os
import sys
from pathlib import Path

import psycopg2
from psycopg2.extras import execute_values

log = logging.getLogger("load_messages")
DEFAULT_FILE = Path(__file__).resolve().parent / "messages.csv"


def read_messages(path: Path) -> list[tuple[str, str]]:
    with path.open(encoding="utf-8-sig", newline="") as fh:
        reader = csv.DictReader(fh)
        return [(row["nomer"].strip(), row["tekstsoobshcheniya"]) for row in reader]


def parse_args(argv=None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Загрузка messages.csv в таблицу disp_messages.")
    p.add_argument("file", nargs="?", type=Path, default=DEFAULT_FILE, help="CSV-файл (по умолчанию messages.csv)")
    p.add_argument("--host", default=os.environ.get("PGHOST", "localhost"))
    p.add_argument("--port", type=int, default=int(os.environ.get("PGPORT", 5432)))
    p.add_argument("--user", default=os.environ.get("PGUSER", "ships"))
    p.add_argument("--password", default=os.environ.get("PGPASSWORD", "my_super_secret"))
    p.add_argument("--dbname", default=os.environ.get("PGDATABASE", "ships"))
    p.add_argument("--truncate", action="store_true", help="очистить таблицу перед загрузкой")
    return p.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
    if not args.file.is_file():
        log.error("Файл не найден: %s", args.file)
        return 2
    messages = read_messages(args.file)
    log.info("Прочитано сообщений: %d", len(messages))

    try:
        conn = psycopg2.connect(host=args.host, port=args.port, user=args.user,
                                password=args.password, dbname=args.dbname, connect_timeout=5)
    except psycopg2.OperationalError as exc:
        log.error("Не удалось подключиться к БД: %s", str(exc).strip())
        return 2
    try:
        with conn:
            cur = conn.cursor()
            cur.execute("SELECT to_regclass('public.disp_messages')")
            if cur.fetchone()[0] is None:
                log.error("Нет таблицы disp_messages. Сначала выполните 03_create_disp_messages.sql.")
                return 2
            if args.truncate:
                cur.execute("TRUNCATE disp_messages")
            execute_values(cur, "INSERT INTO disp_messages (m_id, message) VALUES %s", messages)
            cur.execute("SELECT count(*), count(DISTINCT m_id) FROM disp_messages")
            total, distinct = cur.fetchone()
        log.info("В таблице disp_messages строк: %d (различных m_id: %d)", total, distinct)
    except psycopg2.Error as exc:
        log.error("Ошибка БД, загрузка отменена: %s", (exc.diag.message_primary or str(exc)).strip())
        return 1
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
