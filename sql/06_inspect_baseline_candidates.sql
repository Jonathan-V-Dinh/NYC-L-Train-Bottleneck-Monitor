-- Investigate baseline candidates using development data (2025 data)
-- Identify frequently flagged stretches and disagreements between windows (10 days vs 20 days vs 30 days)
-- Inspect how often the minimum delay threshold determines the flag
-- These checks inform the next notebook and baseline selection


-- Find the most frequently flagged stretches for each window
-- Return the top 5 stretches per candidate, including ties

WITH segment_summary AS (
    SELECT
        baseline_window_weekdays,
        a_stop,
        b_stop,
        a_station,
        b_station,
        direction,
        COUNT(is_slow_day) AS scoreable_days,
        COUNT(*) FILTER (WHERE is_slow_day) AS slow_days,
        ROUND(
            100.0 * COUNT(*) FILTER (WHERE is_slow_day)
            / NULLIF(COUNT(is_slow_day), 0),
            2
        ) AS slow_pct_of_scoreable_days
    FROM public.l_train_baseline_candidates
    WHERE analysis_period = 'development'
    GROUP BY
        baseline_window_weekdays,
        a_stop,
        b_stop,
        a_station,
        b_station,
        direction
),
ranked_segments AS (
    SELECT
        segment_summary.*,
        RANK() OVER (
            PARTITION BY baseline_window_weekdays
            ORDER BY slow_days DESC
        ) AS slow_day_rank
    FROM segment_summary
)
SELECT *
FROM ranked_segments
WHERE slow_day_rank <= 5
ORDER BY baseline_window_weekdays, slow_day_rank, a_stop, b_stop;
-- East 105 St -> New Lots Av northbound ranks first for all three windows
-- Broadway Junction -> Atlantic Av southbound ranks second for all three
-- The 60 weekday baseline flags more days on both stretches
-- Inspect the timelines to understand which dates account for the difference


-- Check 2: Find stretches where candidate flags disagree most often
-- Compare only dates that all three windows can score
-- Agreement can mean all three flag a day or all three leave it unflagged

WITH daily_comparison AS (
    SELECT
        service_date,
        a_stop,
        b_stop,
        a_station,
        b_station,
        COUNT(is_slow_day) AS scoreable_candidates,
        BOOL_OR(is_slow_day) AS any_candidate_flags,
        BOOL_AND(is_slow_day) AS every_candidate_flags
    FROM public.l_train_baseline_candidates
    WHERE analysis_period = 'development'
    GROUP BY
        service_date,
        a_stop,
        b_stop,
        a_station,
        b_station
)
SELECT
    a_stop,
    b_stop,
    a_station,
    b_station,
    COUNT(*) AS comparable_days,
    COUNT(*) FILTER (
        WHERE any_candidate_flags <> every_candidate_flags
    ) AS disagreement_days,
    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE any_candidate_flags <> every_candidate_flags
        ) / COUNT(*),
        2
    ) AS disagreement_pct
FROM daily_comparison
WHERE scoreable_candidates = 3
GROUP BY a_stop, b_stop, a_station, b_station
ORDER BY disagreement_days DESC, a_stop, b_stop
LIMIT 15;
-- Broadway Junction -> Bushwick Av-Aberdeen St northbound has the most disagreement: 63 of 261 weekdays (24.14%)
-- Similar total flag counts can represent different flagged dates
-- Disagreement means at least one candidate flags a day and another does not
-- Inspect this stretch alongside East 105 St -> New Lots Av northbound to compare a sensitive result with a more consistent one


-- Check 3: Inspect which part of the threshold determines the result
-- The minimum applies when 3 scaled MADs are at most 10 seconds
-- Count only days with a usable current timing and baseline

SELECT
    baseline_window_weekdays,
    COUNT(*) AS scoreable_days,
    COUNT(*) FILTER (
        WHERE slow_threshold_seconds = 10.0
    ) AS minimum_threshold_days,
    COUNT(*) FILTER (
        WHERE slow_threshold_seconds > 10.0
    ) AS variability_threshold_days,
    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE slow_threshold_seconds = 10.0
        ) / COUNT(*),
        2
    ) AS minimum_threshold_pct
FROM public.l_train_baseline_candidates
WHERE analysis_period = 'development'
  AND is_slow_day IS NOT NULL
GROUP BY baseline_window_weekdays
ORDER BY baseline_window_weekdays;

-- The 10 second minimum determines the threshold on 83% to 85% of scoreable days
-- Historical variability raises the threshold on the remaining 15% to 17%
-- These percentages cover all scoreable days, including days with no alert
-- The minimum delay threshold should be tested during development
-- This is the smallest increase above the baseline that can trigger a slow-day flag. Currently set at 10 seconds