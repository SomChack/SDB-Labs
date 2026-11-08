CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgres_fdw;

-- Страны
CREATE TABLE country (
    id    INTEGER GENERATED ALWAYS AS IDENTITY,
    code  VARCHAR(10) NOT NULL,
    CONSTRAINT pk_country PRIMARY KEY (id),
    CONSTRAINT uq_country_code UNIQUE (code),
    CONSTRAINT chk_country_code_format CHECK (code ~ '^[A-Z]{2,3}$')
);

-- Типы судов
CREATE TABLE ship_type (
    id    INTEGER GENERATED ALWAYS AS IDENTITY,
    name  VARCHAR(255) NOT NULL,
    CONSTRAINT pk_ship_type PRIMARY KEY (id),
    CONSTRAINT uq_ship_type_name UNIQUE (name),
    CONSTRAINT chk_ship_type_name_clean CHECK (name <> '' AND name = btrim(name))
);

-- Навигационные статусы
CREATE TABLE nav_status (
    id    INTEGER GENERATED ALWAYS AS IDENTITY,
    name  VARCHAR(100) NOT NULL,
    CONSTRAINT pk_nav_status PRIMARY KEY (id),
    CONSTRAINT uq_nav_status_name UNIQUE (name),
    CONSTRAINT chk_nav_status_name_clean CHECK (name <> '' AND name = btrim(name))
);

-- Источники данных о положении судов
CREATE TABLE info_source (
    id    INTEGER GENERATED ALWAYS AS IDENTITY,
    name  VARCHAR(255) NOT NULL,
    CONSTRAINT pk_info_source PRIMARY KEY (id),
    CONSTRAINT uq_info_source_name UNIQUE (name),
    CONSTRAINT chk_info_source_name_clean CHECK (name <> '' AND name = btrim(name))
);

-- Компании-супервайзеры
CREATE TABLE company (
    id    INTEGER GENERATED ALWAYS AS IDENTITY,
    name  VARCHAR(255) NOT NULL,
    CONSTRAINT pk_company PRIMARY KEY (id),
    CONSTRAINT uq_company_name UNIQUE (name),
    CONSTRAINT chk_company_name_clean CHECK (name <> '' AND name = btrim(name))
);

-- Категории судов, допущенных к плаванию в акватории
CREATE TABLE ship_category (
    id    INTEGER GENERATED ALWAYS AS IDENTITY,
    name  VARCHAR(100) NOT NULL,
    CONSTRAINT pk_ship_category PRIMARY KEY (id),
    CONSTRAINT uq_ship_category_name UNIQUE (name),
    CONSTRAINT chk_ship_category_name_clean CHECK (name <> '' AND name = btrim(name))
);

CREATE TABLE iso_country (
    numeric_code  CHAR(3) NOT NULL,
    alpha2        CHAR(2) NOT NULL,
    alpha3        CHAR(3) NOT NULL,
    CONSTRAINT pk_iso_country PRIMARY KEY (numeric_code),
    CONSTRAINT uq_iso_country_alpha2 UNIQUE (alpha2),
    CONSTRAINT uq_iso_country_alpha3 UNIQUE (alpha3),
    CONSTRAINT chk_iso_country_numeric CHECK (numeric_code ~ '^[0-9]{3}$'),
    CONSTRAINT chk_iso_country_alpha2 CHECK (alpha2 ~ '^[A-Z]{2}$'),
    CONSTRAINT chk_iso_country_alpha3 CHECK (alpha3 ~ '^[A-Z]{3}$')
);

INSERT INTO iso_country (numeric_code, alpha2, alpha3) VALUES
    ('643', 'RU', 'RUS'), ('616', 'PL', 'POL'), ('578', 'NO', 'NOR'), ('752', 'SE', 'SWE'),
    ('826', 'GB', 'GBR'), ('428', 'LV', 'LVA'), ('208', 'DK', 'DNK'), ('276', 'DE', 'DEU'),
    ('246', 'FI', 'FIN'), ('233', 'EE', 'EST'), ('440', 'LT', 'LTU'), ('528', 'NL', 'NLD'),
    ('056', 'BE', 'BEL'), ('250', 'FR', 'FRA'), ('724', 'ES', 'ESP'), ('620', 'PT', 'PRT'),
    ('380', 'IT', 'ITA'), ('300', 'GR', 'GRC'), ('792', 'TR', 'TUR'), ('804', 'UA', 'UKR'),
    ('112', 'BY', 'BLR'), ('156', 'CN', 'CHN'), ('392', 'JP', 'JPN'), ('410', 'KR', 'KOR'),
    ('840', 'US', 'USA'), ('124', 'CA', 'CAN'), ('352', 'IS', 'ISL'), ('372', 'IE', 'IRL'),
    ('470', 'MT', 'MLT'), ('196', 'CY', 'CYP'), ('702', 'SG', 'SGP'), ('591', 'PA', 'PAN'),
    ('430', 'LR', 'LBR'), ('584', 'MH', 'MHL'), ('044', 'BS', 'BHS');

-- ------------------------------------------------------------
-- АКВАТОРИИ И ГРАНИЦЫ
-- ------------------------------------------------------------

CREATE TABLE sea (
    id       INTEGER GENERATED ALWAYS AS IDENTITY,
    name     VARCHAR(255) NOT NULL,
    area_km  NUMERIC(14, 2),
    CONSTRAINT pk_sea PRIMARY KEY (id),
    CONSTRAINT uq_sea_name UNIQUE (name),
    CONSTRAINT chk_sea_name_clean CHECK (name <> '' AND name = btrim(name)),
    CONSTRAINT chk_sea_area_range CHECK (area_km > 0 AND area_km <= 361000000)
);

CREATE TABLE sea_ship_category (
    sea_id            INTEGER NOT NULL,
    ship_category_id  INTEGER NOT NULL,
    CONSTRAINT pk_sea_ship_category PRIMARY KEY (sea_id, ship_category_id),
    CONSTRAINT fk_sea_ship_category_sea FOREIGN KEY (sea_id)
        REFERENCES sea (id) ON DELETE CASCADE,
    CONSTRAINT fk_sea_ship_category_category FOREIGN KEY (ship_category_id)
        REFERENCES ship_category (id) ON DELETE CASCADE
);

CREATE TABLE sea_boundary_point (
    sea_id     INTEGER NOT NULL,
    point_no   SMALLINT NOT NULL,
    longitude  NUMERIC(13, 10) NOT NULL,
    latitude   NUMERIC(13, 10) NOT NULL,
    CONSTRAINT pk_sea_boundary_point PRIMARY KEY (sea_id, point_no),
    CONSTRAINT uq_sea_boundary_point_coords UNIQUE (sea_id, longitude, latitude),
    CONSTRAINT chk_sea_boundary_point_no CHECK (point_no >= 1),
    CONSTRAINT chk_sea_boundary_latitude CHECK (latitude BETWEEN -90 AND 90),
    -- верхняя граница 360: многоугольник Arctic Ocean переходит через 180-й меридиан (187.04)
    CONSTRAINT chk_sea_boundary_longitude CHECK (longitude BETWEEN -180 AND 360),
    CONSTRAINT fk_sea_boundary_point_sea FOREIGN KEY (sea_id)
        REFERENCES sea (id) ON DELETE CASCADE
);

CREATE MATERIALIZED VIEW sea_geom AS
SELECT s.id AS sea_id,
       s.name AS sea_name,
       ST_MakePolygon(ST_AddPoint(b.line, ST_StartPoint(b.line)))::geometry(Polygon, 4326) AS geom
  FROM sea s
  JOIN LATERAL (
        SELECT ST_MakeLine(ST_SetSRID(ST_MakePoint(p.longitude::float8, p.latitude::float8), 4326)
                           ORDER BY p.point_no) AS line
          FROM sea_boundary_point p
         WHERE p.sea_id = s.id
        HAVING count(*) >= 3
       ) b ON true;

CREATE UNIQUE INDEX uq_sea_geom_sea ON sea_geom (sea_id);
CREATE INDEX idx_sea_geom_geom ON sea_geom USING GIST (geom);

-- ------------------------------------------------------------
-- ПОРТЫ, КОМПАНИИ, ОПЕРАТОРЫ
-- ------------------------------------------------------------

-- Порт выхода и назначения
CREATE TABLE port (
    id          INTEGER GENERATED ALWAYS AS IDENTITY,
    name        VARCHAR(255) NOT NULL,
    country_id  INTEGER NOT NULL,
    CONSTRAINT pk_port PRIMARY KEY (id),
    -- название порта неуникально в мире, уникальна пара (название, страна)
    CONSTRAINT uq_port_name_country UNIQUE (name, country_id),
    CONSTRAINT chk_port_name_clean CHECK (name <> '' AND name = btrim(name)),
    CONSTRAINT fk_port_country FOREIGN KEY (country_id)
        REFERENCES country (id) ON DELETE RESTRICT
);

-- Операторы сопровождения плавания
CREATE TABLE supervisor (
    id          INTEGER GENERATED ALWAYS AS IDENTITY,
    name        VARCHAR(255) NOT NULL,
    company_id  INTEGER NOT NULL,
    CONSTRAINT pk_supervisor PRIMARY KEY (id),
    CONSTRAINT uq_supervisor_company_name UNIQUE (company_id, name),
    CONSTRAINT chk_supervisor_name_clean CHECK (name <> '' AND name = btrim(name)),
    CONSTRAINT fk_supervisor_company FOREIGN KEY (company_id)
        REFERENCES company (id) ON DELETE RESTRICT
);

-- ------------------------------------------------------------
-- СУДА, РЕЙСЫ, ПОЗИЦИИ
-- ------------------------------------------------------------

-- Судно
CREATE TABLE ship (
    imo               INTEGER NOT NULL,
    mmsi              VARCHAR(9),      -- строка: MMSI может начинаться с нуля
    call_sign         VARCHAR(20),
    name              VARCHAR(255),
    name_lat          VARCHAR(255),    -- международное имя, не выводится из name
    flag_country_id   INTEGER,         -- страна производитель (поле flag)
    owner_country_id  INTEGER,         -- страна владелец (поле сountry)
    ship_type_id      INTEGER,
    -- НОВОЕ: вычисляемый столбец целостности IMO.
    -- Шесть первых цифр умножаются на 7, 6, 5, 4, 3, 2 (т.е. на 2..7 справа налево,
    -- не считая контрольной цифры); последняя цифра суммы должна совпасть
    -- с контрольной (седьмой) цифрой номера.
    imo_valid         BOOLEAN GENERATED ALWAYS AS (
        imo BETWEEN 1000000 AND 9999999
        AND ( ((imo / 1000000) % 10) * 7
            + ((imo / 100000)  % 10) * 6
            + ((imo / 10000)   % 10) * 5
            + ((imo / 1000)    % 10) * 4
            + ((imo / 100)     % 10) * 3
            + ((imo / 10)      % 10) * 2 ) % 10 = imo % 10
    ) STORED,
    CONSTRAINT pk_ship PRIMARY KEY (imo),
    CONSTRAINT uq_ship_mmsi UNIQUE (mmsi),
    CONSTRAINT uq_ship_call_sign UNIQUE (call_sign),
    -- диапазон проверяется, а контрольная цифра нет: неверный IMO должен
    -- загружаться и помечаться imo_valid = false, а не отбрасываться
    CONSTRAINT chk_ship_imo_range CHECK (imo BETWEEN 1000000 AND 9999999),
    CONSTRAINT chk_ship_mmsi_format CHECK (mmsi ~ '^[0-9]{9}$'),
    CONSTRAINT chk_ship_call_sign_format CHECK (call_sign ~ '^[A-Z0-9]{3,10}$'),
    CONSTRAINT chk_ship_name_clean CHECK (name <> '' AND name = btrim(name)),
    CONSTRAINT chk_ship_name_lat_clean CHECK (name_lat <> '' AND name_lat = btrim(name_lat)),
    CONSTRAINT fk_ship_flag_country FOREIGN KEY (flag_country_id)
        REFERENCES country (id) ON DELETE RESTRICT,
    CONSTRAINT fk_ship_owner_country FOREIGN KEY (owner_country_id)
        REFERENCES country (id) ON DELETE RESTRICT,
    CONSTRAINT fk_ship_ship_type FOREIGN KEY (ship_type_id)
        REFERENCES ship_type (id) ON DELETE RESTRICT
);

-- Рейс судна
CREATE TABLE voyage (
    id                   BIGINT GENERATED ALWAYS AS IDENTITY,
    ship_imo             INTEGER NOT NULL,
    exit_port_id         INTEGER,
    destination_port_id  INTEGER,
    eta                  TIMESTAMPTZ,
    country_follow_id    INTEGER,       -- страна следования, не выводится из порта назначения
    supervisor_id        INTEGER,       -- компания определяется через оператора
    is_service           BOOLEAN NOT NULL DEFAULT false,
    CONSTRAINT pk_voyage PRIMARY KEY (id),
    CONSTRAINT chk_voyage_plan_complete CHECK (
        is_service OR (exit_port_id IS NOT NULL AND destination_port_id IS NOT NULL AND eta IS NOT NULL)),
    CONSTRAINT chk_voyage_service_empty CHECK (
        NOT is_service OR (exit_port_id IS NULL AND destination_port_id IS NULL AND eta IS NULL)),
    CONSTRAINT chk_voyage_eta_range CHECK (eta >= TIMESTAMPTZ '2000-01-01 00:00:00+00'
                                       AND eta <  TIMESTAMPTZ '2100-01-01 00:00:00+00'),
    CONSTRAINT fk_voyage_ship FOREIGN KEY (ship_imo)
        REFERENCES ship (imo) ON DELETE CASCADE,
    CONSTRAINT fk_voyage_exit_port FOREIGN KEY (exit_port_id)
        REFERENCES port (id) ON DELETE RESTRICT,
    CONSTRAINT fk_voyage_destination_port FOREIGN KEY (destination_port_id)
        REFERENCES port (id) ON DELETE RESTRICT,
    CONSTRAINT fk_voyage_country_follow FOREIGN KEY (country_follow_id)
        REFERENCES country (id) ON DELETE RESTRICT,
    CONSTRAINT fk_voyage_supervisor FOREIGN KEY (supervisor_id)
        REFERENCES supervisor (id) ON DELETE SET NULL
) PARTITION BY HASH (id);

CREATE TABLE voyage_p0 PARTITION OF voyage FOR VALUES WITH (MODULUS 4, REMAINDER 0);
CREATE TABLE voyage_p1 PARTITION OF voyage FOR VALUES WITH (MODULUS 4, REMAINDER 1);
CREATE TABLE voyage_p2 PARTITION OF voyage FOR VALUES WITH (MODULUS 4, REMAINDER 2);
CREATE TABLE voyage_p3 PARTITION OF voyage FOR VALUES WITH (MODULUS 4, REMAINDER 3);

-- индекс под выборку рейсов судна и под проверку уникальности плана
CREATE INDEX idx_voyage_plan ON voyage (ship_imo, exit_port_id, destination_port_id, eta);

-- Положение судна.
CREATE TABLE ship_position (
    id             BIGINT GENERATED ALWAYS AS IDENTITY,
    voyage_id      BIGINT NOT NULL,
    received_at    TIMESTAMPTZ NOT NULL,
    info_source_id INTEGER NOT NULL,
    latitude       NUMERIC(9, 6) NOT NULL,
    longitude      NUMERIC(9, 6) NOT NULL,
    speed          NUMERIC(8, 3),
    course         NUMERIC(6, 2),
    rot            NUMERIC(8, 3),
    heading        SMALLINT,
    nav_status_id  INTEGER,
    sea_id         INTEGER,
    CONSTRAINT pk_ship_position PRIMARY KEY (id, received_at),
    CONSTRAINT uq_ship_position_voyage_time UNIQUE (voyage_id, received_at),
    CONSTRAINT chk_ship_position_received_at CHECK (received_at >= TIMESTAMPTZ '2000-01-01 00:00:00+00'),
    CONSTRAINT chk_ship_position_latitude_range CHECK (latitude BETWEEN -90 AND 90),
    CONSTRAINT chk_ship_position_longitude_range CHECK (longitude BETWEEN -180 AND 180),
    CONSTRAINT chk_ship_position_speed_max CHECK (speed <= 100),
    CONSTRAINT chk_ship_position_course_range CHECK (course >= 0 AND course < 360),
    CONSTRAINT chk_ship_position_rot_range CHECK (rot BETWEEN -720 AND 720),
    CONSTRAINT chk_ship_position_heading_range CHECK (heading BETWEEN 0 AND 359),
    CONSTRAINT fk_ship_position_voyage FOREIGN KEY (voyage_id)
        REFERENCES voyage (id) ON DELETE CASCADE,
    CONSTRAINT fk_ship_position_info_source FOREIGN KEY (info_source_id)
        REFERENCES info_source (id) ON DELETE RESTRICT,
    CONSTRAINT fk_ship_position_nav_status FOREIGN KEY (nav_status_id)
        REFERENCES nav_status (id) ON DELETE RESTRICT,
    CONSTRAINT fk_ship_position_sea FOREIGN KEY (sea_id)
        REFERENCES sea (id) ON DELETE SET NULL
) PARTITION BY RANGE (received_at);

CREATE TABLE ship_position_2022_09 PARTITION OF ship_position
    FOR VALUES FROM ('2022-09-01 00:00:00+00') TO ('2022-10-01 00:00:00+00');
CREATE TABLE ship_position_2022_10 PARTITION OF ship_position
    FOR VALUES FROM ('2022-10-01 00:00:00+00') TO ('2022-11-01 00:00:00+00');
CREATE TABLE ship_position_2022_11 PARTITION OF ship_position
    FOR VALUES FROM ('2022-11-01 00:00:00+00') TO ('2022-12-01 00:00:00+00');
CREATE TABLE ship_position_2022_12 PARTITION OF ship_position
    FOR VALUES FROM ('2022-12-01 00:00:00+00') TO ('2023-01-01 00:00:00+00');
-- всё, что не попало в месячные секции
CREATE TABLE ship_position_default PARTITION OF ship_position DEFAULT;

-- под запрос плотности судов по акваториям и окну времени
CREATE INDEX idx_ship_position_sea_time ON ship_position (sea_id, received_at);

-- Создание месячной секции для нового месяца
CREATE FUNCTION fn_create_position_partition(p_month DATE)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    v_from  TIMESTAMPTZ := date_trunc('month', p_month)::timestamp AT TIME ZONE 'UTC';
    v_to    TIMESTAMPTZ := (date_trunc('month', p_month) + INTERVAL '1 month')::timestamp AT TIME ZONE 'UTC';
    v_name  TEXT := 'ship_position_' || to_char(p_month, 'YYYY_MM');
BEGIN
    EXECUTE format(
        'CREATE TABLE IF NOT EXISTS %I PARTITION OF ship_position FOR VALUES FROM (%L) TO (%L)',
        v_name, v_from, v_to);
    RETURN v_name;
END;
$$;

-- ------------------------------------------------------------
-- ТРИГГЕРЫ
-- ------------------------------------------------------------

-- Запрет удаления незавершённого рейса 
CREATE FUNCTION fn_voyage_forbid_delete_active()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.eta > now() THEN
        RAISE EXCEPTION
            'Нельзя удалить незавершённый рейс id=% (судно imo=%): плановое прибытие %',
            OLD.id, OLD.ship_imo, OLD.eta
            USING ERRCODE = 'restrict_violation';
    END IF;
    RETURN OLD;
END;
$$;

CREATE TRIGGER trg_voyage_forbid_delete_active
    BEFORE DELETE ON voyage
    FOR EACH ROW
    EXECUTE FUNCTION fn_voyage_forbid_delete_active();

-- Удаление компании вместе с неиспользуемыми операторами
CREATE FUNCTION fn_company_delete_unused_supervisors()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    busy_supervisor TEXT;
BEGIN
    DELETE FROM supervisor s
     WHERE s.company_id = OLD.id
       AND NOT EXISTS (SELECT 1 FROM voyage v WHERE v.supervisor_id = s.id);

    SELECT s.name
      INTO busy_supervisor
      FROM supervisor s
     WHERE s.company_id = OLD.id
     ORDER BY s.id
     LIMIT 1;

    IF busy_supervisor IS NOT NULL THEN
        RAISE EXCEPTION
            'Нельзя удалить компанию "%": оператор "%" привязан к рейсам',
            OLD.name, busy_supervisor
            USING ERRCODE = 'restrict_violation';
    END IF;

    RETURN OLD;
END;
$$;

CREATE TRIGGER trg_company_delete_unused_supervisors
    BEFORE DELETE ON company
    FOR EACH ROW
    EXECUTE FUNCTION fn_company_delete_unused_supervisors();

-- уникальность рейса вместо UNIQUE
CREATE FUNCTION fn_voyage_unique_plan()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.is_service THEN
        IF EXISTS (SELECT 1 FROM voyage v
                    WHERE v.ship_imo = NEW.ship_imo AND v.is_service AND v.id <> NEW.id) THEN
            RAISE EXCEPTION 'У судна imo=% уже есть служебный рейс', NEW.ship_imo
                USING ERRCODE = 'unique_violation', CONSTRAINT = 'uq_voyage_service';
        END IF;
    ELSIF EXISTS (SELECT 1 FROM voyage v
                   WHERE v.ship_imo = NEW.ship_imo
                     AND v.exit_port_id = NEW.exit_port_id
                     AND v.destination_port_id = NEW.destination_port_id
                     AND v.eta = NEW.eta
                     AND v.id <> NEW.id) THEN
        RAISE EXCEPTION 'Рейс судна imo=% (порты % -> %, ETA %) уже существует',
            NEW.ship_imo, NEW.exit_port_id, NEW.destination_port_id, NEW.eta
            USING ERRCODE = 'unique_violation', CONSTRAINT = 'uq_voyage_plan';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_voyage_unique_plan
    BEFORE INSERT OR UPDATE ON voyage
    FOR EACH ROW
    EXECUTE FUNCTION fn_voyage_unique_plan();

-- ------------------------------------------------------------
-- ПОПАДАНИЕ СУДНА В АКВАТОРИЮ
-- ------------------------------------------------------------

-- Пересборка геометрии после загрузки или изменения вершин
CREATE FUNCTION fn_refresh_sea_geom()
RETURNS VOID
LANGUAGE sql
AS $$
    REFRESH MATERIALIZED VIEW sea_geom;
$$;

-- Акватория, в которую попадает точка (долгота, широта).
CREATE FUNCTION fn_sea_id_for_point(p_lon NUMERIC, p_lat NUMERIC)
RETURNS INTEGER
LANGUAGE sql
STABLE
AS $$
    SELECT g.sea_id
      FROM sea_geom g
      JOIN sea s ON s.id = g.sea_id
     WHERE ST_Covers(g.geom, ST_SetSRID(ST_MakePoint(p_lon::float8, p_lat::float8), 4326))
     ORDER BY s.area_km ASC NULLS LAST, s.id
     LIMIT 1;
$$;

-- Автоматически заполняет sea_id при вставке позиции
CREATE FUNCTION fn_ship_position_set_sea()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.sea_id IS NULL THEN
        NEW.sea_id := fn_sea_id_for_point(NEW.longitude, NEW.latitude);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_ship_position_set_sea
    BEFORE INSERT ON ship_position
    FOR EACH ROW
    EXECUTE FUNCTION fn_ship_position_set_sea();

-- Проставляет sea_id уже загруженным позициям
CREATE FUNCTION fn_assign_position_seas(p_only_null BOOLEAN DEFAULT true)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows BIGINT;
BEGIN
    WITH hit AS (
        SELECT DISTINCT ON (p.id, p.received_at)
               p.id, p.received_at, g.sea_id
          FROM ship_position p
          JOIN sea_geom g
            ON ST_Covers(g.geom, ST_SetSRID(ST_MakePoint(p.longitude::float8, p.latitude::float8), 4326))
          JOIN sea s ON s.id = g.sea_id
         WHERE NOT p_only_null OR p.sea_id IS NULL
         ORDER BY p.id, p.received_at, s.area_km ASC NULLS LAST, s.id
    )
    UPDATE ship_position p
       SET sea_id = hit.sea_id
      FROM hit
     WHERE p.id = hit.id
       AND p.received_at = hit.received_at
       AND p.sea_id IS DISTINCT FROM hit.sea_id;
    GET DIAGNOSTICS v_rows = ROW_COUNT;

    IF NOT p_only_null THEN
        -- при полном пересчёте позиции, не попавшие ни в одну акваторию, теряют sea_id
        UPDATE ship_position p
           SET sea_id = NULL
         WHERE p.sea_id IS NOT NULL
           AND fn_sea_id_for_point(p.longitude, p.latitude) IS NULL;
    END IF;
    RETURN v_rows;
END;
$$;

-- Текущее положение каждого судна
CREATE VIEW v_ship_current_sea AS
SELECT DISTINCT ON (s.imo)
       s.imo,
       s.name           AS ship_name,
       p.received_at,
       p.longitude,
       p.latitude,
       se.name          AS sea_name,
       (se.id IS NOT NULL) AS in_sea
  FROM ship s
  JOIN voyage v         ON v.ship_imo = s.imo
  JOIN ship_position p  ON p.voyage_id = v.id
  LEFT JOIN sea se      ON se.id = fn_sea_id_for_point(p.longitude, p.latitude)
 ORDER BY s.imo, p.received_at DESC;

-- Попадает ли текущая позиция судна в указанную акваторию
CREATE FUNCTION fn_ship_in_sea(p_imo INTEGER, p_sea_name TEXT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS (
               SELECT 1
                 FROM sea_geom g
                WHERE lower(g.sea_name) = lower(p_sea_name)
                  AND ST_Covers(g.geom, ST_SetSRID(ST_MakePoint(c.longitude::float8, c.latitude::float8), 4326)))
      FROM (SELECT p.longitude, p.latitude
              FROM voyage v
              JOIN ship_position p ON p.voyage_id = v.id
             WHERE v.ship_imo = p_imo
             ORDER BY p.received_at DESC
             LIMIT 1) c
     WHERE EXISTS (SELECT 1 FROM sea_geom WHERE lower(sea_name) = lower(p_sea_name));
$$;

-- Плотность судов по акваториям
CREATE FUNCTION fn_sea_density(p_from TIMESTAMPTZ, p_to TIMESTAMPTZ)
RETURNS TABLE (
    sea_id                INTEGER,
    sea_name              VARCHAR,
    area_km               NUMERIC,
    ships_count           BIGINT,
    positions_count       BIGINT,
    density_per_1000_km2  NUMERIC
)
LANGUAGE sql
STABLE
AS $$
    SELECT s.id,
           s.name,
           s.area_km,
           count(DISTINCT v.ship_imo),
           count(p.id),
           round(count(DISTINCT v.ship_imo) * 1000.0 / NULLIF(s.area_km, 0), 6)
      FROM sea s
      LEFT JOIN ship_position p
             ON p.sea_id = s.id
            AND p.received_at >= p_from
            AND p.received_at <  p_to
      LEFT JOIN voyage v ON v.id = p.voyage_id
     GROUP BY s.id, s.name, s.area_km
     ORDER BY 6 DESC NULLS LAST, 4 DESC, s.id;
$$;

-- ------------------------------------------------------------
-- ВНЕШНЯЯ БД 
-- ------------------------------------------------------------
CREATE SERVER ext_server
    FOREIGN DATA WRAPPER postgres_fdw
    OPTIONS (host 'ext_db', port '5432', dbname 'ext_ships');

CREATE USER MAPPING FOR CURRENT_USER
    SERVER ext_server
    OPTIONS (user 'ships', password 'my_super_secret');

CREATE SCHEMA ext;

CREATE FUNCTION fn_connect_ext()
RETURNS TEXT
LANGUAGE plpgsql
AS $$
BEGIN
    DROP FOREIGN TABLE IF EXISTS ext.port_call;
    DROP FOREIGN TABLE IF EXISTS ext.ship_track;
    IMPORT FOREIGN SCHEMA public LIMIT TO (port_call, ship_track)
        FROM SERVER ext_server INTO ext;
    RETURN 'Внешние таблицы ext.port_call и ext.ship_track подключены';
END;
$$;

DO $$
BEGIN
    PERFORM fn_connect_ext();
EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'Внешняя БД недоступна (%). Запустите ext_db и выполните SELECT fn_connect_ext();', SQLERRM;
END;
$$;

-- ------------------------------------------------------------
-- ИМПОРТ
-- ------------------------------------------------------------
CREATE FUNCTION fn_parse_imo(p_text TEXT)
RETURNS INTEGER
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE WHEN btrim(p_text) ~ '^[0-9]{7}$' THEN btrim(p_text)::integer END;
$$;

CREATE FUNCTION fn_parse_company_name(p_text TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT NULLIF(
               btrim(regexp_replace(
                   substring(p_text FROM 'Название:(.*?)ИМО:'),
                   '^\s*/\s*', '')),
               '');
$$;

CREATE FUNCTION fn_import_from_ext()
RETURNS TABLE (step_no INTEGER, step TEXT, inserted BIGINT, skipped BIGINT)
LANGUAGE plpgsql
AS $$
DECLARE
    n         BIGINT;
    v_total   BIGINT;
    v_kept    BIGINT;
BEGIN

    DROP TABLE IF EXISTS tmp_track;
    DROP TABLE IF EXISTS tmp_call;

    CREATE TEMP TABLE tmp_track ON COMMIT DROP AS
    SELECT DISTINCT ON (fn_parse_imo(t.imo), t.receive_date)
           fn_parse_imo(t.imo)                              AS imo,
           t.receive_date AT TIME ZONE 'UTC'                AS received_at,
           t.longitude, t.latitude,
           CASE WHEN t.speed  BETWEEN 0 AND 100 THEN t.speed  END AS speed,
           CASE WHEN t.course >= 0 AND t.course < 360 THEN t.course END AS course,
           CASE WHEN t.rot BETWEEN -720 AND 720 THEN t.rot END    AS rot,
           CASE WHEN t.heading >= 0 AND t.heading < 360 THEN round(t.heading)::smallint END AS heading,
           NULLIF(btrim(t.asource), '')                     AS source,
           NULLIF(btrim(t.nav_status), '')                  AS nav_status,
           CASE WHEN btrim(t.mmsi) ~ '^[0-9]{9}$' THEN btrim(t.mmsi) END       AS mmsi,
           CASE WHEN btrim(t.call_sign) ~ '^[A-Z0-9]{3,10}$' THEN btrim(t.call_sign) END AS call_sign,
           NULLIF(btrim(t.shipname), '')                    AS name,
           NULLIF(btrim(t.shipname_lat), '')                AS name_lat,
           NULLIF(btrim(t.flag), '')                        AS flag
      FROM ext.ship_track t
     WHERE fn_parse_imo(t.imo) IS NOT NULL
       AND t.receive_date IS NOT NULL
       AND t.longitude IS NOT NULL AND t.latitude IS NOT NULL
       AND t.longitude BETWEEN -180 AND 180 AND t.latitude BETWEEN -90 AND 90
     ORDER BY fn_parse_imo(t.imo), t.receive_date, t.asource;
    CREATE INDEX ON tmp_track (imo, received_at);

    CREATE TEMP TABLE tmp_call ON COMMIT DROP AS
    SELECT DISTINCT
           fn_parse_imo(c.ship_imo)                     AS imo,
           c.enter_port, c.destination_port,
           upper(NULLIF(btrim(c.destination_country), '')) AS follow_alpha2,
           c.enter_fact_date AT TIME ZONE 'UTC'         AS enter_fact,
           c.exit_date       AT TIME ZONE 'UTC'         AS eta,
           c.exit_fact_date  AT TIME ZONE 'UTC'         AS exit_fact,
           fn_parse_company_name(c.supervising)         AS company,
           CASE WHEN btrim(c.ship_mmsi) ~ '^[0-9]{9}$' THEN btrim(c.ship_mmsi) END AS mmsi,
           CASE WHEN btrim(c.ship_callsign) ~ '^[A-Z0-9]{3,10}$' THEN btrim(c.ship_callsign) END AS call_sign,
           NULLIF(btrim(c.ship_name), '')               AS name,
           NULLIF(btrim(c.ship_name_lat), '')           AS name_lat
      FROM ext.port_call c
     WHERE fn_parse_imo(c.ship_imo) IS NOT NULL
       AND c.enter_port       ~ '^[A-Z]{2}[A-Z0-9]{3}$'
       AND c.destination_port ~ '^[A-Z]{2}[A-Z0-9]{3}$'
       AND c.exit_date IS NOT NULL;

    WITH ins AS (
        INSERT INTO country (code)
        SELECT i.alpha3
          FROM iso_country i
         WHERE i.numeric_code IN (SELECT flag FROM tmp_track)
            OR i.alpha2 IN (SELECT left(enter_port, 2)       FROM tmp_call)
            OR i.alpha2 IN (SELECT left(destination_port, 2) FROM tmp_call)
            OR i.alpha2 IN (SELECT follow_alpha2             FROM tmp_call)
        ON CONFLICT (code) DO NOTHING
        RETURNING 1)
    SELECT count(*) INTO n FROM ins;
    step_no := 1; step := 'country'; inserted := n; skipped := 0; RETURN NEXT;


    WITH ins AS (
        INSERT INTO info_source (name)
        SELECT DISTINCT source FROM tmp_track WHERE source IS NOT NULL
        ON CONFLICT (name) DO NOTHING RETURNING 1)
    SELECT count(*) INTO n FROM ins;
    step_no := 2; step := 'info_source'; inserted := n; skipped := 0; RETURN NEXT;

    WITH ins AS (
        INSERT INTO nav_status (name)
        SELECT DISTINCT nav_status FROM tmp_track WHERE nav_status IS NOT NULL
        ON CONFLICT (name) DO NOTHING RETURNING 1)
    SELECT count(*) INTO n FROM ins;
    step_no := 3; step := 'nav_status'; inserted := n; skipped := 0; RETURN NEXT;

    WITH ins AS (
        INSERT INTO company (name)
        SELECT DISTINCT company FROM tmp_call WHERE company IS NOT NULL
        ON CONFLICT (name) DO NOTHING RETURNING 1)
    SELECT count(*) INTO n FROM ins;
    step_no := 4; step := 'company'; inserted := n; skipped := 0; RETURN NEXT;

    WITH ins AS (
        INSERT INTO supervisor (name, company_id)
        SELECT 'Оператор не указан', c.id
          FROM company c
         WHERE c.name IN (SELECT company FROM tmp_call)
        ON CONFLICT (company_id, name) DO NOTHING RETURNING 1)
    SELECT count(*) INTO n FROM ins;
    step_no := 5; step := 'supervisor'; inserted := n; skipped := 0; RETURN NEXT;

    WITH ports AS (
        SELECT enter_port AS code FROM tmp_call
        UNION
        SELECT destination_port FROM tmp_call
    ), ins AS (
        INSERT INTO port (name, country_id)
        SELECT p.code, c.id
          FROM ports p
          JOIN iso_country i ON i.alpha2 = left(p.code, 2)
          JOIN country c     ON c.code = i.alpha3
        ON CONFLICT (name, country_id) DO NOTHING
        RETURNING 1)
    SELECT count(*) INTO n FROM ins;
    step_no := 6; step := 'port'; inserted := n; skipped := 0; RETURN NEXT;

    DROP TABLE IF EXISTS tmp_ship;
    CREATE TEMP TABLE tmp_ship ON COMMIT DROP AS
    SELECT DISTINCT ON (u.imo)
           u.imo, u.mmsi, u.call_sign, u.name, u.name_lat, u.flag
      FROM (
            SELECT imo, mmsi, call_sign, name, name_lat, flag, 1 AS prio, received_at AS ts
              FROM tmp_track
            UNION ALL
            SELECT imo, mmsi, call_sign, name, name_lat, NULL, 2, eta
              FROM tmp_call
           ) u
     ORDER BY u.imo, u.prio, u.ts DESC;

    UPDATE tmp_ship s SET mmsi = NULL
     WHERE s.mmsi IS NOT NULL
       AND (EXISTS (SELECT 1 FROM tmp_ship o WHERE o.mmsi = s.mmsi AND o.imo < s.imo)
         OR EXISTS (SELECT 1 FROM ship x WHERE x.mmsi = s.mmsi AND x.imo <> s.imo));
    UPDATE tmp_ship s SET call_sign = NULL
     WHERE s.call_sign IS NOT NULL
       AND (EXISTS (SELECT 1 FROM tmp_ship o WHERE o.call_sign = s.call_sign AND o.imo < s.imo)
         OR EXISTS (SELECT 1 FROM ship x WHERE x.call_sign = s.call_sign AND x.imo <> s.imo));

    WITH ins AS (
        INSERT INTO ship (imo, mmsi, call_sign, name, name_lat, flag_country_id)
        SELECT s.imo, s.mmsi, s.call_sign, s.name, s.name_lat, c.id
          FROM tmp_ship s
          LEFT JOIN iso_country i ON i.numeric_code = s.flag
          LEFT JOIN country c     ON c.code = i.alpha3
        ON CONFLICT (imo) DO NOTHING
        RETURNING 1)
    SELECT count(*) INTO n FROM ins;
    step_no := 7; step := 'ship'; inserted := n; skipped := 0; RETURN NEXT;

    DROP TABLE IF EXISTS tmp_voyage;
    CREATE TEMP TABLE tmp_voyage ON COMMIT DROP AS
    SELECT g.imo, pe.id AS exit_port_id, pd.id AS destination_port_id, g.eta,
           min(g.enter_fact) AS enter_fact, max(g.exit_fact) AS exit_fact,
           max(cf.id) AS country_follow_id, max(g.company) AS company
      FROM tmp_call g
      JOIN iso_country ie ON ie.alpha2 = left(g.enter_port, 2)
      JOIN country ce     ON ce.code = ie.alpha3
      JOIN port pe        ON pe.name = g.enter_port AND pe.country_id = ce.id
      JOIN iso_country id ON id.alpha2 = left(g.destination_port, 2)
      JOIN country cd     ON cd.code = id.alpha3
      JOIN port pd        ON pd.name = g.destination_port AND pd.country_id = cd.id
      LEFT JOIN iso_country ifl ON ifl.alpha2 = g.follow_alpha2
      LEFT JOIN country cf      ON cf.code = ifl.alpha3
     WHERE EXISTS (SELECT 1 FROM ship s WHERE s.imo = g.imo)
     GROUP BY g.imo, pe.id, pd.id, g.eta;

    SELECT count(*) INTO v_total FROM ext.port_call;
    SELECT count(*) INTO v_kept FROM tmp_voyage;

    WITH ins AS (
        INSERT INTO voyage (ship_imo, exit_port_id, destination_port_id, eta,
                            country_follow_id, supervisor_id)
        SELECT t.imo, t.exit_port_id, t.destination_port_id, t.eta, t.country_follow_id, sv.id
          FROM tmp_voyage t
          LEFT JOIN company co    ON co.name = t.company
          LEFT JOIN supervisor sv ON sv.company_id = co.id AND sv.name = 'Оператор не указан'
         WHERE NOT EXISTS (SELECT 1 FROM voyage v
                            WHERE v.ship_imo = t.imo
                              AND v.exit_port_id = t.exit_port_id
                              AND v.destination_port_id = t.destination_port_id
                              AND v.eta = t.eta)
        RETURNING 1)
    SELECT count(*) INTO n FROM ins;

    step_no := 8; step := 'voyage'; inserted := n; skipped := v_total - (SELECT count(*) FROM ext.port_call c
        WHERE fn_parse_imo(c.ship_imo) IS NOT NULL AND c.enter_port ~ '^[A-Z]{2}[A-Z0-9]{3}$'
          AND c.destination_port ~ '^[A-Z]{2}[A-Z0-9]{3}$' AND c.exit_date IS NOT NULL);
    RETURN NEXT;

    WITH ins AS (
        INSERT INTO voyage (ship_imo, is_service)
        SELECT DISTINCT t.imo, true
          FROM tmp_track t
         WHERE EXISTS (SELECT 1 FROM ship s WHERE s.imo = t.imo)
           AND NOT EXISTS (SELECT 1 FROM voyage v WHERE v.ship_imo = t.imo AND v.is_service)
        RETURNING 1)
    SELECT count(*) INTO n FROM ins;
    step_no := 9; step := 'voyage (служебные)'; inserted := n; skipped := 0; RETURN NEXT;

    DROP TABLE IF EXISTS tmp_window;
    CREATE TEMP TABLE tmp_window ON COMMIT DROP AS
    SELECT v.id AS voyage_id, t.imo, t.enter_fact AS from_ts, t.exit_fact AS to_ts
      FROM tmp_voyage t
      JOIN voyage v ON v.ship_imo = t.imo
                   AND v.exit_port_id = t.exit_port_id
                   AND v.destination_port_id = t.destination_port_id
                   AND v.eta = t.eta
     WHERE t.enter_fact IS NOT NULL AND t.exit_fact IS NOT NULL;
    CREATE INDEX ON tmp_window (imo, from_ts);

    SELECT count(*) INTO v_total FROM ext.ship_track;
    WITH ins AS (
        INSERT INTO ship_position (voyage_id, received_at, info_source_id, latitude, longitude,
                                   speed, course, rot, heading, nav_status_id)
        SELECT COALESCE(w.voyage_id, sv.id), t.received_at, src.id, t.latitude, t.longitude,
               t.speed, t.course, t.rot, t.heading, ns.id
          FROM tmp_track t
          JOIN info_source src ON src.name = t.source
          LEFT JOIN nav_status ns ON ns.name = t.nav_status
          JOIN voyage sv ON sv.ship_imo = t.imo AND sv.is_service
          LEFT JOIN LATERAL (
                SELECT x.voyage_id
                  FROM tmp_window x
                 WHERE x.imo = t.imo
                   AND t.received_at BETWEEN x.from_ts AND x.to_ts
                 ORDER BY x.from_ts DESC
                 LIMIT 1) w ON true
        ON CONFLICT (voyage_id, received_at) DO NOTHING
        RETURNING 1)
    SELECT count(*) INTO n FROM ins;
  
    step_no := 10; step := 'ship_position'; inserted := n; skipped := v_total - n; RETURN NEXT;

    RETURN;
END;
$$;
