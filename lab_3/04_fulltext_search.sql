SELECT count(*) AS messages, count(DISTINCT m_id) AS distinct_m_id FROM disp_messages;

-- 1. Вычисляемое поле tsvector
ALTER TABLE disp_messages
    ADD COLUMN message_tsv tsvector
    GENERATED ALWAYS AS (to_tsvector('russian', coalesce(message, ''))) STORED;

-- 2. GIN индекс по вычисляемому полю
CREATE INDEX idx_disp_messages_tsv ON disp_messages USING GIN (message_tsv);

SELECT m_id, left(message_tsv::text, 120) AS tsvector_example
  FROM disp_messages
 WHERE m_id = '00000000002'
 LIMIT 1;

-- 3. Примеры полнотекстового поиска

SELECT m_id,
       round(ts_rank(message_tsv, q)::numeric, 4) AS rank,
       ts_headline('russian', message, q, 'MaxFragments=1, MaxWords=12, MinWords=5') AS fragment
  FROM disp_messages, websearch_to_tsquery('russian', 'Атомфлот') AS q
 WHERE message_tsv @@ q
 ORDER BY rank DESC, m_id
 LIMIT 5;

SET enable_seqscan = off;

EXPLAIN (ANALYZE)
SELECT m_id
  FROM disp_messages
 WHERE message_tsv @@ websearch_to_tsquery('russian', 'Атомфлот');

RESET enable_seqscan;

SELECT s.imo, s.name, count(*) AS messages
  FROM ship s
  JOIN disp_messages m ON m.message_tsv @@ phraseto_tsquery('russian', s.name)
 GROUP BY s.imo, s.name
 ORDER BY messages DESC, s.imo
 LIMIT 10;

-- 4. Материализованное представление
DROP MATERIALIZED VIEW IF EXISTS mv_message_ship_permit;

CREATE MATERIALIZED VIEW mv_message_ship_permit AS
WITH msg AS (
    SELECT row_number() OVER (ORDER BY m_id, md5(message)) AS msg_seq, m_id, message
      FROM disp_messages
), lines AS (
    SELECT m.msg_seq, m.m_id, l.line_no, btrim(l.line) AS line
      FROM msg m
     CROSS JOIN LATERAL regexp_split_to_table(m.message, E'\r?\n') WITH ORDINALITY AS l(line, line_no)
     WHERE l.line ~ '^\s*\d+\.\s'
), parsed AS (
    SELECT msg_seq, m_id, line_no,
           substring(line FROM '^\s*(\d+)\.')::int AS request_no,
           regexp_replace(regexp_replace(line, '^\s*\d+\.\s*', ''),
                          '\s+с\s*(\d{2}\.\d{2}\.\d{4})?\s+по\s*(\d{2}\.\d{2}\.\d{4})?\s*$', '') AS body,
           to_date(substring(line FROM '\sс\s+(\d{2}\.\d{2}\.\d{4})\s+по'), 'DD.MM.YYYY') AS valid_from,
           to_date(substring(line FROM '\sпо\s+(\d{2}\.\d{2}\.\d{4})\s*$'), 'DD.MM.YYYY') AS valid_to
      FROM lines
), items AS (
    SELECT msg_seq, m_id, line_no, request_no, valid_from, valid_to,
           btrim(regexp_replace(split_part(body, ' от ', 1), '\s*\([^)]*\)\s*$', '')) AS ship_name_in_msg,
           substring(split_part(body, ' от ', 1) FROM '\((\d{7})\)')::int               AS imo_in_msg,
           btrim(substr(body, position(' от ' IN body) + 4))                              AS company_in_msg
      FROM parsed
), candidates AS (
    SELECT i.*, s.imo AS ship_imo, s.name AS ship_name,
           CASE WHEN s.imo IS NULL THEN 'не найдено'
                WHEN s.imo = i.imo_in_msg THEN 'IMO'
                ELSE 'название' END AS match_type
      FROM items i
      LEFT JOIN ship s
             ON s.imo = i.imo_in_msg
             OR lower(s.name)     = lower(i.ship_name_in_msg)
             OR lower(s.name_lat) = lower(i.ship_name_in_msg)
), ranked AS (
    SELECT c.*,
           rank()  OVER (PARTITION BY msg_seq, line_no ORDER BY (match_type = 'IMO') DESC) AS rnk
      FROM candidates c
)
SELECT msg_seq, m_id, request_no, ship_name_in_msg, imo_in_msg, company_in_msg,
       valid_from, valid_to,
       (valid_to - valid_from + 1)                              AS permit_days,
       (valid_from IS NULL OR valid_to IS NULL OR valid_from <= valid_to) AS dates_ok,
       ship_imo, ship_name, match_type,
       count(ship_imo) OVER (PARTITION BY msg_seq, line_no)     AS candidates
  FROM ranked
 WHERE rnk = 1;

CREATE INDEX idx_mv_message_ship_imo   ON mv_message_ship_permit (ship_imo);
CREATE INDEX idx_mv_message_ship_dates ON mv_message_ship_permit (valid_from, valid_to);

-- 5. Демонстрация работы представления

SELECT match_type, count(*) AS rows, count(DISTINCT ship_imo) AS ships
  FROM mv_message_ship_permit
 GROUP BY match_type
 ORDER BY match_type;

SELECT m_id, request_no, ship_name_in_msg, imo_in_msg, ship_imo, ship_name, match_type,
       valid_from, valid_to, permit_days, candidates
  FROM mv_message_ship_permit
 WHERE ship_imo IS NOT NULL
 ORDER BY ship_imo, m_id, request_no
 LIMIT 15;

SELECT m_id, request_no, ship_name_in_msg, valid_from, valid_to
  FROM mv_message_ship_permit
 WHERE NOT dates_ok;

SELECT DISTINCT ship_imo, ship_name, valid_from, valid_to
  FROM mv_message_ship_permit
 WHERE ship_imo IS NOT NULL
   AND DATE '2020-08-01' BETWEEN valid_from AND valid_to
 ORDER BY ship_imo;

REFRESH MATERIALIZED VIEW mv_message_ship_permit;
