CREATE EXTENSION IF NOT EXISTS pgstattuple;

VACUUM ANALYZE ship_position;

SELECT * FROM pgstatindex('idx_ship_position_received_at');

INSERT INTO ship_position (voyage_id, received_at, info_source_id,
                           latitude, longitude, speed, course, rot,
                           heading, nav_status_id, sea_id)
SELECT voyage_id, received_at + INTERVAL '1 year', info_source_id,
       latitude, longitude, speed, course, rot,
       heading, nav_status_id, sea_id
  FROM ship_position
 WHERE id % 2 = 0;

DELETE FROM ship_position WHERE id % 3 = 0;

UPDATE ship_position
   SET received_at = received_at + INTERVAL '1 millisecond'
 WHERE id % 5 = 1;

SELECT * FROM pgstatindex('idx_ship_position_received_at');

VACUUM ship_position;
REINDEX INDEX idx_ship_position_received_at;
ANALYZE ship_position;

SELECT * FROM pgstatindex('idx_ship_position_received_at');
