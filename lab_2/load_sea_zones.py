#!/usr/bin/env python3
"""
    python load_sea_zones.py
    python load_sea_zones.py module_2/sea_zones.json --compose docker-compose.yml
    python load_sea_zones.py --host localhost --port 5432 --user ships --password my_super_secret
    python load_sea_zones.py --dry-run
"""
from __future__ import annotations

import argparse
import json
import logging
import os
import sys
from decimal import Decimal, InvalidOperation
from pathlib import Path

import psycopg2
import yaml

log = logging.getLogger("load_sea_zones")

DEFAULT_JSON = Path(__file__).resolve().parent / "module_2" / "sea_zones.json"

AREA_KEYS = ("sea_lenght", "sea_length", "area_km")
LON_RANGE = (Decimal(-180), Decimal(360)) 
LAT_RANGE = (Decimal(-90), Decimal(90))


def read_compose(path: Path, service: str = "db") -> dict:
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    svc = (data.get("services") or {}).get(service) or {}
    env = svc.get("environment") or {}
    if isinstance(env, list):  
        env = dict(item.split("=", 1) for item in env if "=" in item)
    found: dict = {}
    for key, name in (("POSTGRES_USER", "user"), ("POSTGRES_PASSWORD", "password"),
                      ("POSTGRES_DB", "dbname")):
        if env.get(key):
            found[name] = str(env[key])
    for mapping in svc.get("ports") or []:
        host_port, _, container_port = str(mapping).rpartition(":")
        if container_port.split("/")[0] == "5432" and host_port.split(":")[-1].isdigit():
            found["port"] = int(host_port.split(":")[-1])
            break
    return found


def find_compose_file(explicit: str | None) -> Path | None:
    if explicit:
        path = Path(explicit)
        if not path.is_file():
            raise SystemExit(f"Файл docker-compose не найден: {path}")
        return path
    here = Path(__file__).resolve().parent
    for folder in (Path.cwd(), here):
        for name in ("docker-compose.yml", "docker-compose.yaml"):
            if (folder / name).is_file():
                return folder / name
    return None


def resolve_connection(args: argparse.Namespace) -> dict:

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
        # POSTGRES_DB для основной БД не задан, поэтому база называется как пользователь
        "dbname": args.dbname or compose.get("dbname") or user,
    }



def to_decimal(value, what: str) -> Decimal:
    try:
        result = Decimal(str(value))
    except InvalidOperation:
        raise ValueError(f"{what}: не число ({value!r})")
    if not result.is_finite():
        raise ValueError(f"{what}: недопустимое число ({value!r})")
    return result


def parse_feature(feature: dict) -> dict:
    """Возвращает {'name', 'area', 'points': [(lon, lat), ...]} или бросает ValueError."""
    if not isinstance(feature, dict) or feature.get("type") != "Feature":
        raise ValueError("элемент features не является Feature")
    props = feature.get("properties") or {}
    name = str(props.get("sea_name") or "").strip()
    if not name:
        raise ValueError("нет свойства sea_name")

    area = None
    for key in AREA_KEYS:
        if props.get(key) not in (None, ""):
            area = to_decimal(props[key], f"свойство {key}")
            if area <= 0:
                raise ValueError(f"свойство {key}: площадь должна быть положительной ({area})")
            break

    geometry = feature.get("geometry") or {}
    if geometry.get("type") != "Polygon":
        raise ValueError(f"поддерживается только Polygon, получено {geometry.get('type')!r}")
    rings = geometry.get("coordinates") or []
    if len(rings) != 1:
        raise ValueError(f"ожидалось одно внешнее кольцо без дыр, получено колец: {len(rings)}")

    ring = [tuple(to_decimal(c, "координата") for c in pos[:2]) for pos in rings[0]]
    if len(ring) < 4:
        raise ValueError("в кольце меньше 4 позиций (3 вершины + замыкающая)")
    if ring[0] != ring[-1]:
        raise ValueError("кольцо не замкнуто: первая и последняя позиции различаются")
    points = ring[:-1]
    if len(set(points)) != len(points):
        raise ValueError("в кольце есть повторяющиеся вершины")
    for lon, lat in points:
        if not LON_RANGE[0] <= lon <= LON_RANGE[1]:
            raise ValueError(f"долгота вне диапазона [{LON_RANGE[0]}; {LON_RANGE[1]}]: {lon}")
        if not LAT_RANGE[0] <= lat <= LAT_RANGE[1]:
            raise ValueError(f"широта вне диапазона [{LAT_RANGE[0]}; {LAT_RANGE[1]}]: {lat}")
    return {"name": name, "area": area, "points": points}


def load_features(path: Path) -> list:
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
    except json.JSONDecodeError as exc:
        raise ValueError(f"{path}: некорректный JSON (строка {exc.lineno}, столбец {exc.colno}): {exc.msg}")
    if not isinstance(data, dict) or data.get("type") != "FeatureCollection":
        raise ValueError(f"{path}: ожидался GeoJSON FeatureCollection")
    features = data.get("features")
    if not isinstance(features, list):
        raise ValueError(f"{path}: нет списка features")
    return features

def check_schema(cur) -> list[str]:
    cur.execute("SELECT to_regclass('public.sea_boundary_point'), to_regproc('fn_refresh_sea_geom')")
    table, func = cur.fetchone()
    problems = []
    if table is None:
        problems.append("Нет таблицы sea_boundary_point.")
    if func is None:
        problems.append("Нет функции fn_refresh_sea_geom().")
    if problems:
        problems.append("Сначала выполните init.sql из lab_2 в этой базе.")
    return problems


def import_sea(cur, sea: dict, stats: dict, warnings: list[str]) -> None:
    cur.execute("SELECT id, area_km FROM sea WHERE lower(name) = lower(%s)", [sea["name"]])
    row = cur.fetchone()
    if row is None:
        cur.execute("INSERT INTO sea (name, area_km) VALUES (%s, %s) RETURNING id",
                    [sea["name"], sea["area"]])
        sea_id = cur.fetchone()[0]
        stats["sea создано"] += 1
    else:
        sea_id, db_area = row
        if sea["area"] is not None:
            if db_area is None:
                cur.execute("UPDATE sea SET area_km = %s WHERE id = %s", [sea["area"], sea_id])
                stats["sea дополнено (площадь)"] += 1
            elif db_area != sea["area"].quantize(Decimal("0.01")):
                warnings.append(f"{sea['name']}: площадь в БД {db_area}, в файле {sea['area']}; "
                                "оставлено значение из БД")
        stats["sea найдено"] += 1

    cur.execute("DELETE FROM sea_boundary_point WHERE sea_id = %s", [sea_id])
    cur.executemany(
        "INSERT INTO sea_boundary_point (sea_id, point_no, longitude, latitude) VALUES (%s, %s, %s, %s)",
        [(sea_id, no, lon, lat) for no, (lon, lat) in enumerate(sea["points"], start=1)])
    stats["вершин записано"] += len(sea["points"])


def describe_db_error(exc: psycopg2.Error) -> str:
    diag = exc.diag
    text = (diag.message_primary or str(exc)).strip()
    if diag.constraint_name:
        text += f" [ограничение {diag.constraint_name}]"
    return text

def parse_args(argv=None) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Загрузка границ акваторий из GeoJSON в PostgreSQL (схема init.sql, lab_2).")
    p.add_argument("file", nargs="?", type=Path, default=DEFAULT_JSON,
                   help=f"GeoJSON-файл (по умолчанию {DEFAULT_JSON.name} из module_2)")
    p.add_argument("--compose", help="путь к docker-compose.yml с параметрами БД")
    p.add_argument("--host", help="хост БД (по умолчанию localhost)")
    p.add_argument("--port", type=int, help="порт БД (по умолчанию из compose или 5432)")
    p.add_argument("--user", help="пользователь БД")
    p.add_argument("--password", help="пароль (или переменная окружения PGPASSWORD)")
    p.add_argument("--dbname", help="имя базы (по умолчанию POSTGRES_DB, иначе имя пользователя)")
    p.add_argument("--dry-run", action="store_true", help="выполнить всё, но откатить изменения")
    p.add_argument("--strict", action="store_true", help="при первой ошибке откатить всю загрузку")
    p.add_argument("-v", "--verbose", action="store_true", help="подробный вывод")
    return p.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(levelname)s: %(message)s")

    if not args.file.is_file():
        log.error("Файл не найден: %s", args.file)
        return 2
    try:
        features = load_features(args.file)
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

    stats = {"sea создано": 0, "sea найдено": 0, "sea дополнено (площадь)": 0, "вершин записано": 0}
    errors: list[str] = []
    warnings: list[str] = []
    accepted = 0
    try:
        cur = conn.cursor()
        problems = check_schema(cur)
        if problems:
            for line in problems:
                log.error("%s", line)
            return 2

        for index, feature in enumerate(features, start=1):
            label = f"{args.file.name}[{index}]"
            stats_before, warnings_before = dict(stats), len(warnings)
            cur.execute("SAVEPOINT feature")
            try:
                sea = parse_feature(feature)
                label = f"{args.file.name}[{index}] {sea['name']}"
                import_sea(cur, sea, stats, warnings)
                cur.execute("RELEASE SAVEPOINT feature")
                accepted += 1
                log.debug("%s: загружена, вершин: %d", label, len(sea["points"]))
            except (ValueError, psycopg2.Error) as exc:
                cur.execute("ROLLBACK TO SAVEPOINT feature")
                stats.update(stats_before)          # откат счётчиков вместе с точкой сохранения
                del warnings[warnings_before:]
                message = describe_db_error(exc) if isinstance(exc, psycopg2.Error) else str(exc)
                errors.append(f"{label}: {message}")
                log.error("%s: пропущена: %s", label, message)
                if args.strict:
                    break

        if args.dry_run or (args.strict and errors):
            conn.rollback()
        else:
            cur.execute("SELECT fn_refresh_sea_geom()")   # пересборка геометрии из вершин
            cur.execute("SELECT count(*) FROM sea_geom")
            geom_count = cur.fetchone()[0]
            conn.commit()
            log.info("Материализованное представление sea_geom обновлено: акваторий с геометрией %d",
                     geom_count)
    finally:
        conn.close()

    rolled_back = args.dry_run or bool(args.strict and errors)
    print()
    print(f"Акваторий в файле: {len(features)}; загружено без ошибок: {accepted}; с ошибками: {len(errors)}")
    print(("Было бы записано (изменения отменены): " if rolled_back else "Записано: ")
          + ", ".join(f"{k} {v}" for k, v in stats.items()))
    for warning in warnings:
        log.warning("%s", warning)
    if args.dry_run:
        print("Режим --dry-run: изменения отменены.")
    elif args.strict and errors:
        print("Режим --strict: из-за ошибки вся загрузка отменена.")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
