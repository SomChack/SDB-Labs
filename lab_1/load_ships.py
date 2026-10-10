#!/usr/bin/env python3
"""Импорт данных о судах из JSON-файлов в БД ships_db (схема из init.sql).

Примеры:
    python load_ships.py ships_data.json
    python load_ships.py ships_data.json --compose docker-compose.yml
    python load_ships.py a.json b.json --host localhost --port 5432 \
        --user ships --password my_super_secret --dbname ships
    python load_ships.py ships_data.json --dry-run

Как работает:
  * Для каждой записи сначала создаются сущности, от которых зависят другие
    (страны, типы, порты, компании и т.д.), и только потом зависимые
    (судно -> рейс -> позиция). Если значение справочника уже есть в БД,
    берётся существующее, иначе создаётся новое.
  * Повторный запуск безопасен: судно ищется по IMO, рейс по
    (судно, порт выхода, порт назначения, ETA), позиция по (рейс, время).
    Дубли не создаются.
  * Каждая запись выполняется в своей точке сохранения: некорректная запись
    пропускается с понятным сообщением, остальные загружаются. С ключом
    --strict при первой ошибке откатывается всё.
  * Если в БД уже есть другое значение, а в файле другое, значение из БД
    не перезаписывается, выводится предупреждение. Пустые поля дополняются.
"""
from __future__ import annotations

import argparse
import ast
import json
import logging
import os
import re
import sys
from collections import Counter
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path

import psycopg2
from psycopg2 import sql

log = logging.getLogger("load_ships")

# Ключ владельца в исходном файле написан с КИРИЛЛИЧЕСКОЙ «с».
OWNER_COUNTRY_KEYS = ("сountry", "country")


# ---------------------------------------------------------------------------
# Параметры подключения
# ---------------------------------------------------------------------------

def find_compose_file(explicit: str | None) -> Path | None:
    """Явно указанный docker-compose.yml или автопоиск рядом со скриптом."""
    if explicit:
        path = Path(explicit)
        if not path.is_file():
            raise SystemExit(f"Файл docker-compose не найден: {path}")
        return path
    here = Path(__file__).resolve().parent
    for folder in (Path.cwd(), here, here.parent):
        for name in ("docker-compose.yml", "docker-compose.yaml"):
            if (folder / name).is_file():
                return folder / name
    return None


def read_compose(path: Path) -> dict:
    """Достаёт POSTGRES_USER / PASSWORD / DB и порт хоста из docker-compose.yml."""
    text = path.read_text(encoding="utf-8")
    found: dict = {}
    for key, name in (("POSTGRES_USER", "user"), ("POSTGRES_PASSWORD", "password"),
                      ("POSTGRES_DB", "dbname")):
        m = re.search(rf"^\s*-?\s*{key}\s*[:=]\s*['\"]?([^'\"\s#]+)", text, re.M)
        if m:
            found[name] = m.group(1)
    m = re.search(r"(?<![\d.])(\d+):5432\b", text)
    if m:
        found["port"] = int(m.group(1))
    return found


def resolve_connection(args: argparse.Namespace) -> dict:
    """Приоритет: аргументы командной строки > docker-compose.yml > значения по умолчанию."""
    compose: dict = {}
    compose_path = find_compose_file(args.compose)
    if compose_path:
        compose = read_compose(compose_path)
        log.info("Параметры подключения прочитаны из %s", compose_path)

    user = args.user or compose.get("user") or "ships"
    return {
        "host": args.host or "localhost",
        "port": args.port or compose.get("port") or 5432,
        "user": user,
        "password": args.password or compose.get("password") or os.environ.get("PGPASSWORD"),
        # В docker-compose.yml POSTGRES_DB не задан, поэтому база называется как пользователь.
        "dbname": args.dbname or compose.get("dbname") or user,
    }


# ---------------------------------------------------------------------------
# Чтение и разбор JSON
# ---------------------------------------------------------------------------

def strip_comments(text: str) -> str:
    """Убирает комментарии `-- ...` вне строк. Переводы строк сохраняются
    (номера строк в сообщениях об ошибках JSON остаются верными)."""
    out: list[str] = []
    i, n = 0, len(text)
    in_string = False
    while i < n:
        c = text[i]
        if in_string:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == '"':
                in_string = False
            i += 1
        elif c == '"':
            in_string = True
            out.append(c)
            i += 1
        elif text.startswith("--", i):
            while i < n and text[i] != "\n":
                i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def load_json_file(path: Path) -> list:
    text = path.read_text(encoding="utf-8-sig")
    try:
        data = json.loads(strip_comments(text))
    except json.JSONDecodeError as exc:
        raise ValueError(f"{path}: некорректный JSON (строка {exc.lineno}, столбец {exc.colno}): {exc.msg}")
    if isinstance(data, dict):
        data = [data]
    if not isinstance(data, list):
        raise ValueError(f"{path}: ожидался список записей или одна запись")
    return data


def text_or_none(value) -> str | None:
    if value is None:
        return None
    s = str(value).strip()
    return s or None


def required_text(raw: dict, key: str) -> str:
    value = text_or_none(raw.get(key))
    if value is None:
        raise ValueError(f"нет обязательного поля «{key}»")
    return value


def to_decimal(value, key: str) -> Decimal | None:
    if value is None or (isinstance(value, str) and not value.strip()):
        return None
    try:
        result = Decimal(str(value).strip())
    except InvalidOperation:
        raise ValueError(f"поле «{key}»: не число ({value!r})")
    if not result.is_finite():
        raise ValueError(f"поле «{key}»: недопустимое число ({value!r})")
    return result


def to_int(value, key: str) -> int | None:
    number = to_decimal(value, key)
    return None if number is None else int(number.to_integral_value())


def parse_eta(value) -> datetime:
    """ETA в исходных данных: миллисекунды от начала эпохи (UTC)."""
    if value is None or value == "":
        raise ValueError("нет обязательного поля «eta»")
    if isinstance(value, str) and not re.fullmatch(r"-?\d+(\.\d+)?", value.strip()):
        return parse_iso(value, "eta")
    millis = to_decimal(value, "eta")
    try:
        return datetime.fromtimestamp(float(millis) / 1000, tz=timezone.utc)
    except (OverflowError, ValueError, OSError):
        raise ValueError(f"поле «eta»: значение вне допустимого диапазона ({value!r})")


def parse_iso(value, key: str) -> datetime:
    s = text_or_none(value)
    if s is None:
        raise ValueError(f"нет обязательного поля «{key}»")
    try:
        parsed = datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        raise ValueError(f"поле «{key}»: не дата в формате ISO 8601 ({value!r})")
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def parse_mmsi(value) -> str | None:
    s = text_or_none(value)
    if s is None:
        return None
    # В файле MMSI числом: ведущие нули могли потеряться, возвращаем до 9 знаков.
    return s.zfill(9) if s.isdigit() else s


def parse_sea_types(value) -> list[str]:
    """seaTypes в файле: строка с Python-списком, например "['military','trade']"."""
    if value is None or value == "":
        return []
    if isinstance(value, (list, tuple)):
        items = list(value)
    elif isinstance(value, str):
        try:
            items = ast.literal_eval(value)
        except (ValueError, SyntaxError):
            try:
                items = json.loads(value)
            except json.JSONDecodeError:
                items = value.split(",")
        if isinstance(items, str):
            items = [items]
    else:
        raise ValueError(f"поле «seaTypes»: неожиданный тип ({value!r})")
    result: list[str] = []
    for item in items:
        name = text_or_none(item)
        if name and name not in result:
            result.append(name)
    return result


def normalize(raw: dict) -> dict:
    """Приводит запись из JSON к типам БД и проверяет обязательные поля."""
    if not isinstance(raw, dict):
        raise ValueError("запись не является объектом JSON")

    owner = None
    for key in OWNER_COUNTRY_KEYS:
        if key in raw:
            owner = text_or_none(raw[key])
            break

    def country(key: str) -> str | None:
        value = text_or_none(raw.get(key))
        return value.upper() if value else None

    imo = to_int(raw.get("imo"), "imo")
    if imo is None:
        raise ValueError("нет обязательного поля «imo»")

    rec = {
        "imo": imo,
        "mmsi": parse_mmsi(raw.get("mmsi")),
        "call_sign": text_or_none(raw.get("callSign")),
        "name": text_or_none(raw.get("name")),
        "name_lat": text_or_none(raw.get("nameLat")),
        "flag": country("flag"),
        "owner": owner.upper() if owner else None,
        "ship_type": text_or_none(raw.get("shipTypeName")),
        "exit_port": required_text(raw, "exitPort"),
        "exit_port_country": required_text(raw, "exitPortCountry").upper(),
        "dest_port": required_text(raw, "destinationPort"),
        "dest_port_country": required_text(raw, "destinationPortCountry").upper(),
        "eta": parse_eta(raw.get("eta")),
        "country_follow": country("countryFollow"),
        "supervisor": text_or_none(raw.get("supervisor")),
        "company": text_or_none(raw.get("supervisorCompany")),
        "sea": text_or_none(raw.get("sea")),
        "sea_area": to_decimal(raw.get("seaAreaKm"), "seaAreaKm"),
        "sea_types": parse_sea_types(raw.get("seaTypes")),
        "source": required_text(raw, "source"),
        "nav_status": text_or_none(raw.get("navStatus")),
        "received_at": parse_iso(raw.get("receiveDate"), "receiveDate"),
        "latitude": to_decimal(raw.get("latitude"), "latitude"),
        "longitude": to_decimal(raw.get("longitude"), "longitude"),
        "speed": to_decimal(raw.get("speed"), "speed"),
        "course": to_decimal(raw.get("course"), "course"),
        "rot": to_decimal(raw.get("rot"), "rot"),
        "heading": to_int(raw.get("heading"), "heading"),
    }
    for key in ("latitude", "longitude"):
        if rec[key] is None:
            raise ValueError(f"нет обязательного поля «{key}»")
    return rec


# ---------------------------------------------------------------------------
# Запись в БД
# ---------------------------------------------------------------------------

class Importer:
    def __init__(self, cur):
        self.cur = cur
        self.created: Counter = Counter()   # создано новых строк по таблицам
        self.existing: Counter = Counter()  # дубли, которые уже были в БД
        self.warnings: list[str] = []
        self._cache: dict = {}

    # -- служебное ---------------------------------------------------------

    def snapshot(self):
        return Counter(self.created), Counter(self.existing), len(self.warnings)

    def restore(self, snap):
        """Откат счётчиков и кэша после отката точки сохранения."""
        self.created, self.existing = Counter(snap[0]), Counter(snap[1])
        del self.warnings[snap[2]:]
        self._cache.clear()

    def get_or_create(self, table: str, key: dict, extra: dict | None = None) -> int:
        """Находит строку справочника по уникальным столбцам, а если её нет, создаёт.
        `extra` — дополнительные столбцы, которые записываются только при создании."""
        cache_key = (table, tuple(key.items()))
        if cache_key in self._cache:
            return self._cache[cache_key]
        cols = list(key)
        insert_cols = cols + list(extra or {})
        self.cur.execute(
            sql.SQL("INSERT INTO {t} ({ic}) VALUES ({v}) ON CONFLICT ({c}) DO NOTHING RETURNING id").format(
                t=sql.Identifier(table),
                ic=sql.SQL(", ").join(map(sql.Identifier, insert_cols)),
                c=sql.SQL(", ").join(map(sql.Identifier, cols)),
                v=sql.SQL(", ").join([sql.Placeholder()] * len(insert_cols))),
            [*key.values(), *(extra or {}).values()])
        row = self.cur.fetchone()
        if row:
            self.created[table] += 1
        else:
            where = sql.SQL(" AND ").join(
                sql.SQL("{} = %s").format(sql.Identifier(c)) for c in cols)
            self.cur.execute(
                sql.SQL("SELECT id FROM {t} WHERE {w}").format(t=sql.Identifier(table), w=where),
                list(key.values()))
            row = self.cur.fetchone()
        self._cache[cache_key] = row[0]
        return row[0]

    def reconcile(self, table: str, pk_col: str, pk_val, new: dict, label: str):
        """Дополняет пустые поля существующей строки; при расхождении значений
        оставляет значение из БД и добавляет предупреждение."""
        cols = list(new)
        self.cur.execute(
            sql.SQL("SELECT {c} FROM {t} WHERE {pk} = %s").format(
                c=sql.SQL(", ").join(map(sql.Identifier, cols)),
                t=sql.Identifier(table), pk=sql.Identifier(pk_col)),
            [pk_val])
        current = dict(zip(cols, self.cur.fetchone()))
        fill = {}
        for col, value in new.items():
            if value is None:
                continue
            if current[col] is None:
                fill[col] = value
            elif current[col] != value:
                self.warnings.append(
                    f"{label}: {table}.{col}: в БД {show(current[col])}, в файле {show(value)}; "
                    "оставлено значение из БД")
        if fill:
            self.cur.execute(
                sql.SQL("UPDATE {t} SET {s} WHERE {pk} = %s").format(
                    t=sql.Identifier(table),
                    s=sql.SQL(", ").join(sql.SQL("{} = %s").format(sql.Identifier(c)) for c in fill),
                    pk=sql.Identifier(pk_col)),
                [*fill.values(), pk_val])
            self.created[f"{table} (дополнено)"] += 1

    # -- сущности в порядке зависимостей -------------------------------------

    def import_record(self, rec: dict, label: str):
        gc = self.get_or_create

        # 1. Судно зависит от стран и типа судна.
        flag_id = gc("country", {"code": rec["flag"]}) if rec["flag"] else None
        owner_id = gc("country", {"code": rec["owner"]}) if rec["owner"] else None
        type_id = gc("ship_type", {"name": rec["ship_type"]}) if rec["ship_type"] else None
        ship = {"mmsi": rec["mmsi"], "call_sign": rec["call_sign"], "name": rec["name"],
                "name_lat": rec["name_lat"], "flag_country_id": flag_id,
                "owner_country_id": owner_id, "ship_type_id": type_id}
        self.cur.execute("SELECT 1 FROM ship WHERE imo = %s", [rec["imo"]])
        if self.cur.fetchone():
            self.reconcile("ship", "imo", rec["imo"], ship, label)
        else:
            self.cur.execute(
                """INSERT INTO ship (imo, mmsi, call_sign, name, name_lat,
                                     flag_country_id, owner_country_id, ship_type_id)
                   VALUES (%s, %s, %s, %s, %s, %s, %s, %s)""",
                [rec["imo"], *ship.values()])
            self.created["ship"] += 1

        # 2. Рейс зависит от судна, портов (а порты от стран) и оператора (а он от компании).
        exit_country = gc("country", {"code": rec["exit_port_country"]})
        dest_country = gc("country", {"code": rec["dest_port_country"]})
        exit_port = gc("port", {"name": rec["exit_port"], "country_id": exit_country})
        dest_port = gc("port", {"name": rec["dest_port"], "country_id": dest_country})
        follow_id = gc("country", {"code": rec["country_follow"]}) if rec["country_follow"] else None

        supervisor_id = None
        if rec["supervisor"]:
            if rec["company"]:
                company_id = gc("company", {"name": rec["company"]})
                supervisor_id = gc("supervisor", {"company_id": company_id, "name": rec["supervisor"]})
            else:
                self.warnings.append(
                    f"{label}: у оператора «{rec['supervisor']}» нет компании, оператор не сохранён")
        elif rec["company"]:
            gc("company", {"name": rec["company"]})

        self.cur.execute(
            """SELECT id FROM voyage
                WHERE ship_imo = %s AND exit_port_id = %s AND destination_port_id = %s AND eta = %s""",
            [rec["imo"], exit_port, dest_port, rec["eta"]])
        row = self.cur.fetchone()
        if row:
            voyage_id = row[0]
            self.reconcile("voyage", "id", voyage_id,
                           {"country_follow_id": follow_id, "supervisor_id": supervisor_id}, label)
        else:
            self.cur.execute(
                """INSERT INTO voyage (ship_imo, exit_port_id, destination_port_id, eta,
                                       country_follow_id, supervisor_id)
                   VALUES (%s, %s, %s, %s, %s, %s) RETURNING id""",
                [rec["imo"], exit_port, dest_port, rec["eta"], follow_id, supervisor_id])
            voyage_id = self.cur.fetchone()[0]
            self.created["voyage"] += 1

        # 3. Акватория, её площадь и допустимые категории судов.
        sea_id = None
        if rec["sea"]:
            created_before = self.created["sea"]
            sea_id = gc("sea", {"name": rec["sea"]}, extra={"area_km": rec["sea_area"]})
            if self.created["sea"] == created_before:  # море уже было: дополняем и сверяем площадь
                self.reconcile("sea", "id", sea_id, {"area_km": rec["sea_area"]}, label)
            for category in rec["sea_types"]:
                category_id = gc("ship_category", {"name": category})
                self.cur.execute(
                    """INSERT INTO sea_ship_category (sea_id, ship_category_id) VALUES (%s, %s)
                       ON CONFLICT DO NOTHING RETURNING sea_id""",
                    [sea_id, category_id])
                if self.cur.fetchone():
                    self.created["sea_ship_category"] += 1
        elif rec["sea_types"] or rec["sea_area"] is not None:
            self.warnings.append(f"{label}: указаны площадь или категории акватории без названия, пропущены")

        # 4. Позиция зависит от рейса, источника, статуса и акватории.
        source_id = gc("info_source", {"name": rec["source"]})
        nav_id = gc("nav_status", {"name": rec["nav_status"]}) if rec["nav_status"] else None
        self.cur.execute(
            """INSERT INTO ship_position (voyage_id, received_at, info_source_id, latitude, longitude,
                                          speed, course, rot, heading, nav_status_id, sea_id)
               VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
               ON CONFLICT (voyage_id, received_at) DO NOTHING RETURNING id""",
            [voyage_id, rec["received_at"], source_id, rec["latitude"], rec["longitude"],
             rec["speed"], rec["course"], rec["rot"], rec["heading"], nav_id, sea_id])
        if self.cur.fetchone():
            self.created["ship_position"] += 1
        else:
            self.existing["ship_position"] += 1


EXPECTED_TABLES = ("country", "ship_type", "nav_status", "info_source", "company", "ship_category",
                   "sea", "sea_ship_category", "port", "supervisor", "ship", "voyage", "ship_position")


def check_schema(cur, conn_params: dict) -> list[str]:
    """Проверяет, что все таблицы из init.sql есть в схеме public текущей базы.
    Возвращает строки с описанием проблемы и подсказками (пусто, если всё на месте)."""
    cur.execute(
        """SELECT n.nspname, c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind IN ('r', 'p') AND c.relname = ANY(%s)""",
        [list(EXPECTED_TABLES)])
    found = cur.fetchall()
    in_public = {name for schema, name in found if schema == "public"}
    missing = [t for t in EXPECTED_TABLES if t not in in_public]
    if not missing:
        return []

    db = conn_params["dbname"]
    if len(missing) == len(EXPECTED_TABLES):
        problems = [f"В базе «{db}» (схема public) нет ни одной таблицы из init.sql."]
    else:
        problems = [f"В базе «{db}» (схема public) не хватает таблиц: {', '.join(missing)}.",
                    "Похоже, init.sql остановился на ошибке или выполнен не целиком."]
    elsewhere = sorted(f"{schema}.{name}" for schema, name in found if schema != "public")
    if elsewhere:
        problems.append("Эти таблицы лежат в другой схеме: " + ", ".join(elsewhere))

    # Ищем таблицы в других базах этого же сервера: частая причина — init.sql выполнен не в той базе.
    cur.execute("SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> current_database()")
    hosts = []
    for (other,) in cur.fetchall():
        try:
            other_conn = psycopg2.connect(connect_timeout=5, **{**conn_params, "dbname": other})
        except psycopg2.Error:
            continue
        try:
            other_cur = other_conn.cursor()
            other_cur.execute("SELECT to_regclass('public.ship_position')")
            if other_cur.fetchone()[0] is not None:
                hosts.append(other)
        finally:
            other_conn.close()
    if hosts:
        problems.append(f"Таблица ship_position найдена в другой базе: {', '.join(hosts)}. "
                        f"Запустите загрузчик с --dbname {hosts[0]} или выполните init.sql в базе «{db}».")
    else:
        problems.append("Если init.sql выполняли в DBeaver, проверьте, что подключение смотрит в базу "
                        f"«{db}» и что транзакция зафиксирована (Commit).")
    return problems


def show(value) -> str:
    """Значение для сообщения: строки в кавычках, числа без обёрток."""
    return repr(value) if isinstance(value, str) else str(value)


def describe_db_error(exc: psycopg2.Error) -> str:
    diag = exc.diag
    text = (diag.message_primary or str(exc)).strip()
    if diag.constraint_name:
        text += f" [ограничение {diag.constraint_name}]"
    # Для CHECK (23514) и NOT NULL (23502) детали содержат строку с внутренними id и только шумят.
    if diag.message_detail and exc.pgcode not in ("23514", "23502"):
        text += f" ({diag.message_detail.strip()})"
    return text


# ---------------------------------------------------------------------------
# Точка входа
# ---------------------------------------------------------------------------

def parse_args(argv=None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Импорт данных о судах из JSON в PostgreSQL (схема init.sql).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Параметры подключения берутся из аргументов, иначе из docker-compose.yml "
               "(найденного автоматически или указанного через --compose).")
    p.add_argument("files", nargs="+", type=Path, help="один или несколько JSON-файлов")
    p.add_argument("--compose", help="путь к docker-compose.yml с параметрами БД")
    p.add_argument("--host", help="хост БД (по умолчанию localhost)")
    p.add_argument("--port", type=int, help="порт БД (по умолчанию из compose или 5432)")
    p.add_argument("--user", help="пользователь БД")
    p.add_argument("--password", help="пароль (или переменная окружения PGPASSWORD)")
    p.add_argument("--dbname", help="имя базы (по умолчанию POSTGRES_DB, иначе имя пользователя)")
    p.add_argument("--dry-run", action="store_true", help="выполнить всё, но откатить изменения")
    p.add_argument("--strict", action="store_true",
                   help="при первой же ошибке откатить всю загрузку")
    p.add_argument("-v", "--verbose", action="store_true", help="подробный вывод")
    return p.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s: %(message)s")

    # Сначала читаем файлы: ошибка в файле не должна открывать соединение.
    batches: list[tuple[Path, list]] = []
    for path in args.files:
        if not path.is_file():
            log.error("Файл не найден: %s", path)
            return 2
        try:
            batches.append((path, load_json_file(path)))
        except ValueError as exc:
            log.error("%s", exc)
            return 2

    conn_params = resolve_connection(args)
    try:
        conn = psycopg2.connect(connect_timeout=5, **conn_params)
    except psycopg2.OperationalError as exc:
        log.error("Не удалось подключиться к %s:%s (база %s, пользователь %s): %s",
                  conn_params["host"], conn_params["port"], conn_params["dbname"],
                  conn_params["user"], str(exc).strip())
        return 2

    errors: list[str] = []
    importer = None
    try:
        cur = conn.cursor()
        problems = check_schema(cur, conn_params)
        if problems:
            for line in problems:
                log.error("%s", line)
            log.error("Сначала выполните init.sql в этой базе.")
            return 2

        importer = Importer(cur)
        total = accepted = 0
        aborted = False
        for path, records in batches:
            for index, raw in enumerate(records, start=1):
                total += 1
                label = f"{path.name}[{index}]"
                snap = importer.snapshot()
                cur.execute("SAVEPOINT record")
                try:
                    rec = normalize(raw)
                    label = f"{path.name}[{index}] imo={rec['imo']}"
                    importer.import_record(rec, label)
                    cur.execute("RELEASE SAVEPOINT record")
                    accepted += 1
                    log.debug("%s: загружена", label)
                except (ValueError, psycopg2.Error) as exc:
                    cur.execute("ROLLBACK TO SAVEPOINT record")
                    importer.restore(snap)
                    message = describe_db_error(exc) if isinstance(exc, psycopg2.Error) else str(exc)
                    errors.append(f"{label}: {message}")
                    log.error("%s: пропущена: %s", label, message)
                    if args.strict:
                        aborted = True
                        break
            if aborted:
                break

        rollback = args.dry_run or (args.strict and errors)
        if rollback:
            conn.rollback()
        else:
            conn.commit()
    finally:
        conn.close()

    # -- итог --------------------------------------------------------------
    rolled_back = args.dry_run or bool(args.strict and errors)
    print()
    print(f"Записей в файлах: {total}; обработано без ошибок: {accepted}; с ошибками: {len(errors)}")
    created_title = "Было бы создано строк (изменения отменены)" if rolled_back else "Создано строк"
    if importer.created:
        print(f"{created_title}: " + ", ".join(f"{t} {n}" for t, n in importer.created.items()))
    else:
        print("Новых строк не создано")
    if importer.existing:
        print("Уже были в БД (пропущены): " +
              ", ".join(f"{t} {n}" for t, n in importer.existing.items()))
    for warning in importer.warnings:
        log.warning("%s", warning)
    if args.dry_run:
        print("Режим --dry-run: изменения отменены.")
    elif args.strict and errors:
        print("Режим --strict: из-за ошибки вся загрузка отменена.")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
