-- Build one row per monitored directional stop pair per weekday.
-- December 2024 provides baseline history and is excluded from scoring.
-- Use 2025 for development and January through April 2026 for evaluation.
-- Preserve missing rows and unusable travel times as separate statuses.

CREATE OR REPLACE VIEW public.l_train_segment_days AS
WITH weekdays AS (
    SELECT
        calendar.day::date AS service_date,
        CASE
            WHEN calendar.day::date < DATE '2025-01-01' THEN 'warmup'
            WHEN calendar.day::date < DATE '2026-01-01' THEN 'development'
            ELSE 'evaluation'
        END AS analysis_period
    FROM GENERATE_SERIES(
        TIMESTAMP '2024-12-01',
        TIMESTAMP '2026-04-30',
        INTERVAL '1 day'
    ) AS calendar(day)
    WHERE EXTRACT(ISODOW FROM calendar.day) BETWEEN 1 AND 5
),
monitored_pairs AS (
    SELECT a_stop, b_stop, a_station, b_station
    FROM public.l_train_segment_coverage
    WHERE eligible_for_monitoring
),
l_train_observations AS (
    SELECT service_date, a_stop, b_stop, n_trips, mean_seconds
    FROM public.subway_segment_times
    WHERE service_date >= DATE '2024-12-01'
      AND service_date < DATE '2026-05-01'
      AND route_ids ~ '(^|[[:space:]])L([[:space:]]|$)'
)
SELECT
    weekday.service_date,
    weekday.analysis_period,
    pair.a_stop,
    pair.b_stop,
    pair.a_station,
    pair.b_station,
    RIGHT(pair.a_stop, 1) AS direction,
    observation.n_trips,
    CASE
        WHEN observation.mean_seconds > 0 THEN observation.mean_seconds
    END AS travel_seconds,
    CASE
        WHEN observation.service_date IS NULL THEN 'missing_row'
        WHEN observation.mean_seconds IS NULL THEN 'null_timing'
        WHEN observation.mean_seconds <= 0 THEN 'invalid_timing'
        ELSE 'usable'
    END AS observation_status
FROM monitored_pairs AS pair
CROSS JOIN weekdays AS weekday
LEFT JOIN l_train_observations AS observation
    ON observation.service_date = weekday.service_date
   AND observation.a_stop = pair.a_stop
   AND observation.b_stop = pair.b_stop;

-- Check 1: Verify the expected calendar and observation counts by period
SELECT
    analysis_period,
    MIN(service_date) AS first_weekday,
    MAX(service_date) AS last_weekday,
    COUNT(DISTINCT service_date) AS weekdays,
    COUNT(DISTINCT (a_stop, b_stop)) AS monitored_pairs,
    COUNT(*) AS segment_days,
    COUNT(*) FILTER (WHERE observation_status = 'usable') AS usable_days,
    COUNT(*) FILTER (WHERE observation_status = 'missing_row') AS missing_rows,
    COUNT(*) FILTER (WHERE observation_status = 'null_timing') AS null_timings,
    COUNT(*) FILTER (WHERE observation_status = 'invalid_timing') AS invalid_timings
FROM public.l_train_segment_days
GROUP BY analysis_period
ORDER BY MIN(service_date);

-- Check 2: Verify that each directional pair has at most one row per weekday
SELECT
    service_date,
    a_stop,
    b_stop,
    COUNT(*) AS rows_for_key
FROM public.l_train_segment_days
GROUP BY service_date, a_stop, b_stop
HAVING COUNT(*) > 1
ORDER BY service_date, a_stop, b_stop;

-- Verified: The prepared view has zero duplicate segment day keys
-- Verified: 968 warm up, 11,484 development, and 3,784 evaluation segment days
-- Development has 5 null timings. Evaluation has 24 missing rows and 1 null timing
-- No invalid timings or duplicate segment day keys were found