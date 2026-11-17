-- Identify L-train stop pairs with reliable weekday travel time coverage
-- Stop pairs are two consecutive stations on the L train route
-- Use 2025 to select pairs. Later evaluation dates do not affect selection
-- A pair qualifies if at least 95% of expected weekdays have a usable timing
-- Alot of L-train pairs have extremely large gaps or inconsistent data
-- We will look for pairs with qualifying data in 2025, then evaluate further in Jan - April 2026 with qualifying pairs

CREATE OR REPLACE VIEW public.l_train_segment_coverage AS
WITH settings AS (
    SELECT
        DATE '2025-01-01' AS development_start,
        DATE '2026-01-01' AS development_end_exclusive,
        0.95::numeric AS minimum_usable_coverage
),
weekdays AS (
    SELECT day::date AS service_date
    FROM settings
    CROSS JOIN LATERAL GENERATE_SERIES(
        development_start::timestamp,
        (development_end_exclusive - 1)::timestamp,
        INTERVAL '1 day'
    ) AS calendar(day)
    WHERE EXTRACT(ISODOW FROM day) BETWEEN 1 AND 5
),
development_rows AS (
    SELECT
        source.service_date,
        source.a_stop,
        source.b_stop,
        source.a_station,
        source.b_station,
        source.mean_seconds
    FROM public.subway_segment_times AS source
    CROSS JOIN settings
    WHERE source.service_date >= development_start
      AND source.service_date < development_end_exclusive
      AND source.route_ids ~ '(^|[[:space:]])L([[:space:]]|$)'
      AND source.a_stop <> source.b_stop
),
segments AS (
    SELECT DISTINCT ON (a_stop, b_stop)
        a_stop,
        b_stop,
        a_station,
        b_station
    FROM development_rows
    ORDER BY a_stop, b_stop, service_date DESC
),
coverage AS (
    SELECT
        segment.a_stop,
        segment.b_stop,
        segment.a_station,
        segment.b_station,
        COUNT(*) AS expected_weekdays,
        COUNT(source.service_date) AS observed_weekdays,
        COUNT(*) FILTER (
            WHERE source.service_date IS NULL
        ) AS missing_row_weekdays,
        COUNT(*) FILTER (
            WHERE source.service_date IS NOT NULL
              AND source.mean_seconds IS NULL
        ) AS null_timing_weekdays,
        COUNT(*) FILTER (
            WHERE source.mean_seconds <= 0
        ) AS nonpositive_timing_weekdays,
        COUNT(*) FILTER (
            WHERE source.mean_seconds > 0
        ) AS usable_weekdays,
        MIN(source.service_date) AS first_observed_date,
        MAX(source.service_date) AS last_observed_date
    FROM segments AS segment
    CROSS JOIN weekdays AS weekday
    LEFT JOIN development_rows AS source
        ON source.a_stop = segment.a_stop
       AND source.b_stop = segment.b_stop
       AND source.service_date = weekday.service_date
    GROUP BY
        segment.a_stop,
        segment.b_stop,
        segment.a_station,
        segment.b_station
)
SELECT
    coverage.*,
    ROUND(100.0 * usable_weekdays / expected_weekdays, 2)
        AS usable_coverage_pct,
    usable_weekdays::numeric / expected_weekdays >= minimum_usable_coverage
        AS eligible_for_monitoring
FROM coverage
CROSS JOIN settings;

-- Check 1: How many pairs qualify in each direction?
SELECT
    RIGHT(a_stop, 1) AS direction,
    COUNT(*) AS candidate_pairs,
    COUNT(*) FILTER (WHERE eligible_for_monitoring) AS eligible_pairs,
    COUNT(*) FILTER (WHERE NOT eligible_for_monitoring) AS excluded_pairs
FROM public.l_train_segment_coverage
GROUP BY RIGHT(a_stop, 1)
ORDER BY direction;

-- Check 2: Inspect individual pairs and see why they qualified.
SELECT
    a_stop,
    b_stop,
    a_station,
    b_station,
    expected_weekdays,
    observed_weekdays,
    missing_row_weekdays,
    null_timing_weekdays,
    nonpositive_timing_weekdays,
    usable_weekdays,
    usable_coverage_pct,
    eligible_for_monitoring
FROM public.l_train_segment_coverage
ORDER BY eligible_for_monitoring DESC, usable_coverage_pct DESC, a_stop, b_stop;

-- 2025 coverage: 59 candidate pairs and 44 eligible pairs
-- Eligible pairs: 22 run northbound and 22 run southbound
-- Union Square -> 3 Av southbound: 261 of 261 weekdays usable