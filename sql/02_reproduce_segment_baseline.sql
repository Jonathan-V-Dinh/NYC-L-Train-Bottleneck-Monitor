-- Purpose: Verify that PostgreSQL reproduces the same TransitLab browser results
-- for the southbound L from Union Square to 3 Av (L03S -> L05S).
-- Compare each day's travel time with the median of up to 10 prior rows.
-- The baseline excludes today's value and skips null travel times.
-- Use April 2026 as baseline history and display May through October 2026.
-- Expected extra seconds: 12.7 on Sep 29, 12.7 on Sep 30, 12.4 on Oct 1.

WITH segment_history AS (
    SELECT
        service_date,
        n_trips,
        mean_seconds,
        ARRAY_AGG(mean_seconds) OVER (
            ORDER BY service_date
            ROWS BETWEEN 10 PRECEDING AND 1 PRECEDING
        ) AS prior_times
    FROM public.subway_segment_times
    WHERE a_stop = 'L03S'
      AND b_stop = 'L05S'
      AND service_date >= DATE '2026-04-01'
      AND service_date < DATE '2026-11-01'
),
daily_baseline AS (
    SELECT
        service_date,
        n_trips,
        mean_seconds,
        (
            SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY seconds)
            FROM UNNEST(prior_times) AS prior(seconds)
        ) AS baseline_seconds
    FROM segment_history
)
SELECT
    service_date,
    n_trips,
    ROUND(mean_seconds::numeric, 1) AS travel_seconds,
    ROUND(baseline_seconds::numeric, 1) AS normal_seconds,
    ROUND((mean_seconds - baseline_seconds)::numeric, 1) AS extra_seconds
FROM daily_baseline
WHERE service_date >= DATE '2026-05-01'
ORDER BY service_date;

-- Verified against the TransitLab browser export: 131 matching dates
-- One displayed value differs by 0.1 seconds: extra_seconds on 2026-09-28