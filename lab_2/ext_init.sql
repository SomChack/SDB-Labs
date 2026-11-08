-- Заходы судов в порты
CREATE TABLE port_call (
    enter_port           TEXT,
    enter_date           TIMESTAMP,   
    enter_fact_date      TIMESTAMP,  
    exit_date            TIMESTAMP,   
    exit_fact_date       TIMESTAMP,   
    destination_port     TEXT,       
    destination_country  TEXT,        
    ship_imo             TEXT,        
    ship_mmsi            TEXT,
    ship_callsign        TEXT,
    ship_name            TEXT,
    ship_name_lat        TEXT,
    supervising          TEXT,       
    prichal              TEXT         
);

-- Позиции судов
CREATE TABLE ship_track (
    receive_date  TIMESTAMP,
    longitude     NUMERIC,
    latitude      NUMERIC,
    asource       TEXT,
    speed         NUMERIC,
    course        NUMERIC,
    rot           NUMERIC,
    heading       NUMERIC,
    draught       NUMERIC,
    sea           TEXT,
    ship_fk       INTEGER,
    imo           TEXT,
    mmsi          TEXT,
    call_sign     TEXT,
    shipname      TEXT,
    shipname_lat  TEXT,
    nav_status    TEXT,
    flag          TEXT  
);

COPY port_call (enter_port, enter_date, enter_fact_date, exit_date, exit_fact_date,
                destination_port, destination_country, ship_imo, ship_mmsi, ship_callsign,
                ship_name, ship_name_lat, supervising, prichal)
FROM '/csv/port_data.csv'
WITH (FORMAT csv, HEADER true, NULL '',
      FORCE_NULL (enter_port, enter_date, enter_fact_date, exit_date, exit_fact_date,
                  destination_port, destination_country, ship_imo, ship_mmsi, ship_callsign,
                  ship_name, ship_name_lat, supervising, prichal));

COPY ship_track (receive_date, longitude, latitude, asource, speed, course, rot, heading,
                 draught, sea, ship_fk, imo, mmsi, call_sign, shipname, shipname_lat,
                 nav_status, flag)
FROM '/csv/ship_data.csv'
WITH (FORMAT csv, HEADER true, NULL '',
      FORCE_NULL (receive_date, longitude, latitude, asource, speed, course, rot, heading,
                  draught, sea, ship_fk, imo, mmsi, call_sign, shipname, shipname_lat,
                  nav_status, flag));
