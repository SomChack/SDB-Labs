DROP VIEW IF EXISTS v_voyage_full;

CREATE VIEW v_voyage_full AS
SELECT v.id                 AS voyage_id,
       v.ship_imo,
       s.name               AS ship_name,
       pe.name              AS exit_port,
       ce.code              AS exit_port_country,
       pd.name              AS destination_port,
       cd.code              AS destination_port_country,
       v.eta,
       cf.code              AS country_follow,
       co.name              AS company_name,
       sv.name              AS supervisor_name
  FROM voyage v
  JOIN ship s             ON s.imo = v.ship_imo
  JOIN port pe            ON pe.id = v.exit_port_id
  JOIN country ce         ON ce.id = pe.country_id
  JOIN port pd            ON pd.id = v.destination_port_id
  JOIN country cd         ON cd.id = pd.country_id
  LEFT JOIN country cf    ON cf.id = v.country_follow_id
  LEFT JOIN supervisor sv ON sv.id = v.supervisor_id
  LEFT JOIN company co    ON co.id = sv.company_id
 WHERE NOT v.is_service;

DO $$
BEGIN
    INSERT INTO v_voyage_full (ship_imo, exit_port, exit_port_country, destination_port,
                               destination_port_country, eta)
    VALUES (9843223, 'RUARH', 'RUS', 'RUNIL', 'RUS', TIMESTAMPTZ '2030-01-01 12:00:00+00');
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Ожидаемая ошибка без триггера: %', SQLERRM;
END;
$$;

CREATE OR REPLACE FUNCTION fn_dov_country(p_code TEXT)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_id INTEGER;
BEGIN
    IF p_code IS NULL THEN
        RETURN NULL;
    END IF;
    SELECT id INTO v_id FROM country WHERE code = p_code;
    IF v_id IS NULL THEN
        INSERT INTO country (code) VALUES (p_code) RETURNING id INTO v_id;
    END IF;
    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION fn_dov_port(p_name TEXT, p_country_code TEXT)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_country INTEGER := fn_dov_country(p_country_code);
    v_id      INTEGER;
BEGIN
    SELECT id INTO v_id FROM port WHERE name = p_name AND country_id = v_country;
    IF v_id IS NULL THEN
        INSERT INTO port (name, country_id) VALUES (p_name, v_country) RETURNING id INTO v_id;
    END IF;
    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION fn_dov_supervisor(p_company TEXT, p_supervisor TEXT)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_company INTEGER;
    v_id      INTEGER;
    v_name    TEXT := COALESCE(p_supervisor, 'Оператор не указан');
BEGIN
    IF p_company IS NULL THEN
        RETURN NULL;
    END IF;
    SELECT id INTO v_company FROM company WHERE name = p_company;
    IF v_company IS NULL THEN
        INSERT INTO company (name) VALUES (p_company) RETURNING id INTO v_company;
    END IF;
    SELECT id INTO v_id FROM supervisor WHERE company_id = v_company AND name = v_name;
    IF v_id IS NULL THEN
        INSERT INTO supervisor (name, company_id) VALUES (v_name, v_company) RETURNING id INTO v_id;
    END IF;
    RETURN v_id;
END;
$$;

-- 3. Триггерные функции INSTEAD OF

CREATE OR REPLACE FUNCTION fn_v_voyage_full_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO ship (imo, name) VALUES (NEW.ship_imo, NEW.ship_name)
    ON CONFLICT (imo) DO NOTHING;

    INSERT INTO voyage (ship_imo, exit_port_id, destination_port_id, eta,
                        country_follow_id, supervisor_id)
    VALUES (NEW.ship_imo,
            fn_dov_port(NEW.exit_port, NEW.exit_port_country),
            fn_dov_port(NEW.destination_port, NEW.destination_port_country),
            NEW.eta,
            fn_dov_country(NEW.country_follow),
            fn_dov_supervisor(NEW.company_name, NEW.supervisor_name))
    RETURNING id INTO NEW.voyage_id;

    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION fn_v_voyage_full_update()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE voyage
       SET exit_port_id        = fn_dov_port(NEW.exit_port, NEW.exit_port_country),
           destination_port_id = fn_dov_port(NEW.destination_port, NEW.destination_port_country),
           eta                 = NEW.eta,
           country_follow_id   = fn_dov_country(NEW.country_follow),
           supervisor_id       = fn_dov_supervisor(NEW.company_name, NEW.supervisor_name)
     WHERE id = OLD.voyage_id;
    RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION fn_v_voyage_full_delete()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    DELETE FROM voyage WHERE id = OLD.voyage_id;
    RETURN OLD;
END;
$$;

CREATE TRIGGER trg_v_voyage_full_insert
    INSTEAD OF INSERT ON v_voyage_full
    FOR EACH ROW EXECUTE FUNCTION fn_v_voyage_full_insert();

CREATE TRIGGER trg_v_voyage_full_update
    INSTEAD OF UPDATE ON v_voyage_full
    FOR EACH ROW EXECUTE FUNCTION fn_v_voyage_full_update();

CREATE TRIGGER trg_v_voyage_full_delete
    INSTEAD OF DELETE ON v_voyage_full
    FOR EACH ROW EXECUTE FUNCTION fn_v_voyage_full_delete();

-- 4. Демонстрация

SELECT (SELECT count(*) FROM country)    AS countries,
       (SELECT count(*) FROM port)       AS ports,
       (SELECT count(*) FROM company)    AS companies,
       (SELECT count(*) FROM supervisor) AS supervisors,
       (SELECT count(*) FROM ship)       AS ships,
       (SELECT count(*) FROM voyage)     AS voyages;

INSERT INTO v_voyage_full (ship_imo, ship_name, exit_port, exit_port_country,
                           destination_port, destination_port_country, eta,
                           country_follow, company_name, supervisor_name)
VALUES (9999999, 'DEMO VOYAGER', 'FIKTK', 'FIN', 'NOOSL', 'NOR',
        TIMESTAMPTZ '2030-06-01 12:00:00+00', 'NOR',
        'Demo Shipping Co.', 'Ivanov Ivan');

SELECT (SELECT count(*) FROM country)    AS countries,
       (SELECT count(*) FROM port)       AS ports,
       (SELECT count(*) FROM company)    AS companies,
       (SELECT count(*) FROM supervisor) AS supervisors,
       (SELECT count(*) FROM ship)       AS ships,
       (SELECT count(*) FROM voyage)     AS voyages;

SELECT imo, name FROM ship WHERE imo = 9999999;
SELECT p.id, p.name, c.code AS country FROM port p JOIN country c ON c.id = p.country_id
 WHERE p.name IN ('FIKTK', 'NOOSL');
SELECT co.name AS company, sv.name AS supervisor
  FROM supervisor sv JOIN company co ON co.id = sv.company_id
 WHERE co.name = 'Demo Shipping Co.';

SELECT * FROM v_voyage_full WHERE ship_imo = 9999999;

UPDATE v_voyage_full
   SET destination_port = 'SESTO', destination_port_country = 'SWE',
       eta = TIMESTAMPTZ '2030-06-05 08:00:00+00',
       supervisor_name = 'Petrov Petr'
 WHERE ship_imo = 9999999;

SELECT voyage_id, exit_port, destination_port, destination_port_country, eta, company_name, supervisor_name
  FROM v_voyage_full WHERE ship_imo = 9999999;

DO $$
BEGIN
    DELETE FROM v_voyage_full WHERE ship_imo = 9999999;
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Ожидаемая ошибка: %', SQLERRM;
END;
$$;

UPDATE v_voyage_full SET eta = TIMESTAMPTZ '2021-01-01 00:00:00+00' WHERE ship_imo = 9999999;
DELETE FROM v_voyage_full WHERE ship_imo = 9999999;

SELECT count(*) AS voyages_left FROM v_voyage_full WHERE ship_imo = 9999999;

DELETE FROM supervisor WHERE company_id IN (SELECT id FROM company WHERE name = 'Demo Shipping Co.');
DELETE FROM company WHERE name = 'Demo Shipping Co.';
DELETE FROM port WHERE name IN ('FIKTK', 'NOOSL', 'SESTO');
DELETE FROM ship WHERE imo = 9999999;
