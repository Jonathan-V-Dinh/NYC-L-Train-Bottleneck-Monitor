-- Goal: Calculate historical baselines and flag unusually slow days
-- Baseline: Median travel time across the previous 10 scheduled weekdays
-- Require at least 8 usable timings within that window
-- Variation: Median absolute deviation (MAD) around the prior window median
-- Slow-day threshold: The larger of 10 seconds or 3 scaled MADs.
--
-- All calculations exclude the current day's timing
-- Warm up dates remain available to calculate early January baselines
-- Missing observations or insufficient history produce an unknown flag
-- Inspect these initial settings using development data before evaluation.

CREATE OR REPLACE VIEW public.l_train_segment_baselines AS
WITH settings AS (
    SELECT
        8 AS minimum_usable_days,
        10.0::double precision AS minimum_extra_seconds,
        3.0::double precision AS variation_multiplier,
        1.4826::double precision AS mad_scale
),
history AS (
    SELECT
        days.*,
        ARRAY_AGG(travel_seconds) OVER prior_weekdays AS prior_times,
        COUNT(travel_seconds) OVER prior_weekdays AS prior_usable_days
    FROM public.l_train_segment_days AS days
    WINDOW prior_weekdays AS (
        PARTITION BY a_stop, b_stop
        ORDER BY service_date
        ROWS BETWEEN 10 PRECEDING AND 1 PRECEDING
    )
),
baseline_stats AS (
    SELECT
        history.*,
        baseline.baseline_seconds,
        variation.mad_seconds
    FROM history
    CROSS JOIN settings

    -- Calculate the median of the usable prior timings.
    CROSS JOIN LATERAL (
        SELECT
            PERCENTILE_CONT(0.5) WITHIN GROUP (
                ORDER BY timing.seconds
            ) AS baseline_seconds
        FROM UNNEST(history.prior_times) AS timing(seconds)
        WHERE history.prior_usable_days >= settings.minimum_usable_days
          AND timing.seconds IS NOT NULL
    ) AS baseline

    -- Calculate the median distance from that same historical median.
    CROSS JOIN LATERAL (
        SELECT
            PERCENTILE_CONT(0.5) WITHIN GROUP (
                ORDER BY ABS(timing.seconds - baseline.baseline_seconds)
            ) AS mad_seconds
        FROM UNNEST(history.prior_times) AS timing(seconds)
        WHERE baseline.baseline_seconds IS NOT NULL
          AND timing.seconds IS NOT NULL
    ) AS variation
),
daily_scores AS (
    SELECT
        service_date,
        analysis_period,
        a_stop,
        b_stop,
        a_station,
        b_station,
        direction,
        n_trips,
        travel_seconds,
        observation_status,
        prior_usable_days,
        baseline_seconds,
        mad_seconds,
        travel_seconds - baseline_seconds AS extra_seconds,
        CASE
            WHEN mad_seconds IS NOT NULL
            THEN GREATEST(
                settings.minimum_extra_seconds,
                settings.variation_multiplier
                    * settings.mad_scale
                    * mad_seconds
            )
        END AS slow_threshold_seconds
    FROM baseline_stats
    CROSS JOIN settings
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


-- Check 1: Summarize development results.
-- Expected total: 11,484 segment-days.
-- Scoreable days + unknown days should equal the total.
SELECT
    COUNT(*) AS development_segment_days,
    COUNT(is_slow_day) AS scoreable_days,
    COUNT(*) FILTER (WHERE is_slow_day) AS slow_days,
    COUNT(*) FILTER (WHERE is_slow_day IS NULL) AS unknown_days,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE is_slow_day)
        / NULLIF(COUNT(is_slow_day), 0),
        2
    ) AS slow_pct_of_scoreable_days
FROM public.l_train_segment_baselines
WHERE analysis_period = 'development';


-- Check 2: Confirm December supplies history for early January.
-- Union Square -> 3 Av should have 10 usable prior timings on January 1.
SELECT
    service_date,
    observation_status,
    prior_usable_days,
    ROUND(travel_seconds::numeric, 2) AS travel_seconds,
    ROUND(baseline_seconds::numeric, 2) AS baseline_seconds,
    ROUND(mad_seconds::numeric, 2) AS mad_seconds,
    ROUND(extra_seconds::numeric, 2) AS extra_seconds,
    ROUND(slow_threshold_seconds::numeric, 2) AS threshold_seconds,
    is_slow_day
FROM public.l_train_segment_baselines
WHERE a_stop = 'L03S'
  AND b_stop = 'L05S'
  AND service_date >= DATE '2025-01-01'
  AND service_date < DATE '2025-01-09'
ORDER BY service_date;


-- Check 3: Inspect why development days could not be scored.
SELECT
    observation_status,
    prior_usable_days,
    COUNT(*) AS unknown_days
FROM public.l_train_segment_baselines
WHERE analysis_period = 'development'
  AND is_slow_day IS NULL
GROUP BY observation_status, prior_usable_days
ORDER BY observation_status, prior_usable_days;