-- Compare 10, 20, and 60 weekday baseline windows for each monitored directional L train stop pair
-- Calculate the baseline for each, then compare that baseline to the rest of the data.
-- The initial draft used 10 weekdays. After questioning whether an unusual two week period could distort the baseline, I added longer baselines

-- About the baseline:
-- Use only prior weekdays, excluding the current day
-- Require 80% usable history: 8, 16, or 48 timings
-- Baseline: Median of usable prior travel times
-- Variation: Median absolute deviation (MAD) around that baseline
-- Initial slow threshold: Greater of 10 seconds or 3 scaled MADs
-- Missing current timings or insufficient history will lead to a NULL within 'is_slow_day'

CREATE OR REPLACE VIEW public.l_train_baseline_candidates AS
WITH history AS (
    SELECT
        days.*,
        ARRAY_AGG(travel_seconds) OVER prior_10 AS timings_10,
        ARRAY_AGG(travel_seconds) OVER prior_20 AS timings_20,
        ARRAY_AGG(travel_seconds) OVER prior_60 AS timings_60
    FROM public.l_train_segment_days AS days
    WINDOW
        prior_10 AS (
            PARTITION BY a_stop, b_stop
            ORDER BY service_date
            ROWS BETWEEN 10 PRECEDING AND 1 PRECEDING
        ),
        prior_20 AS (
            PARTITION BY a_stop, b_stop
            ORDER BY service_date
            ROWS BETWEEN 20 PRECEDING AND 1 PRECEDING
        ),
        prior_60 AS (
            PARTITION BY a_stop, b_stop
            ORDER BY service_date
            ROWS BETWEEN 60 PRECEDING AND 1 PRECEDING
        )
),
candidate_stats AS (
    SELECT
        history.service_date,
        history.analysis_period,
        history.a_stop,
        history.b_stop,
        history.a_station,
        history.b_station,
        history.direction,
        history.n_trips,
        history.travel_seconds,
        history.observation_status,
        candidate.baseline_window_weekdays,
        candidate.minimum_usable_days,
        baseline.prior_usable_days,
        baseline.baseline_seconds,
        variation.mad_seconds
    FROM history

    -- Create one candidate row per window for each segment day
    CROSS JOIN LATERAL (
        VALUES
            (10, 8, history.timings_10),
            (20, 16, history.timings_20),
            (60, 48, history.timings_60)
    ) AS candidate(
        baseline_window_weekdays,
        minimum_usable_days,
        prior_times
    )

    -- Calculate the baseline when enough usable history exists
    CROSS JOIN LATERAL (
        SELECT
            COUNT(timing.seconds) AS prior_usable_days,
            CASE
                WHEN COUNT(timing.seconds) >= candidate.minimum_usable_days
                THEN PERCENTILE_CONT(0.5) WITHIN GROUP (
                    ORDER BY timing.seconds
                )
            END AS baseline_seconds
        FROM UNNEST(candidate.prior_times) AS timing(seconds)
        WHERE timing.seconds IS NOT NULL
    ) AS baseline

    -- Calculate typical variation around the historical baseline
    CROSS JOIN LATERAL (
        SELECT
            PERCENTILE_CONT(0.5) WITHIN GROUP (
                ORDER BY ABS(timing.seconds - baseline.baseline_seconds)
            ) AS mad_seconds
        FROM UNNEST(candidate.prior_times) AS timing(seconds)
        WHERE timing.seconds IS NOT NULL
          AND baseline.baseline_seconds IS NOT NULL
    ) AS variation
),
daily_scores AS (
    SELECT
        candidate_stats.*,
        travel_seconds - baseline_seconds AS extra_seconds,
        CASE
            WHEN mad_seconds IS NOT NULL
            THEN GREATEST(
                10.0,
                3.0 * 1.4826 * mad_seconds
            )
        END AS slow_threshold_seconds
    FROM candidate_stats
)
SELECT
    daily_scores.*,
    CASE
        WHEN observation_status = 'usable'
         AND slow_threshold_seconds IS NOT NULL
        THEN extra_seconds >= slow_threshold_seconds
        ELSE NULL
    END AS is_slow_day
FROM daily_scores;


-- Compare candidate windows using development data
-- Expected: 11,484 segment days per candidate
-- Scoreable days plus unknown days should equal the total

SELECT
    baseline_window_weekdays,
    minimum_usable_days,
    COUNT(*) AS development_segment_days,
    COUNT(is_slow_day) AS scoreable_days,
    COUNT(*) FILTER (
        WHERE is_slow_day
    ) AS slow_days,
    COUNT(*) FILTER (
        WHERE is_slow_day IS NULL
    ) AS unknown_days,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_slow_day)
        / NULLIF(COUNT(is_slow_day), 0),
        2
    ) AS slow_pct_of_scoreable_days
FROM public.l_train_baseline_candidates
WHERE analysis_period = 'development'
GROUP BY
    baseline_window_weekdays,
    minimum_usable_days
ORDER BY baseline_window_weekdays;
-- Each window scores 11,479 days and leaves 5 unknown
-- 10 weekdays flags 624 days (5.44%)
-- 20 weekdays flags 609 days (5.31%)
-- 60 weekdays flags 641 days (5.58%)


-- Inspect the baselines at the beginning of January
-- December and earlier warm up observations should supply the history
SELECT
    service_date,
    baseline_window_weekdays,
    prior_usable_days,
    minimum_usable_days,
    observation_status,
    ROUND(travel_seconds::numeric, 2) AS travel_seconds,
    ROUND(baseline_seconds::numeric, 2) AS baseline_seconds,
    ROUND(mad_seconds::numeric, 2) AS mad_seconds,
    ROUND(extra_seconds::numeric, 2) AS extra_seconds,
    ROUND(slow_threshold_seconds::numeric, 2) AS threshold_seconds,
    is_slow_day
FROM public.l_train_baseline_candidates
WHERE a_stop = 'L03S'
  AND b_stop = 'L05S'
  AND service_date >= DATE '2025-01-01'
  AND service_date < DATE '2025-01-06'
ORDER BY service_date, baseline_window_weekdays;


-- Confirm one row per segment day and candidate window
SELECT
    service_date,
    a_stop,
    b_stop,
    baseline_window_weekdays,
    COUNT(*) AS rows_for_key
FROM public.l_train_baseline_candidates
GROUP BY
    service_date,
    a_stop,
    b_stop,
    baseline_window_weekdays
HAVING COUNT(*) > 1;


-- Explain development days that could not be scored
-- An unknown result can come from insufficient history, an unusable current timing, or both

SELECT
    baseline_window_weekdays,
    observation_status,
    CASE
        WHEN baseline_seconds IS NULL
         AND observation_status <> 'usable'
            THEN 'insufficient_history_and_current_timing_unusable'
        WHEN baseline_seconds IS NULL
            THEN 'insufficient_history'
        ELSE 'current_timing_unusable'
    END AS reason,
    COUNT(*) AS unknown_days
FROM public.l_train_baseline_candidates
WHERE analysis_period = 'development'
  AND is_slow_day IS NULL
GROUP BY
    baseline_window_weekdays,
    observation_status,
    CASE
        WHEN baseline_seconds IS NULL
         AND observation_status <> 'usable'
            THEN 'insufficient_history_and_current_timing_unusable'
        WHEN baseline_seconds IS NULL
            THEN 'insufficient_history'
        ELSE 'current_timing_unusable'
    END
ORDER BY baseline_window_weekdays, observation_status, reason;
-- The same 5 missing timings account for all unknown flags