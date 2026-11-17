DROP INDEX IF EXISTS idx_ship_position_received_at;
DROP INDEX IF EXISTS idx_ship_position_utc_date;
DROP INDEX IF EXISTS idx_ship_name_lat_reverse;

ANALYZE ship_position;

SELECT count(*) AS positions FROM ship_position;

SELECT indexname, indexdef
  FROM pg_indexes
 WHERE tablename = 'ship_position'
 ORDER BY indexname;

-- 1. B-tree индекс

EXPLAIN (ANALYZE, BUFFERS)
SELECT id, voyage_id, received_at, latitude, longitude, speed
  FROM ship_position
 WHERE received_at >= TIMESTAMPTZ '2022-11-22 00:00:00+00'
   AND received_at <  TIMESTAMPTZ '2022-11-23 00:00:00+00';

CREATE INDEX idx_ship_position_received_at
    ON ship_position USING btree (received_at);

ANALYZE ship_position;

EXPLAIN (ANALYZE, BUFFERS)
SELECT id, voyage_id, received_at, latitude, longitude, speed
  FROM ship_position
 WHERE received_at >= TIMESTAMPTZ '2022-11-22 00:00:00+00'
   AND received_at <  TIMESTAMPTZ '2022-11-23 00:00:00+00';

-- 2. Функциональный индекс (индекс по выражению)

EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
  FROM ship_position
 WHERE (received_at AT TIME ZONE 'UTC')::date = DATE '2022-11-22';

CREATE INDEX idx_ship_position_utc_date
    ON ship_position (((received_at AT TIME ZONE 'UTC')::date));

ANALYZE ship_position;

EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
  FROM ship_position
 WHERE (received_at AT TIME ZONE 'UTC')::date = DATE '2022-11-22';

-- 3. Реверсивный индекс

EXPLAIN (ANALYZE)
SELECT imo, name_lat
  FROM ship
 WHERE reverse(lower(name_lat)) LIKE reverse('%ov');

CREATE INDEX idx_ship_name_lat_reverse
    ON ship (reverse(lower(name_lat)) text_pattern_ops);

ANALYZE ship;

SET enable_seqscan = off;

EXPLAIN (ANALYZE)
SELECT imo, name_lat
  FROM ship
 WHERE reverse(lower(name_lat)) LIKE reverse('%ov');

RESET enable_seqscan;

SELECT imo, name_lat
  FROM ship
 WHERE reverse(lower(name_lat)) LIKE reverse('%ov')
 ORDER BY imo;

SELECT c.relname AS index_name,
       am.amname AS method,
       pg_size_pretty(pg_relation_size(c.oid)) AS size
  FROM pg_class c
  JOIN pg_index i  ON i.indexrelid = c.oid
  JOIN pg_am am    ON am.oid = c.relam
 WHERE i.indrelid IN ('ship_position'::regclass, 'ship'::regclass)
 ORDER BY c.relname;
