--
-- PostgreSQL database dump
--

\restrict 0X5OMp2QWUXp9SdGaRZi1Ta73bIO5qfhDhbfye1v1j8CJurI0LTKCX7L8acg4Na

-- Dumped from database version 17.11 (Debian 17.11-1.pgdg13+2)
-- Dumped by pg_dump version 17.11 (Debian 17.11-1.pgdg13+2)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: fn_company_delete_unused_supervisors(); Type: FUNCTION; Schema: public; Owner: ships
--

CREATE FUNCTION public.fn_company_delete_unused_supervisors() RETURNS trigger
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


ALTER FUNCTION public.fn_company_delete_unused_supervisors() OWNER TO ships;

--
-- Name: fn_voyage_forbid_delete_active(); Type: FUNCTION; Schema: public; Owner: ships
--

CREATE FUNCTION public.fn_voyage_forbid_delete_active() RETURNS trigger
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


ALTER FUNCTION public.fn_voyage_forbid_delete_active() OWNER TO ships;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: company; Type: TABLE; Schema: public; Owner: ships
--

CREATE TABLE public.company (
    id integer NOT NULL,
    name character varying(255) NOT NULL,
    CONSTRAINT chk_company_name_clean CHECK ((((name)::text <> ''::text) AND ((name)::text = btrim((name)::text))))
);


ALTER TABLE public.company OWNER TO ships;

--
-- Name: company_id_seq; Type: SEQUENCE; Schema: public; Owner: ships
--

ALTER TABLE public.company ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.company_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: country; Type: TABLE; Schema: public; Owner: ships
--

CREATE TABLE public.country (
    id integer NOT NULL,
    code character varying(10) NOT NULL,
    CONSTRAINT chk_country_code_format CHECK (((code)::text ~ '^[A-Z]{2,3}$'::text))
);


ALTER TABLE public.country OWNER TO ships;

--
-- Name: country_id_seq; Type: SEQUENCE; Schema: public; Owner: ships
--

ALTER TABLE public.country ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.country_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: info_source; Type: TABLE; Schema: public; Owner: ships
--

CREATE TABLE public.info_source (
    id integer NOT NULL,
    name character varying(255) NOT NULL,
    CONSTRAINT chk_info_source_name_clean CHECK ((((name)::text <> ''::text) AND ((name)::text = btrim((name)::text))))
);


ALTER TABLE public.info_source OWNER TO ships;

--
-- Name: info_source_id_seq; Type: SEQUENCE; Schema: public; Owner: ships
--

ALTER TABLE public.info_source ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.info_source_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: nav_status; Type: TABLE; Schema: public; Owner: ships
--

CREATE TABLE public.nav_status (
    id integer NOT NULL,
    name character varying(100) NOT NULL,
    CONSTRAINT chk_nav_status_name_clean CHECK ((((name)::text <> ''::text) AND ((name)::text = btrim((name)::text))))
);


ALTER TABLE public.nav_status OWNER TO ships;

--
-- Name: nav_status_id_seq; Type: SEQUENCE; Schema: public; Owner: ships
--

ALTER TABLE public.nav_status ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.nav_status_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: port; Type: TABLE; Schema: public; Owner: ships
--

CREATE TABLE public.port (
    id integer NOT NULL,
    name character varying(255) NOT NULL,
    country_id integer NOT NULL,
    CONSTRAINT chk_port_name_clean CHECK ((((name)::text <> ''::text) AND ((name)::text = btrim((name)::text))))
);


ALTER TABLE public.port OWNER TO ships;

--
-- Name: port_id_seq; Type: SEQUENCE; Schema: public; Owner: ships
--

ALTER TABLE public.port ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.port_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: sea; Type: TABLE; Schema: public; Owner: ships
--

CREATE TABLE public.sea (
    id integer NOT NULL,
    name character varying(255) NOT NULL,
    area_km numeric(14,2),
    CONSTRAINT chk_sea_area_range CHECK (((area_km > (0)::numeric) AND (area_km <= (361000000)::numeric))),
    CONSTRAINT chk_sea_name_clean CHECK ((((name)::text <> ''::text) AND ((name)::text = btrim((name)::text))))
);


ALTER TABLE public.sea OWNER TO ships;

--
-- Name: sea_id_seq; Type: SEQUENCE; Schema: public; Owner: ships
--

ALTER TABLE public.sea ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.sea_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: sea_ship_category; Type: TABLE; Schema: public; Owner: ships
--

CREATE TABLE public.sea_ship_category (
    sea_id integer NOT NULL,
    ship_category_id integer NOT NULL
);


ALTER TABLE public.sea_ship_category OWNER TO ships;

--
-- Name: ship; Type: TABLE; Schema: public; Owner: ships
--

CREATE TABLE public.ship (
    imo integer NOT NULL,
    mmsi character varying(9),
    call_sign character varying(20),
    name character varying(255),
    name_lat character varying(255),
    flag_country_id integer,
    owner_country_id integer,
    ship_type_id integer,
    CONSTRAINT chk_ship_call_sign_format CHECK (((call_sign)::text ~ '^[A-Z0-9]{3,10}$'::text)),
    CONSTRAINT chk_ship_imo_range CHECK (((imo >= 1000000) AND (imo <= 9999999))),
    CONSTRAINT chk_ship_mmsi_format CHECK (((mmsi)::text ~ '^[0-9]{9}$'::text)),
    CONSTRAINT chk_ship_name_clean CHECK ((((name)::text <> ''::text) AND ((name)::text = btrim((name)::text)))),
    CONSTRAINT chk_ship_name_lat_clean CHECK ((((name_lat)::text <> ''::text) AND ((name_lat)::text = btrim((name_lat)::text))))
);


ALTER TABLE public.ship OWNER TO ships;

--
-- Name: ship_category; Type: TABLE; Schema: public; Owner: ships
--

CREATE TABLE public.ship_category (
    id integer NOT NULL,
    name character varying(100) NOT NULL,
    CONSTRAINT chk_ship_category_name_clean CHECK ((((name)::text <> ''::text) AND ((name)::text = btrim((name)::text))))
);


ALTER TABLE public.ship_category OWNER TO ships;

--
-- Name: ship_category_id_seq; Type: SEQUENCE; Schema: public; Owner: ships
--

ALTER TABLE public.ship_category ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.ship_category_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: ship_position; Type: TABLE; Schema: public; Owner: ships
--

CREATE TABLE public.ship_position (
    id bigint NOT NULL,
    voyage_id bigint NOT NULL,
    received_at timestamp with time zone NOT NULL,
    info_source_id integer NOT NULL,
    latitude numeric(9,6) NOT NULL,
    longitude numeric(9,6) NOT NULL,
    speed numeric(8,3),
    course numeric(6,2),
    rot numeric(8,3),
    heading smallint,
    nav_status_id integer,
    sea_id integer,
    CONSTRAINT chk_ship_position_course_range CHECK (((course >= (0)::numeric) AND (course < (360)::numeric))),
    CONSTRAINT chk_ship_position_heading_range CHECK (((heading >= 0) AND (heading <= 359))),
    CONSTRAINT chk_ship_position_latitude_range CHECK (((latitude >= ('-90'::integer)::numeric) AND (latitude <= (90)::numeric))),
    CONSTRAINT chk_ship_position_longitude_range CHECK (((longitude >= ('-180'::integer)::numeric) AND (longitude <= (180)::numeric))),
    CONSTRAINT chk_ship_position_received_at CHECK ((received_at >= '2000-01-01 00:00:00+00'::timestamp with time zone)),
    CONSTRAINT chk_ship_position_rot_range CHECK (((rot >= ('-720'::integer)::numeric) AND (rot <= (720)::numeric))),
    CONSTRAINT chk_ship_position_speed_max CHECK ((speed <= (100)::numeric))
);


ALTER TABLE public.ship_position OWNER TO ships;

--
-- Name: ship_position_id_seq; Type: SEQUENCE; Schema: public; Owner: ships
--

ALTER TABLE public.ship_position ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.ship_position_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: ship_type; Type: TABLE; Schema: public; Owner: ships
--

CREATE TABLE public.ship_type (
    id integer NOT NULL,
    name character varying(255) NOT NULL,
    CONSTRAINT chk_ship_type_name_clean CHECK ((((name)::text <> ''::text) AND ((name)::text = btrim((name)::text))))
);


ALTER TABLE public.ship_type OWNER TO ships;

--
-- Name: ship_type_id_seq; Type: SEQUENCE; Schema: public; Owner: ships
--

ALTER TABLE public.ship_type ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.ship_type_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: supervisor; Type: TABLE; Schema: public; Owner: ships
--

CREATE TABLE public.supervisor (
    id integer NOT NULL,
    name character varying(255) NOT NULL,
    company_id integer NOT NULL,
    CONSTRAINT chk_supervisor_name_clean CHECK ((((name)::text <> ''::text) AND ((name)::text = btrim((name)::text))))
);


ALTER TABLE public.supervisor OWNER TO ships;

--
-- Name: supervisor_id_seq; Type: SEQUENCE; Schema: public; Owner: ships
--

ALTER TABLE public.supervisor ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.supervisor_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: voyage; Type: TABLE; Schema: public; Owner: ships
--

CREATE TABLE public.voyage (
    id bigint NOT NULL,
    ship_imo integer NOT NULL,
    exit_port_id integer NOT NULL,
    destination_port_id integer NOT NULL,
    eta timestamp with time zone NOT NULL,
    country_follow_id integer,
    supervisor_id integer,
    CONSTRAINT chk_voyage_eta_range CHECK (((eta >= '2000-01-01 00:00:00+00'::timestamp with time zone) AND (eta < '2100-01-01 00:00:00+00'::timestamp with time zone))),
    CONSTRAINT chk_voyage_ports_differ CHECK ((exit_port_id <> destination_port_id))
);


ALTER TABLE public.voyage OWNER TO ships;

--
-- Name: voyage_id_seq; Type: SEQUENCE; Schema: public; Owner: ships
--

ALTER TABLE public.voyage ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.voyage_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Data for Name: company; Type: TABLE DATA; Schema: public; Owner: ships
--

COPY public.company (id, name) FROM stdin;
1	ShipVising inc.
2	AtlanticKeeper Inc.
3	OceanGuardian Ltd.
4	BalticShipping Ltd.
5	MediterraneanCruises Inc.
6	PolarResearch Corp.
7	AustralisShipping Ltd.
\.


--
-- Data for Name: country; Type: TABLE DATA; Schema: public; Owner: ships
--

COPY public.country (id, code) FROM stdin;
1	USA
2	CAN
3	NOR
4	UK
5	AUS
6	GER
7	POL
8	ITA
9	ESP
10	RUS
11	SWE
12	NZ
\.


--
-- Data for Name: info_source; Type: TABLE DATA; Schema: public; Owner: ships
--

COPY public.info_source (id, name) FROM stdin;
1	EXACTEARTH
2	SHIPFINDER
3	OCEANTRACKER
\.


--
-- Data for Name: nav_status; Type: TABLE DATA; Schema: public; Owner: ships
--

COPY public.nav_status (id, name) FROM stdin;
1	At Anchor
2	Moored
3	Underway using engine
\.


--
-- Data for Name: port; Type: TABLE DATA; Schema: public; Owner: ships
--

COPY public.port (id, name, country_id) FROM stdin;
1	KHATANGA	1
2	BETHEL	1
3	TORONTO	2
4	OSLO	3
5	VALDEZ	1
6	FALMOUTH	4
7	HAMBURG	6
8	GDANSK	7
9	GENOA	8
10	BARCELONA	9
11	MURMANSK	10
12	STOCKHOLM	11
13	SYDNEY	5
14	WELLINGTON	12
\.


--
-- Data for Name: sea; Type: TABLE DATA; Schema: public; Owner: ships
--

COPY public.sea (id, name, area_km) FROM stdin;
1	Barents Sea	1424000.00
2	Atlantic Ocean	1120000.00
3	North Sea	1300000.00
4	Baltic Sea	1030000.00
5	Mediterranean Sea	1100500.00
6	Tasman Sea	930000.00
\.


--
-- Data for Name: sea_ship_category; Type: TABLE DATA; Schema: public; Owner: ships
--

COPY public.sea_ship_category (sea_id, ship_category_id) FROM stdin;
1	1
1	2
2	3
2	4
3	5
3	2
4	3
4	2
5	4
5	6
6	3
6	2
\.


--
-- Data for Name: ship; Type: TABLE DATA; Schema: public; Owner: ships
--

COPY public.ship (imo, mmsi, call_sign, name, name_lat, flag_country_id, owner_country_id, ship_type_id) FROM stdin;
8841917	368346000	WDJ5676	SADIE	SADIE	1	1	1
9841931	377346200	KLD4921	ADVENTURER	ADVENTURER	2	2	2
8841920	368346010	WDJ5679	CORAL	CORAL	4	4	3
9841932	377346201	KLD4922	BALTIC PIONEER	BALTIC PIONEER	6	6	4
9841933	377346202	KLD4923	OCEAN TRAVELLER	OCEAN TRAVELLER	8	8	2
9841934	377346203	KLD4924	ARCTIC EXPLORER	ARCTIC EXPLORER	10	10	5
9841935	377346204	KLD4925	SOUTHERN STAR	SOUTHERN STAR	5	5	3
\.


--
-- Data for Name: ship_category; Type: TABLE DATA; Schema: public; Owner: ships
--

COPY public.ship_category (id, name) FROM stdin;
1	military
2	trade
3	commercial
4	tourism
5	research
6	cruise
\.


--
-- Data for Name: ship_position; Type: TABLE DATA; Schema: public; Owner: ships
--

COPY public.ship_position (id, voyage_id, received_at, info_source_id, latitude, longitude, speed, course, rot, heading, nav_status_id, sea_id) FROM stdin;
1	1	2023-09-09 17:07:28+00	1	60.769690	-161.751430	0.000	282.60	0.000	9	1	1
2	2	2023-09-09 19:00:00+00	2	52.465920	-142.693200	4.000	272.80	2.000	18	2	2
3	3	2023-09-09 18:00:00+00	3	54.769600	-152.751300	3.000	280.10	1.000	12	3	3
4	4	2023-09-09 20:00:00+00	2	53.501920	-141.693200	-12.000	270.00	0.000	272	3	4
5	5	2023-09-09 21:00:00+00	1	43.801710	7.693200	14.000	88.00	0.000	90	3	5
6	6	2023-09-09 22:00:00+00	1	68.961920	33.093200	16.000	330.00	0.000	334	3	1
7	7	2023-09-09 23:00:00+00	3	-33.869850	151.209300	18.000	150.00	0.000	152	3	6
8	3	2023-09-09 20:00:00+00	3	54.779600	-152.771300	3.000	280.10	1.000	12	3	3
9	4	2023-09-09 22:13:00+00	2	53.511920	-141.701200	-12.000	270.00	0.000	272	3	4
10	7	2023-09-09 23:15:13+00	3	-33.859850	151.219300	18.000	150.00	0.000	152	3	6
\.


--
-- Data for Name: ship_type; Type: TABLE DATA; Schema: public; Owner: ships
--

COPY public.ship_type (id, name) FROM stdin;
1	Tanker
2	Cruise
3	Cargo
4	Container Ship
5	Research Vessel
\.


--
-- Data for Name: supervisor; Type: TABLE DATA; Schema: public; Owner: ships
--

COPY public.supervisor (id, name, company_id) FROM stdin;
1	Sidorov Ivan Ivanovich	1
2	Anna Maria Johnson	2
3	John Doe Smith	3
4	Lars Müller	4
5	Giuseppe Verdi	5
6	Alexei Ivanov	6
7	Emily Johnson	7
\.


--
-- Data for Name: voyage; Type: TABLE DATA; Schema: public; Owner: ships
--

COPY public.voyage (id, ship_imo, exit_port_id, destination_port_id, eta, country_follow_id, supervisor_id) FROM stdin;
1	8841917	1	2	2023-09-21 18:05:05+00	2	1
2	9841931	3	4	2023-09-21 18:06:45+00	3	2
3	8841920	5	6	2023-09-21 17:50:05+00	5	3
4	9841932	7	8	2023-09-21 17:50:26+00	7	4
5	9841933	9	10	2023-10-21 18:05:05+00	9	5
6	9841934	11	12	2023-10-21 18:05:05+00	11	6
7	9841935	13	14	2023-10-21 18:05:05+00	12	7
\.


--
-- Name: company_id_seq; Type: SEQUENCE SET; Schema: public; Owner: ships
--

SELECT pg_catalog.setval('public.company_id_seq', 7, true);


--
-- Name: country_id_seq; Type: SEQUENCE SET; Schema: public; Owner: ships
--

SELECT pg_catalog.setval('public.country_id_seq', 12, true);


--
-- Name: info_source_id_seq; Type: SEQUENCE SET; Schema: public; Owner: ships
--

SELECT pg_catalog.setval('public.info_source_id_seq', 3, true);


--
-- Name: nav_status_id_seq; Type: SEQUENCE SET; Schema: public; Owner: ships
--

SELECT pg_catalog.setval('public.nav_status_id_seq', 3, true);


--
-- Name: port_id_seq; Type: SEQUENCE SET; Schema: public; Owner: ships
--

SELECT pg_catalog.setval('public.port_id_seq', 14, true);


--
-- Name: sea_id_seq; Type: SEQUENCE SET; Schema: public; Owner: ships
--

SELECT pg_catalog.setval('public.sea_id_seq', 6, true);


--
-- Name: ship_category_id_seq; Type: SEQUENCE SET; Schema: public; Owner: ships
--

SELECT pg_catalog.setval('public.ship_category_id_seq', 6, true);


--
-- Name: ship_position_id_seq; Type: SEQUENCE SET; Schema: public; Owner: ships
--

SELECT pg_catalog.setval('public.ship_position_id_seq', 10, true);


--
-- Name: ship_type_id_seq; Type: SEQUENCE SET; Schema: public; Owner: ships
--

SELECT pg_catalog.setval('public.ship_type_id_seq', 5, true);


--
-- Name: supervisor_id_seq; Type: SEQUENCE SET; Schema: public; Owner: ships
--

SELECT pg_catalog.setval('public.supervisor_id_seq', 7, true);


--
-- Name: voyage_id_seq; Type: SEQUENCE SET; Schema: public; Owner: ships
--

SELECT pg_catalog.setval('public.voyage_id_seq', 7, true);


--
-- Name: company pk_company; Type: CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.company
    ADD CONSTRAINT pk_company PRIMARY KEY (id);


--
-- Name: country pk_country; Type: CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.country
    ADD CONSTRAINT pk_country PRIMARY KEY (id);


--
-- Name: info_source pk_info_source; Type: CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.info_source
    ADD CONSTRAINT pk_info_source PRIMARY KEY (id);


--
-- Name: nav_status pk_nav_status; Type: CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.nav_status
    ADD CONSTRAINT pk_nav_status PRIMARY KEY (id);


--
-- Name: port pk_port; Type: CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.port
    ADD CONSTRAINT pk_port PRIMARY KEY (id);


--
-- Name: sea pk_sea; Type: CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.sea
    ADD CONSTRAINT pk_sea PRIMARY KEY (id);


--
-- Name: sea_ship_category pk_sea_ship_category; Type: CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.sea_ship_category
    ADD CONSTRAINT pk_sea_ship_category PRIMARY KEY (sea_id, ship_category_id);


--
-- Name: ship pk_ship; Type: CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.ship
    ADD CONSTRAINT pk_ship PRIMARY KEY (imo);


--
-- Name: ship_category pk_ship_category; Type: CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.ship_category
    ADD CONSTRAINT pk_ship_category PRIMARY KEY (id);


--
-- Name: ship_position pk_ship_position; Type: CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.ship_position
    ADD CONSTRAINT pk_ship_position PRIMARY KEY (id);


--
-- Name: ship_type pk_ship_type; Type: CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.ship_type
    ADD CONSTRAINT pk_ship_type PRIMARY KEY (id);


--
-- Name: supervisor pk_supervisor; Type: CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.supervisor
    ADD CONSTRAINT pk_supervisor PRIMARY KEY (id);


--
-- Name: voyage pk_voyage; Type: CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.voyage
    ADD CONSTRAINT pk_voyage PRIMARY KEY (id);


--
-- Name: company uq_company_name; Type: CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.company
    ADD CONSTRAINT uq_company_name UNIQUE (name);


--
-- Name: country uq_country_code; Type: CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.country
    ADD CONSTRAINT uq_country_code UNIQUE (code);


--
-- Name: info_source uq_info_source_name; Type: CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.info_source
    ADD CONSTRAINT uq_info_source_name UNIQUE (name);


--
-- Name: nav_status uq_nav_status_name; Type: CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.nav_status
    ADD CONSTRAINT uq_nav_status_name UNIQUE (name);


--
-- Name: port uq_port_name_country; Type: CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.port
    ADD CONSTRAINT uq_port_name_country UNIQUE (name, country_id);


--
-- Name: sea uq_sea_name; Type: CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.sea
    ADD CONSTRAINT uq_sea_name UNIQUE (name);


--
-- Name: ship uq_ship_call_sign; Type: CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.ship
    ADD CONSTRAINT uq_ship_call_sign UNIQUE (call_sign);


--
-- Name: ship_category uq_ship_category_name; Type: CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.ship_category
    ADD CONSTRAINT uq_ship_category_name UNIQUE (name);


--
-- Name: ship uq_ship_mmsi; Type: CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.ship
    ADD CONSTRAINT uq_ship_mmsi UNIQUE (mmsi);


--
-- Name: ship_position uq_ship_position_voyage_time; Type: CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.ship_position
    ADD CONSTRAINT uq_ship_position_voyage_time UNIQUE (voyage_id, received_at);


--
-- Name: ship_type uq_ship_type_name; Type: CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.ship_type
    ADD CONSTRAINT uq_ship_type_name UNIQUE (name);


--
-- Name: supervisor uq_supervisor_company_name; Type: CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.supervisor
    ADD CONSTRAINT uq_supervisor_company_name UNIQUE (company_id, name);


--
-- Name: voyage uq_voyage_plan; Type: CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.voyage
    ADD CONSTRAINT uq_voyage_plan UNIQUE (ship_imo, exit_port_id, destination_port_id, eta);


--
-- Name: company trg_company_delete_unused_supervisors; Type: TRIGGER; Schema: public; Owner: ships
--

CREATE TRIGGER trg_company_delete_unused_supervisors BEFORE DELETE ON public.company FOR EACH ROW EXECUTE FUNCTION public.fn_company_delete_unused_supervisors();


--
-- Name: voyage trg_voyage_forbid_delete_active; Type: TRIGGER; Schema: public; Owner: ships
--

CREATE TRIGGER trg_voyage_forbid_delete_active BEFORE DELETE ON public.voyage FOR EACH ROW EXECUTE FUNCTION public.fn_voyage_forbid_delete_active();


--
-- Name: port fk_port_country; Type: FK CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.port
    ADD CONSTRAINT fk_port_country FOREIGN KEY (country_id) REFERENCES public.country(id) ON DELETE RESTRICT;


--
-- Name: sea_ship_category fk_sea_ship_category_category; Type: FK CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.sea_ship_category
    ADD CONSTRAINT fk_sea_ship_category_category FOREIGN KEY (ship_category_id) REFERENCES public.ship_category(id) ON DELETE CASCADE;


--
-- Name: sea_ship_category fk_sea_ship_category_sea; Type: FK CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.sea_ship_category
    ADD CONSTRAINT fk_sea_ship_category_sea FOREIGN KEY (sea_id) REFERENCES public.sea(id) ON DELETE CASCADE;


--
-- Name: ship fk_ship_flag_country; Type: FK CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.ship
    ADD CONSTRAINT fk_ship_flag_country FOREIGN KEY (flag_country_id) REFERENCES public.country(id) ON DELETE RESTRICT;


--
-- Name: ship fk_ship_owner_country; Type: FK CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.ship
    ADD CONSTRAINT fk_ship_owner_country FOREIGN KEY (owner_country_id) REFERENCES public.country(id) ON DELETE RESTRICT;


--
-- Name: ship_position fk_ship_position_info_source; Type: FK CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.ship_position
    ADD CONSTRAINT fk_ship_position_info_source FOREIGN KEY (info_source_id) REFERENCES public.info_source(id) ON DELETE RESTRICT;


--
-- Name: ship_position fk_ship_position_nav_status; Type: FK CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.ship_position
    ADD CONSTRAINT fk_ship_position_nav_status FOREIGN KEY (nav_status_id) REFERENCES public.nav_status(id) ON DELETE RESTRICT;


--
-- Name: ship_position fk_ship_position_sea; Type: FK CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.ship_position
    ADD CONSTRAINT fk_ship_position_sea FOREIGN KEY (sea_id) REFERENCES public.sea(id) ON DELETE SET NULL;


--
-- Name: ship_position fk_ship_position_voyage; Type: FK CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.ship_position
    ADD CONSTRAINT fk_ship_position_voyage FOREIGN KEY (voyage_id) REFERENCES public.voyage(id) ON DELETE CASCADE;


--
-- Name: ship fk_ship_ship_type; Type: FK CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.ship
    ADD CONSTRAINT fk_ship_ship_type FOREIGN KEY (ship_type_id) REFERENCES public.ship_type(id) ON DELETE RESTRICT;


--
-- Name: supervisor fk_supervisor_company; Type: FK CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.supervisor
    ADD CONSTRAINT fk_supervisor_company FOREIGN KEY (company_id) REFERENCES public.company(id) ON DELETE RESTRICT;


--
-- Name: voyage fk_voyage_country_follow; Type: FK CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.voyage
    ADD CONSTRAINT fk_voyage_country_follow FOREIGN KEY (country_follow_id) REFERENCES public.country(id) ON DELETE RESTRICT;


--
-- Name: voyage fk_voyage_destination_port; Type: FK CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.voyage
    ADD CONSTRAINT fk_voyage_destination_port FOREIGN KEY (destination_port_id) REFERENCES public.port(id) ON DELETE RESTRICT;


--
-- Name: voyage fk_voyage_exit_port; Type: FK CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.voyage
    ADD CONSTRAINT fk_voyage_exit_port FOREIGN KEY (exit_port_id) REFERENCES public.port(id) ON DELETE RESTRICT;


--
-- Name: voyage fk_voyage_ship; Type: FK CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.voyage
    ADD CONSTRAINT fk_voyage_ship FOREIGN KEY (ship_imo) REFERENCES public.ship(imo) ON DELETE CASCADE;


--
-- Name: voyage fk_voyage_supervisor; Type: FK CONSTRAINT; Schema: public; Owner: ships
--

ALTER TABLE ONLY public.voyage
    ADD CONSTRAINT fk_voyage_supervisor FOREIGN KEY (supervisor_id) REFERENCES public.supervisor(id) ON DELETE SET NULL;


--
-- PostgreSQL database dump complete
--

\unrestrict 0X5OMp2QWUXp9SdGaRZi1Ta73bIO5qfhDhbfye1v1j8CJurI0LTKCX7L8acg4Na

