-- Initial Test after first uploading the 67 months of Data
SELECT
    COUNT(DISTINCT DATE_TRUNC('month', service_date)) AS months_loaded,
    MIN(service_date) AS first_date,
    MAX(service_date) AS last_date
FROM subway_segment_times;

SELECT
    COUNT(*) AS total_rows,
    MIN(service_date) AS first_date,
    MAX(service_date) AS last_date,
    COUNT(DISTINCT DATE_TRUNC('month', service_date)) AS months_loaded
FROM subway_segment_times;

SELECT service_date, n_trips, mean_seconds
FROM subway_segment_times
WHERE a_stop = 'L03S'
  AND b_stop = 'L05S'
  AND service_date IN (DATE '2026-09-29', DATE '2026-09-30')
ORDER BY service_date;