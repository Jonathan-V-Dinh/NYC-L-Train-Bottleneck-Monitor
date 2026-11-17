-- Confirm the import covers all 67 months.
SELECT
    COUNT(*) AS total_rows,
    COUNT(DISTINCT DATE_TRUNC('month', service_date)) AS months_loaded,
    MIN(service_date) AS first_date,
    MAX(service_date) AS last_date
FROM public.subway_segment_times;
-- 1,667,891 Rows
-- 67 months
-- First Date: 2021-04-01
-- Last Date: 2026-10-30

-- Basic datatypes for columns
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'subway_segment_times'
ORDER BY ordinal_position;

-- Check whether each directional stop pair has at most one row per date.
SELECT
    service_date,
    a_stop,
    b_stop,
    COUNT(*) AS rows_for_key
FROM public.subway_segment_times
GROUP BY service_date, a_stop, b_stop
HAVING COUNT(*) > 1
ORDER BY rows_for_key DESC, service_date, a_stop, b_stop;
-- No duplicates found

-- Check data quality for the L train rows we plan to analyze
SELECT
    COUNT(*) AS l_train_rows,
    COUNT(*) FILTER (
        WHERE service_date IS NULL OR a_stop IS NULL OR b_stop IS NULL
    ) AS missing_key_rows,
    COUNT(*) FILTER (WHERE mean_seconds IS NULL) AS missing_travel_times,
    COUNT(*) FILTER (WHERE mean_seconds <= 0) AS nonpositive_travel_times
FROM public.subway_segment_times
WHERE route_ids ~ '(^|[[:space:]])L([[:space:]]|$)';
-- L-train records: 60,304
-- 0 Missing Key Rows, only 68 Missing Travel times (We will keep this as Null)

-- L matches only the 60,304 rows
SELECT route_ids, COUNT(*) AS rows_
FROM public.subway_segment_times
WHERE route_ids ~ '(^|[[:space:]])L([[:space:]]|$)'
GROUP BY 1 ORDER BY 2 DESC;

-- I ran this same query within the browser data base, just a small confirmation
SELECT service_date, n_trips, mean_seconds
FROM public.subway_segment_times
WHERE a_stop = 'L03S'
  AND b_stop = 'L05S'
  AND service_date IN (DATE '2026-09-29', DATE '2026-09-30')
ORDER BY service_date;


-- Check basic assumptions about L-train source records.
SELECT
    COUNT(*) FILTER (
        WHERE EXTRACT(ISODOW FROM service_date) IN (6, 7)
    ) AS weekend_rows,
    COUNT(*) FILTER (WHERE n_trips IS NULL) AS missing_train_counts,
    COUNT(*) FILTER (WHERE n_trips < 10) AS below_minimum_train_count,
    COUNT(*) FILTER (WHERE a_stop = b_stop) AS same_stop_rows
FROM public.subway_segment_times
WHERE route_ids ~ '(^|[[:space:]])L([[:space:]]|$)';
-- Weekend rows: 0, Missing train counts: 0, Rows with fewer than 10 trains: 0
-- Same-stop rows: 1 (L28S -> L28S)

-- Check whether missing travel times cluster in certain months.
SELECT
    DATE_TRUNC('month', service_date)::date AS month,
    COUNT(*) AS l_train_rows,
    COUNT(*) FILTER (WHERE mean_seconds IS NULL) AS missing_travel_times
FROM public.subway_segment_times
WHERE route_ids ~ '(^|[[:space:]])L([[:space:]]|$)'
GROUP BY 1
HAVING COUNT(*) FILTER (WHERE mean_seconds IS NULL) > 0
ORDER BY month;
-- No one month has an extremely high amount of Missing travel times, it's generally spread out
-- Month with the most missing times only has 7 missing times