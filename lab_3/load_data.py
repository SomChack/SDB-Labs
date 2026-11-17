#!/usr/bin/env python3
"""
Загрузка данных лабораторной №3 в БД из первой лабораторной (схема lab_3/init.sql).

Источники (лежат в lab_2/module_2):
    sea_zones.json  - границы акваторий (GeoJSON)
    port_data.csv   - заходы судов в порты (рейсы, компании-супервайзеры)
    ship_data.csv   - позиции судов (AIS)

Примеры запуска:
    python load_data.py
    python load_data.py --reset                    # очистить таблицы и загрузить заново
    python load_data.py --host localhost --port 5432 --user ships --password my_super_secret
    python load_data.py --dry-run                  # выполнить всё, но откатить изменения
"""
from __future__ import annotations

import argparse
import csv
import json
import logging
import os
import re
import sys
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path

import psycopg2
from psycopg2.extras import execute_values

log = logging.getLogger("load_data")

DEFAULT_DATA_DIR = Path(__file__).resolve().parent.parent / "lab_2" / "module_2"

ISO = {
    "643": ("RU", "RUS"), "616": ("PL", "POL"), "578": ("NO", "NOR"), "752": ("SE", "SWE"),
    "826": ("GB", "GBR"), "428": ("LV", "LVA"), "208": ("DK", "DNK"), "276": ("DE", "DEU"),
    "246": ("FI", "FIN"), "233": ("EE", "EST"), "440": ("LT", "LTU"), "528": ("NL", "NLD"),
    "056": ("BE", "BEL"), "250": ("FR", "FRA"), "724": ("ES", "ESP"), "620": ("PT", "PRT"),
    "380": ("IT", "ITA"), "300": ("GR", "GRC"), "792": ("TR", "TUR"), "804": ("UA", "UKR"),
    "112": ("BY", "BLR"), "156": ("CN", "CHN"), "392": ("JP", "JPN"), "410": ("KR", "KOR"),
    "840": ("US", "USA"), "124": ("CA", "CAN"), "352": ("IS", "ISL"), "372": ("IE", "IRL"),
    "470": ("MT", "MLT"), "196": ("CY", "CYP"), "702": ("SG", "SGP"), "591": ("PA", "PAN"),
    "430": ("LR", "LBR"), "584": ("MH", "MHL"), "044": ("BS", "BHS"),
}
ALPHA2_TO_ALPHA3 = {a2: a3 for a2, a3 in ISO.values()}

IMO_RE = re.compile(r"^[0-9]{7}$")
MMSI_RE = re.compile(r"^[0-9]{9}$")
CALL_SIGN_RE = re.compile(r"^[A-Z0-9]{3,10}$")
PORT_RE = re.compile(r"^[A-Z]{2}[A-Z0-9]{3}$")

NO_OPERATOR = "Оператор не указан"


def clean(value: str | None) -> str | None:
    value = (value or "").strip()
    return value or None


def parse_ts(value: str | None) -> datetime | None:
    value = clean(value)
    if value is None:
        return None
    return datetime.strptime(value, "%Y-%m-%d %H:%M:%S.%f").replace(tzinfo=timezone.utc)


def parse_num(value: str | None, lo=None, hi=None, hi_inclusive=True):
    value = clean(value)
    if value is None:
        return None
    try:
        num = Decimal(value)
    except InvalidOperation:
        return None
    if not num.is_finite():
        return None
    if lo is not None and num < lo:
        return None
    if hi is not None and (num > hi if hi_inclusive else num >= hi):
        return None
    return num


def parse_company(supervising: str | None) -> str | None:
    text = clean(supervising)
    if text is None:
        return None
    match = re.search(r"Название:(.*?)ИМО:", text, flags=re.S)
    if not match:
        return None
    name = re.sub(r"^\s*/\s*", "", match.group(1)).strip()
    return name or None


def point_in_ring(ring: list[tuple[float, float]], x: float, y: float) -> bool:
    inside = False
    j = len(ring) - 1
    for i in range(len(ring)):
        xi, yi = ring[i]
        xj, yj = ring[j]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
            inside = not inside
        j = i
    return inside


def load_sea_zones(path: Path) -> list[dict]:
    data = json.loads(path.read_text(encoding="utf-8-sig"))
    seas = []
    for feature in data["features"]:
        props = feature["properties"]
        ring = [(float(p[0]), float(p[1])) for p in feature["geometry"]["coordinates"][0]]
        seas.append({
            "name": props["sea_name"].strip(),
            "area": Decimal(str(props.get("sea_lenght") or props.get("area_km"))),
            "ring": ring,
        })
    return seas


def find_sea(seas: list[dict], lon: float, lat: float) -> int | None:
    best = None
    for sea in seas:
        if point_in_ring(sea["ring"], lon, lat) or (lon < 0 and point_in_ring(sea["ring"], lon + 360, lat)):
            if best is None or sea["area"] < best["area"]:
                best = sea
    return best["id"] if best else None


def read_csv(path: Path) -> list[dict]:
    with path.open(encoding="utf-8-sig", newline="") as fh:
        return list(csv.DictReader(fh))


def reset_tables(cur) -> None:
    cur.execute("""TRUNCATE ship_position, voyage, supervisor, company, port, ship, country,
                            nav_status, info_source, sea_ship_category, sea, ship_category, ship_type
                   RESTART IDENTITY CASCADE""")
    log.info("Таблицы очищены (RESTART IDENTITY)")


def get_ids(cur, table: str, column: str) -> dict:
    cur.execute(f"SELECT {column}, id FROM {table}")
    return dict(cur.fetchall())


def import_seas(cur, seas: list[dict]) -> None:
    created = 0
    for sea in seas:
        cur.execute("SELECT id, area_km FROM sea WHERE lower(name) = lower(%s)", (sea["name"],))
        row = cur.fetchone()
        if row is None:
            cur.execute("INSERT INTO sea (name, area_km) VALUES (%s, %s) RETURNING id",
                        (sea["name"], sea["area"]))
            sea["id"] = cur.fetchone()[0]
            created += 1
        else:
            sea["id"] = row[0]
            if row[1] is None:
                cur.execute("UPDATE sea SET area_km = %s WHERE id = %s", (sea["area"], row[0]))
    log.info("sea: в файле %d акваторий, создано %d, найдено в БД %d", len(seas), created, len(seas) - created)


def import_ports_and_voyages(cur, port_rows: list[dict], track_rows: list[dict], stats: dict) -> dict:
    calls = []
    for row in port_rows:
        imo = clean(row["ship_imo"])
        enter_port, dest_port = clean(row["enter_port"]), clean(row["destination_port"])
        eta = parse_ts(row["exit_date"])
        if not (imo and IMO_RE.match(imo) and enter_port and PORT_RE.match(enter_port)
                and dest_port and PORT_RE.match(dest_port) and eta):
            stats["port_data: отброшено (неверный IMO/порт/дата)"] += 1
            continue
        if enter_port == dest_port or enter_port[:2] not in ALPHA2_TO_ALPHA3 \
                or dest_port[:2] not in ALPHA2_TO_ALPHA3:
            stats["port_data: отброшено (совпадение портов/неизвестная страна)"] += 1
            continue
        calls.append({
            "imo": int(imo), "exit_port": enter_port, "dest_port": dest_port, "eta": eta,
            "enter_fact": parse_ts(row["enter_fact_date"]), "exit_fact": parse_ts(row["exit_fact_date"]),
            "follow": clean(row["destination_country"]), "company": parse_company(row["supervising"]),
            "mmsi": clean(row["ship_mmsi"]), "call_sign": clean(row["ship_callsign"]),
            "name": clean(row["ship_name"]), "name_lat": clean(row["ship_name_lat"]),
        })

    alpha3 = {ALPHA2_TO_ALPHA3[c["exit_port"][:2]] for c in calls}
    alpha3 |= {ALPHA2_TO_ALPHA3[c["dest_port"][:2]] for c in calls}
    alpha3 |= {ALPHA2_TO_ALPHA3[c["follow"]] for c in calls if c["follow"] in ALPHA2_TO_ALPHA3}
    alpha3 |= {ISO[r["flag"].strip()][1] for r in track_rows if r["flag"].strip() in ISO}
    execute_values(cur, "INSERT INTO country (code) VALUES %s ON CONFLICT (code) DO NOTHING",
                   [(c,) for c in sorted(alpha3)])
    country = get_ids(cur, "country", "code")

    sources = sorted({clean(r["asource"]) for r in track_rows} - {None})
    execute_values(cur, "INSERT INTO info_source (name) VALUES %s ON CONFLICT (name) DO NOTHING",
                   [(s,) for s in sources])
    statuses = sorted({clean(r["nav_status"]) for r in track_rows} - {None})
    execute_values(cur, "INSERT INTO nav_status (name) VALUES %s ON CONFLICT (name) DO NOTHING",
                   [(s,) for s in statuses])

    companies = sorted({c["company"] for c in calls} - {None})
    execute_values(cur, "INSERT INTO company (name) VALUES %s ON CONFLICT (name) DO NOTHING",
                   [(c,) for c in companies])
    company = get_ids(cur, "company", "name")
    execute_values(cur, "INSERT INTO supervisor (name, company_id) VALUES %s ON CONFLICT DO NOTHING",
                   [(NO_OPERATOR, company[c]) for c in companies])
    cur.execute("SELECT company_id, id FROM supervisor WHERE name = %s", (NO_OPERATOR,))
    supervisor = dict(cur.fetchall())

    ports = sorted({c["exit_port"] for c in calls} | {c["dest_port"] for c in calls})
    execute_values(cur, "INSERT INTO port (name, country_id) VALUES %s ON CONFLICT DO NOTHING",
                   [(p, country[ALPHA2_TO_ALPHA3[p[:2]]]) for p in ports])
    cur.execute("SELECT name, id FROM port")
    port = dict(cur.fetchall())

    ships: dict[int, dict] = {}
    for r in sorted(track_rows, key=lambda r: r["receive_date"]):
        imo = clean(r["imo"])
        if not (imo and IMO_RE.match(imo)):
            continue
        flag = clean(r["flag"])
        ships[int(imo)] = {
            "mmsi": clean(r["mmsi"]), "call_sign": clean(r["call_sign"]),
            "name": clean(r["shipname"]), "name_lat": clean(r["shipname_lat"]),
            "flag": country[ISO[flag][1]] if flag in ISO else None,
        }
    for c in sorted(calls, key=lambda c: c["eta"]):
        ship = ships.setdefault(c["imo"], {"mmsi": None, "call_sign": None, "name": None,
                                           "name_lat": None, "flag": None})
        for key in ("mmsi", "call_sign", "name", "name_lat"):
            ship[key] = ship[key] or c[key]
    cur.execute("SELECT imo, mmsi, call_sign FROM ship")
    existing = cur.fetchall()
    known_imo = {r[0] for r in existing}
    seen_mmsi = {r[1] for r in existing if r[1]}
    seen_call = {r[2] for r in existing if r[2]}
    rows = []
    for imo in sorted(ships):
        if imo in known_imo:
            continue
        s = ships[imo]
        mmsi = s["mmsi"] if s["mmsi"] and MMSI_RE.match(s["mmsi"]) and s["mmsi"] not in seen_mmsi else None
        call = s["call_sign"] if s["call_sign"] and CALL_SIGN_RE.match(s["call_sign"]) \
            and s["call_sign"] not in seen_call else None
        seen_mmsi.add(mmsi)
        seen_call.add(call)
        rows.append((imo, mmsi, call, s["name"], s["name_lat"], s["flag"]))
    execute_values(cur, """INSERT INTO ship (imo, mmsi, call_sign, name, name_lat, flag_country_id)
                           VALUES %s ON CONFLICT (imo) DO NOTHING""", rows)
    stats["ship (новых)"] = len(rows)

    voyages: dict[tuple, dict] = {}
    for c in calls:
        key = (c["imo"], port[c["exit_port"]], port[c["dest_port"]], c["eta"])
        v = voyages.setdefault(key, {"follow": None, "company": None, "enter_fact": None, "exit_fact": None})
        v["follow"] = v["follow"] or (country[ALPHA2_TO_ALPHA3[c["follow"]]]
                                       if c["follow"] in ALPHA2_TO_ALPHA3 else None)
        v["company"] = v["company"] or c["company"]
        if c["enter_fact"] and (v["enter_fact"] is None or c["enter_fact"] < v["enter_fact"]):
            v["enter_fact"] = c["enter_fact"]
        if c["exit_fact"] and (v["exit_fact"] is None or c["exit_fact"] > v["exit_fact"]):
            v["exit_fact"] = c["exit_fact"]
    stats["port_data: строк, пригодных для рейсов"] = len(calls)
    keys = sorted(voyages)
    execute_values(cur, """INSERT INTO voyage (ship_imo, exit_port_id, destination_port_id, eta,
                                               country_follow_id, supervisor_id)
                           VALUES %s ON CONFLICT ON CONSTRAINT uq_voyage_plan DO NOTHING""",
                   [(k[0], k[1], k[2], k[3], voyages[k]["follow"],
                     supervisor.get(company.get(voyages[k]["company"]))) for k in keys])
    stats["voyage (плановые)"] = len(keys)
    cur.execute("SELECT ship_imo, exit_port_id, destination_port_id, eta, id FROM voyage")
    voyage_id = {(r[0], r[1], r[2], r[3]): r[4] for r in cur.fetchall()}

    track_imos = sorted({int(r["imo"]) for r in track_rows if IMO_RE.match(clean(r["imo"]) or "")})
    execute_values(cur, """INSERT INTO voyage (ship_imo, is_service) VALUES %s
                           ON CONFLICT (ship_imo) WHERE is_service DO NOTHING""",
                   [(i, True) for i in track_imos])
    cur.execute("SELECT ship_imo, id FROM voyage WHERE is_service")
    service = dict(cur.fetchall())
    stats["voyage (служебные)"] = len(service)

    windows: dict[int, list] = {}
    for k in keys:
        v = voyages[k]
        if v["enter_fact"] and v["exit_fact"]:
            windows.setdefault(k[0], []).append((v["enter_fact"], v["exit_fact"], voyage_id[k]))
    for items in windows.values():
        items.sort()
    return {"windows": windows, "service": service, "info_source": get_ids(cur, "info_source", "name"),
            "nav_status": get_ids(cur, "nav_status", "name")}


def pick_voyage(windows: list, service_id: int, ts: datetime) -> tuple[int, bool]:
    hits = [(start, vid) for start, end, vid in windows if start <= ts <= end]
    if hits:
        return max(hits)[1], True
    return service_id, False


def import_positions(cur, track_rows: list[dict], ctx: dict, seas: list[dict], stats: dict) -> None:
    rows, seen = [], set()
    for r in sorted(track_rows, key=lambda r: (r["imo"], r["receive_date"], r["asource"])):
        imo = clean(r["imo"])
        ts = parse_ts(r["receive_date"])
        lon, lat = parse_num(r["longitude"], -180, 180), parse_num(r["latitude"], -90, 90)
        source = clean(r["asource"])
        if not (imo and IMO_RE.match(imo) and ts and lon is not None and lat is not None and source):
            stats["ship_data: отброшено (нет IMO/времени/координат/источника)"] += 1
            continue
        vid, planned = pick_voyage(ctx["windows"].get(int(imo), []), ctx["service"][int(imo)], ts)
        if (vid, ts) in seen:
            stats["ship_data: отброшено (дубликат судно + время)"] += 1
            continue
        seen.add((vid, ts))
        stats["ship_position: привязано к плановому рейсу" if planned
              else "ship_position: привязано к служебному рейсу"] += 1
        heading = parse_num(r["heading"], 0, 360, hi_inclusive=False)
        rows.append((
            vid, ts, ctx["info_source"][source], round(lat, 6), round(lon, 6),
            parse_num(r["speed"], 0, 100), parse_num(r["course"], 0, 360, hi_inclusive=False),
            parse_num(r["rot"], -720, 720), round(heading) if heading is not None else None,
            ctx["nav_status"].get(clean(r["nav_status"])), find_sea(seas, float(lon), float(lat)),
        ))
    cur.execute("SELECT count(*) FROM ship_position")
    before = cur.fetchone()[0]
    execute_values(cur, """INSERT INTO ship_position
                               (voyage_id, received_at, info_source_id, latitude, longitude,
                                speed, course, rot, heading, nav_status_id, sea_id)
                           VALUES %s ON CONFLICT ON CONSTRAINT uq_ship_position_voyage_time DO NOTHING""",
                   rows, page_size=5000)
    cur.execute("SELECT count(*) FROM ship_position")
    stats["ship_position (добавлено в таблицу)"] = cur.fetchone()[0] - before


def parse_args(argv=None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Загрузка sea_zones.json, port_data.csv, ship_data.csv в PostgreSQL.")
    p.add_argument("--data-dir", type=Path, default=DEFAULT_DATA_DIR,
                   help=f"папка с файлами данных (по умолчанию {DEFAULT_DATA_DIR})")
    p.add_argument("--host", default=os.environ.get("PGHOST", "localhost"))
    p.add_argument("--port", type=int, default=int(os.environ.get("PGPORT", 5432)))
    p.add_argument("--user", default=os.environ.get("PGUSER", "ships"))
    p.add_argument("--password", default=os.environ.get("PGPASSWORD", "my_super_secret"))
    p.add_argument("--dbname", default=os.environ.get("PGDATABASE", "ships"))
    p.add_argument("--reset", action="store_true", help="очистить таблицы перед загрузкой")
    p.add_argument("--dry-run", action="store_true", help="выполнить всё, но откатить изменения")
    return p.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
    files = {name: args.data_dir / name for name in ("sea_zones.json", "port_data.csv", "ship_data.csv")}
    for path in files.values():
        if not path.is_file():
            log.error("Файл не найден: %s", path)
            return 2

    try:
        conn = psycopg2.connect(host=args.host, port=args.port, user=args.user,
                                password=args.password, dbname=args.dbname, connect_timeout=5)
    except psycopg2.OperationalError as exc:
        log.error("Не удалось подключиться к БД: %s", str(exc).strip())
        return 2

    stats: dict[str, int] = {k: 0 for k in (
        "port_data: отброшено (неверный IMO/порт/дата)",
        "port_data: отброшено (совпадение портов/неизвестная страна)",
        "ship_data: отброшено (нет IMO/времени/координат/источника)",
        "ship_position: привязано к плановому рейсу", "ship_position: привязано к служебному рейсу",
        "ship_data: отброшено (дубликат судно + время)")}
    try:
        with conn:
            cur = conn.cursor()
            cur.execute("SELECT to_regclass('public.ship_position')")
            if cur.fetchone()[0] is None:
                log.error("В БД нет таблицы ship_position. Сначала выполните init.sql.")
                return 2
            if args.reset:
                reset_tables(cur)
            seas = load_sea_zones(files["sea_zones.json"])
            port_rows, track_rows = read_csv(files["port_data.csv"]), read_csv(files["ship_data.csv"])
            log.info("Прочитано: port_data %d строк, ship_data %d строк", len(port_rows), len(track_rows))
            import_seas(cur, seas)
            ctx = import_ports_and_voyages(cur, port_rows, track_rows, stats)
            import_positions(cur, track_rows, ctx, seas, stats)
            if args.dry_run:
                conn.rollback()
                log.info("Режим --dry-run: изменения отменены")
    except psycopg2.Error as exc:
        log.error("Ошибка БД, загрузка отменена: %s", (exc.diag.message_primary or str(exc)).strip())
        return 1
    finally:
        conn.close()

    print("\nИтоги загрузки:")
    for key, value in stats.items():
        print(f"  {key}: {value}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
