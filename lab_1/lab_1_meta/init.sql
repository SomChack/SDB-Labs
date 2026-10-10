-- ============================================================
-- Лаба 1. Структура БД судов, рейсов и истории перемещений
-- PostgreSQL 17. Нормализация до НФБК.
-- Содержимое: таблицы, первичные ключи, внешние ключи с режимами
-- удаления, NOT NULL, CHECK, UNIQUE, триггеры.
-- Индексы и прочая оптимизация в эту лабу не входят.
-- ============================================================

-- ------------------------------------------------------------
-- 1. СПРАВОЧНИКИ
-- ------------------------------------------------------------

-- Страны (в JSON только коды: USA, UK, GER, NZ ...)
CREATE TABLE country (
    id    INTEGER GENERATED ALWAYS AS IDENTITY,
    code  VARCHAR(10) NOT NULL,
    CONSTRAINT pk_country PRIMARY KEY (id),
    CONSTRAINT uq_country_code UNIQUE (code),
    CONSTRAINT chk_country_code_format CHECK (code ~ '^[A-Z]{2,3}$')
);

-- Типы судов (Tanker, Cargo, Cruise ...)
CREATE TABLE ship_type (
    id    INTEGER GENERATED ALWAYS AS IDENTITY,
    name  VARCHAR(255) NOT NULL,
    CONSTRAINT pk_ship_type PRIMARY KEY (id),
    CONSTRAINT uq_ship_type_name UNIQUE (name),
    CONSTRAINT chk_ship_type_name_clean CHECK (name <> '' AND name = btrim(name))
);

-- Навигационные статусы (At Anchor, Moored, Underway using engine)
CREATE TABLE nav_status (
    id    INTEGER GENERATED ALWAYS AS IDENTITY,
    name  VARCHAR(100) NOT NULL,
    CONSTRAINT pk_nav_status PRIMARY KEY (id),
    CONSTRAINT uq_nav_status_name UNIQUE (name),
    CONSTRAINT chk_nav_status_name_clean CHECK (name <> '' AND name = btrim(name))
);

-- Источники данных о положении судов (EXACTEARTH, SHIPFINDER, OCEANTRACKER)
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
-- (military, trade, commercial, tourism, research, cruise).
-- Не путать с ship_type: словари значений разные.
CREATE TABLE ship_category (
    id    INTEGER GENERATED ALWAYS AS IDENTITY,
    name  VARCHAR(100) NOT NULL,
    CONSTRAINT pk_ship_category PRIMARY KEY (id),
    CONSTRAINT uq_ship_category_name UNIQUE (name),
    CONSTRAINT chk_ship_category_name_clean CHECK (name <> '' AND name = btrim(name))
);

-- ------------------------------------------------------------
-- 2. АКВАТОРИИ
-- ------------------------------------------------------------

CREATE TABLE sea (
    id       INTEGER GENERATED ALWAYS AS IDENTITY,
    name     VARCHAR(255) NOT NULL,
    area_km  NUMERIC(14, 2),
    CONSTRAINT pk_sea PRIMARY KEY (id),
    CONSTRAINT uq_sea_name UNIQUE (name),
    CONSTRAINT chk_sea_name_clean CHECK (name <> '' AND name = btrim(name)),
    -- верхний предел: площадь всего Мирового океана
    CONSTRAINT chk_sea_area_range CHECK (area_km > 0 AND area_km <= 361000000)
);

-- Связь M:N: какие категории судов допущены в какой акватории
CREATE TABLE sea_ship_category (
    sea_id            INTEGER NOT NULL,
    ship_category_id  INTEGER NOT NULL,
    CONSTRAINT pk_sea_ship_category PRIMARY KEY (sea_id, ship_category_id),
    CONSTRAINT fk_sea_ship_category_sea FOREIGN KEY (sea_id)
        REFERENCES sea (id) ON DELETE CASCADE,
    CONSTRAINT fk_sea_ship_category_category FOREIGN KEY (ship_category_id)
        REFERENCES ship_category (id) ON DELETE CASCADE
);

-- ------------------------------------------------------------
-- 3. ПОРТЫ, КОМПАНИИ, ОПЕРАТОРЫ
-- ------------------------------------------------------------

-- Одна таблица для порта выхода и порта назначения (один объект в двух ролях)
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

-- Операторы сопровождения плавания (много операторов — одна компания)
CREATE TABLE supervisor (
    id          INTEGER GENERATED ALWAYS AS IDENTITY,
    name        VARCHAR(255) NOT NULL,
    company_id  INTEGER NOT NULL,
    CONSTRAINT pk_supervisor PRIMARY KEY (id),
    -- ФИО само по себе неуникально
    CONSTRAINT uq_supervisor_company_name UNIQUE (company_id, name),
    CONSTRAINT chk_supervisor_name_clean CHECK (name <> '' AND name = btrim(name)),
    CONSTRAINT fk_supervisor_company FOREIGN KEY (company_id)
        REFERENCES company (id) ON DELETE RESTRICT
);

-- ------------------------------------------------------------
-- 4. СУДА, РЕЙСЫ, ПОЗИЦИИ
-- ------------------------------------------------------------

-- Судно и его постоянные характеристики.
-- imo — первичный ключ; mmsi и call_sign — альтернативные (потенциальные)
-- ключи, поэтому UNIQUE (иначе нарушается НФБК: mmsi -> imo, call_sign -> imo).
CREATE TABLE ship (
    imo               INTEGER NOT NULL,
    mmsi              VARCHAR(9),      -- строка: MMSI может начинаться с нуля
    call_sign         VARCHAR(20),
    name              VARCHAR(255),
    name_lat          VARCHAR(255),    -- международное имя, не выводится из name
    flag_country_id   INTEGER,         -- страна производитель (поле flag)
    owner_country_id  INTEGER,         -- страна владелец (поле сountry)
    ship_type_id      INTEGER,
    CONSTRAINT pk_ship PRIMARY KEY (imo),
    CONSTRAINT uq_ship_mmsi UNIQUE (mmsi),
    CONSTRAINT uq_ship_call_sign UNIQUE (call_sign),
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

-- Запланированный рейс конкретного судна
CREATE TABLE voyage (
    id                   BIGINT GENERATED ALWAYS AS IDENTITY,
    ship_imo             INTEGER NOT NULL,
    exit_port_id         INTEGER NOT NULL,
    destination_port_id  INTEGER NOT NULL,
    eta                  TIMESTAMPTZ NOT NULL,
    country_follow_id    INTEGER,       -- страна следования, не выводится из порта назначения
    supervisor_id        INTEGER,       -- компания определяется через оператора
    CONSTRAINT pk_voyage PRIMARY KEY (id),
    -- защита от дубля рейса при повторной загрузке
    CONSTRAINT uq_voyage_plan UNIQUE (ship_imo, exit_port_id, destination_port_id, eta),
    CONSTRAINT chk_voyage_ports_differ CHECK (exit_port_id <> destination_port_id),
    -- защита от ошибки единиц (миллисекунды/секунды) при загрузке eta
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
);

-- Отдельное наблюдение положения судна в определённый момент (история перемещений).
-- Судно определяется через рейс: хранить рядом ещё и ship_imo нельзя
-- (транзитивная зависимость position -> voyage -> ship, нарушение 3НФ).
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
    CONSTRAINT pk_ship_position PRIMARY KEY (id),
    CONSTRAINT uq_ship_position_voyage_time UNIQUE (voyage_id, received_at),
    CONSTRAINT chk_ship_position_received_at CHECK (received_at >= TIMESTAMPTZ '2000-01-01 00:00:00+00'),
    CONSTRAINT chk_ship_position_latitude_range CHECK (latitude BETWEEN -90 AND 90),
    CONSTRAINT chk_ship_position_longitude_range CHECK (longitude BETWEEN -180 AND 180),
    -- нижней границы у скорости нет: в тестовых данных у BALTIC PIONEER speed = -12
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
);

-- ------------------------------------------------------------
-- 5. ТРИГГЕРЫ УДАЛЕНИЯ
-- ------------------------------------------------------------

-- 5.1. Запрет удаления незавершённого рейса.
-- Срабатывает и при каскадном удалении рейсов от судна: ошибка на одном
-- рейсе откатывает всю операцию, позиции рейса не пропадают.
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

-- 5.2. Удаление компании вместе с неиспользуемыми операторами.
-- Операторов без рейсов удаляет, а если остался оператор с рейсами,
-- отклоняет удаление компании и называет оператора.
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
