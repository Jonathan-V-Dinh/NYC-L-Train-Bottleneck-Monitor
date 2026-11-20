-- Prepare daily segment data for the Tableau watchlist and timeline
-- Use the reserved January through April 2026 evaluation dates
-- Display the policy using 60 weekdays, multiplier 2, and 2 slow weekdays
-- Preserve missing observations so unknown days break slow streaks

CREATE OR REPLACE VIEW public.l_train_tableau_segment_days AS
WITH candidate_days AS (
    SELECT
        service_date,
        a_stop,
        b_stop,
        a_station,
        b_station,
        direction,
        n_trips,
        observation_status,
        travel_seconds,
        baseline_seconds,
        travel_seconds - baseline_seconds AS extra_seconds,
        CASE
            WHEN mad_seconds IS NOT NULL
            THEN GREATEST(10.0, 2.0 * 1.4826 * mad_seconds)
        END AS slow_threshold_seconds
    FROM public.l_train_baseline_candidates
    WHERE analysis_period = 'evaluation'
      AND baseline_window_weekdays = 60
),
scored_days AS (
    SELECT
        candidate_days.*,
        baseline_seconds + slow_threshold_seconds AS alert_boundary_seconds,
        extra_seconds >= slow_threshold_seconds AS is_slow_day
    FROM candidate_days
),
streak_groups AS (
    SELECT
        scored_days.*,
        COUNT(*) FILTER (
            WHERE is_slow_day IS DISTINCT FROM TRUE
        ) OVER (
            PARTITION BY a_stop, b_stop
            ORDER BY service_date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS streak_group
    FROM scored_days
),
streak_counts AS (
    SELECT
        streak_groups.*,
        COUNT(*) FILTER (
            WHERE is_slow_day
        ) OVER (
            PARTITION BY a_stop, b_stop, streak_group
            ORDER BY service_date
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS consecutive_slow_weekdays
    FROM streak_groups
)
SELECT
    service_date,
    a_stop || ':' || b_stop AS segment_id,
    COALESCE(a_station, a_stop) || ' to ' || COALESCE(b_station, b_stop)
        AS segment_name,
    a_stop,
    b_stop,
    direction,
    n_trips,
    observation_status,
    travel_seconds,
    baseline_seconds,
    extra_seconds,
    slow_threshold_seconds,
    alert_boundary_seconds,
    is_slow_day,
    consecutive_slow_weekdays,
    consecutive_slow_weekdays = 2 AS new_alert,
    consecutive_slow_weekdays >= 2 AS active_alert,
    CASE
        WHEN is_slow_day IS NULL THEN 'Unknown'
        WHEN consecutive_slow_weekdays = 2 THEN 'New alert'
        WHEN consecutive_slow_weekdays > 2 THEN 'Active alert'
        WHEN is_slow_day THEN 'Slow, waiting for another weekday'
        ELSE 'Below threshold'
    END AS alert_status
FROM streak_counts;

-- Check that the daily data and alert counts match the evaluation notebook

SELECT
    COUNT(*) AS segment_days,
    COUNT(DISTINCT segment_id) AS segments,
    COUNT(DISTINCT service_date) AS weekdays,
    COUNT(*) FILTER (
        WHERE consecutive_slow_weekdays = 1
    ) AS alerts_after_one_weekday,
    COUNT(*) FILTER (
        WHERE new_alert
    ) AS alerts_after_two_weekdays,
    COUNT(*) FILTER (
        WHERE consecutive_slow_weekdays = 3
    ) AS alerts_after_three_weekdays
FROM public.l_train_tableau_segment_days;

-- Run this SELECT separately and export its results to CSV

SELECT *
FROM public.l_train_tableau_segment_days
ORDER BY service_date, direction, a_stop, b_stop;