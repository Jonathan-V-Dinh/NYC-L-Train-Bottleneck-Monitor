-- Compare alert policies using 2025 development data
--
-- Detector settings:
-- 10 weekdays, 10 second minimum, variability multiplier 3
-- 60 weekdays, 10 second minimum, variability multiplier 3
-- 60 weekdays, 10 second minimum, variability multiplier 2
--
-- Compare alerts after 1, 2, or 3 consecutive slow weekdays
-- Issue one alert per streak and keep it active through the last slow day
-- Normal or unknown weekdays break the streak
-- Results use the provisional reference episodes from 07


CREATE MATERIALIZED VIEW IF NOT EXISTS
    public.l_train_development_baseline_cache AS
SELECT *
FROM public.l_train_baseline_candidates
WHERE analysis_period = 'development'
WITH NO DATA;

REFRESH MATERIALIZED VIEW public.l_train_development_baseline_cache;

CREATE UNIQUE INDEX IF NOT EXISTS
    l_train_development_baseline_cache_key
ON public.l_train_development_baseline_cache (
    a_stop,
    b_stop,
    service_date,
    baseline_window_weekdays
);

ANALYZE public.l_train_development_baseline_cache;


CREATE MATERIALIZED VIEW IF NOT EXISTS
    public.l_train_reference_days_cache AS
SELECT *
FROM public.l_train_reference_days
WHERE analysis_period = 'development'
WITH NO DATA;

REFRESH MATERIALIZED VIEW public.l_train_reference_days_cache;

CREATE UNIQUE INDEX IF NOT EXISTS
    l_train_reference_days_cache_key
ON public.l_train_reference_days_cache (
    a_stop,
    b_stop,
    service_date
);

ANALYZE public.l_train_reference_days_cache;


CREATE MATERIALIZED VIEW IF NOT EXISTS
    public.l_train_development_episodes_cache AS
SELECT *
FROM public.l_train_development_episodes
WITH NO DATA;

REFRESH MATERIALIZED VIEW public.l_train_development_episodes_cache;

CREATE UNIQUE INDEX IF NOT EXISTS
    l_train_development_episodes_cache_key
ON public.l_train_development_episodes_cache (
    a_stop,
    b_stop,
    episode_number
);

ANALYZE public.l_train_development_episodes_cache;


CREATE MATERIALIZED VIEW IF NOT EXISTS
    public.l_train_development_reference_calendar_cache AS
SELECT
    reference.*,
    ROW_NUMBER() OVER (
        PARTITION BY a_stop, b_stop
        ORDER BY service_date
    ) AS weekday_index
FROM public.l_train_reference_days_cache AS reference
WITH NO DATA;

REFRESH MATERIALIZED VIEW
    public.l_train_development_reference_calendar_cache;

CREATE UNIQUE INDEX IF NOT EXISTS
    l_train_development_reference_calendar_cache_key
ON public.l_train_development_reference_calendar_cache (
    a_stop,
    b_stop,
    weekday_index
);

ANALYZE public.l_train_development_reference_calendar_cache;


-- Calculate slow flags and identify streak groups
CREATE OR REPLACE VIEW public.l_train_development_alert_days AS
WITH detector_days AS (
    SELECT
        candidate.service_date,
        candidate.a_stop,
        candidate.b_stop,
        candidate.baseline_window_weekdays,
        configuration.variation_multiplier,
        candidate.travel_seconds,
        candidate.baseline_seconds,
        CASE
            WHEN candidate.mad_seconds IS NOT NULL
            THEN GREATEST(
                10.0,
                configuration.variation_multiplier
                    * 1.4826
                    * candidate.mad_seconds
            )
        END AS threshold_seconds
    FROM public.l_train_development_baseline_cache AS candidate
    JOIN (
        VALUES
            (10, 3.0),
            (60, 3.0),
            (60, 2.0)
    ) AS configuration(
        baseline_window_weekdays,
        variation_multiplier
    )
        ON configuration.baseline_window_weekdays =
           candidate.baseline_window_weekdays
    WHERE candidate.analysis_period = 'development'
),
scored_days AS (
    SELECT
        detector_days.*,
        CASE
            WHEN travel_seconds IS NOT NULL
             AND threshold_seconds IS NOT NULL
            THEN travel_seconds - baseline_seconds >= threshold_seconds
            ELSE NULL
        END AS is_slow_day,
        ROW_NUMBER() OVER (
            PARTITION BY
                a_stop,
                b_stop,
                baseline_window_weekdays,
                variation_multiplier
            ORDER BY service_date
        ) AS weekday_index
    FROM detector_days
)
SELECT
    scored_days.*,
    COUNT(*) FILTER (
        WHERE is_slow_day IS DISTINCT FROM TRUE
    ) OVER (
        PARTITION BY
            a_stop,
            b_stop,
            baseline_window_weekdays,
            variation_multiplier
        ORDER BY service_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS streak_group
FROM scored_days;


CREATE MATERIALIZED VIEW IF NOT EXISTS
    public.l_train_development_alert_days_cache AS
SELECT *
FROM public.l_train_development_alert_days
WITH NO DATA;

REFRESH MATERIALIZED VIEW public.l_train_development_alert_days_cache;

CREATE UNIQUE INDEX IF NOT EXISTS
    l_train_development_alert_days_cache_key
ON public.l_train_development_alert_days_cache (
    a_stop,
    b_stop,
    baseline_window_weekdays,
    variation_multiplier,
    weekday_index
);

ANALYZE public.l_train_development_alert_days_cache;


-- Issue alerts once a slow streak reaches the policy requirement
-- An alert remains active through the last slow weekday in that streak

CREATE OR REPLACE VIEW public.l_train_development_alerts AS
WITH slow_streaks AS (
    SELECT
        a_stop,
        b_stop,
        baseline_window_weekdays,
        variation_multiplier,
        streak_group,
        MIN(service_date) AS streak_start,
        MAX(service_date) AS streak_end,
        MIN(weekday_index) AS first_weekday_index,
        MAX(weekday_index) AS last_weekday_index,
        COUNT(*) AS slow_streak_weekdays
    FROM public.l_train_development_alert_days_cache
    WHERE is_slow_day
    GROUP BY
        a_stop,
        b_stop,
        baseline_window_weekdays,
        variation_multiplier,
        streak_group
)
SELECT
    streak.a_stop,
    streak.b_stop,
    streak.baseline_window_weekdays,
    streak.variation_multiplier,
    policy.wait_weekdays,
    streak.streak_start,
    streak.streak_end AS active_end,
    streak.slow_streak_weekdays,
    alert_day.service_date AS alert_date,
    alert_day.weekday_index AS alert_weekday_index,
    streak.last_weekday_index AS active_end_weekday_index
FROM slow_streaks AS streak
CROSS JOIN (
    VALUES (1), (2), (3)
) AS policy(wait_weekdays)
JOIN public.l_train_development_alert_days_cache AS alert_day
    ON alert_day.a_stop = streak.a_stop
   AND alert_day.b_stop = streak.b_stop
   AND alert_day.baseline_window_weekdays =
       streak.baseline_window_weekdays
   AND alert_day.variation_multiplier = streak.variation_multiplier
   AND alert_day.weekday_index =
       streak.first_weekday_index + policy.wait_weekdays - 1
WHERE streak.slow_streak_weekdays >= policy.wait_weekdays;


CREATE MATERIALIZED VIEW IF NOT EXISTS
    public.l_train_development_alerts_cache AS
SELECT *
FROM public.l_train_development_alerts
WITH NO DATA;

REFRESH MATERIALIZED VIEW public.l_train_development_alerts_cache;

CREATE INDEX IF NOT EXISTS
    l_train_development_alerts_cache_lookup
ON public.l_train_development_alerts_cache (
    a_stop,
    b_stop,
    baseline_window_weekdays,
    variation_multiplier,
    wait_weekdays
);

ANALYZE public.l_train_development_alerts_cache;


-- Determine whether each reference episode was detected
-- Delay is measured in weekdays, with same day detection counted as zero

CREATE OR REPLACE VIEW public.l_train_development_episode_scores AS
WITH configurations AS (
    SELECT
        detector.baseline_window_weekdays,
        detector.variation_multiplier,
        policy.wait_weekdays
    FROM (
        VALUES
            (10, 3.0),
            (60, 3.0),
            (60, 2.0)
    ) AS detector(
        baseline_window_weekdays,
        variation_multiplier
    )
    CROSS JOIN (
        VALUES (1), (2), (3)
    ) AS policy(wait_weekdays)
),
episode_matches AS (
    SELECT
        configuration.baseline_window_weekdays,
        configuration.variation_multiplier,
        configuration.wait_weekdays,
        episode.a_stop,
        episode.b_stop,
        episode.a_station,
        episode.b_station,
        episode.episode_number,
        episode.episode_start,
        episode.episode_end,
        detection.first_detection_date
    FROM public.l_train_development_episodes_cache AS episode
    CROSS JOIN configurations AS configuration
    CROSS JOIN LATERAL (
        SELECT
            MIN(
                GREATEST(alert.alert_date, episode.episode_start)
            ) AS first_detection_date
        FROM public.l_train_development_alerts_cache AS alert
        WHERE alert.a_stop = episode.a_stop
          AND alert.b_stop = episode.b_stop
          AND alert.baseline_window_weekdays =
              configuration.baseline_window_weekdays
          AND alert.variation_multiplier =
              configuration.variation_multiplier
          AND alert.wait_weekdays = configuration.wait_weekdays
          AND alert.alert_date <= episode.episode_end
          AND alert.active_end >= episode.episode_start
    ) AS detection
)
SELECT
    episode_matches.*,
    first_detection_date IS NOT NULL AS detected,
    CASE
        WHEN first_detection_date IS NOT NULL
        THEN (
            SELECT COUNT(*)
            FROM public.l_train_reference_days_cache AS reference
            WHERE reference.analysis_period = 'development'
              AND reference.a_stop = episode_matches.a_stop
              AND reference.b_stop = episode_matches.b_stop
              AND reference.service_date >= episode_matches.episode_start
              AND reference.service_date < first_detection_date
        )
    END AS detection_delay_weekdays
FROM episode_matches;


-- Classify individual alerts
CREATE OR REPLACE VIEW public.l_train_development_alert_outcomes AS
SELECT
    alert.*,
    CASE
        WHEN EXISTS (
            SELECT 1
            FROM public.l_train_development_episodes_cache AS episode
            WHERE episode.a_stop = alert.a_stop
              AND episode.b_stop = alert.b_stop
              AND alert.alert_date <= episode.episode_end
              AND alert.active_end >= episode.episode_start
        )
        THEN 'overlaps_reference_episode'

        WHEN followup.available_weekdays =
             alert.active_end_weekday_index
             - alert.alert_weekday_index + 7
         AND followup.known_weekdays = followup.available_weekdays
        THEN 'outside_reference_episodes'

        ELSE 'insufficient_followup_or_unknown'
    END AS alert_outcome
FROM public.l_train_development_alerts_cache AS alert
CROSS JOIN LATERAL (
    SELECT
        COUNT(*) AS available_weekdays,
        COUNT(reference.reference_slow_day) AS known_weekdays
    FROM public.l_train_development_reference_calendar_cache AS reference
    WHERE reference.a_stop = alert.a_stop
      AND reference.b_stop = alert.b_stop
      AND reference.weekday_index BETWEEN
          alert.alert_weekday_index
          AND alert.active_end_weekday_index + 6
) AS followup;


-- Check 1: Count alerts and their outcomes

SELECT
    baseline_window_weekdays,
    variation_multiplier,
    wait_weekdays,
    COUNT(*) AS total_alerts,
    COUNT(*) FILTER (
        WHERE alert_outcome = 'overlaps_reference_episode'
    ) AS alerts_overlapping_episodes,
    COUNT(*) FILTER (
        WHERE alert_outcome = 'outside_reference_episodes'
    ) AS alerts_outside_episodes,
    COUNT(*) FILTER (
        WHERE alert_outcome = 'insufficient_followup_or_unknown'
    ) AS unclassified_alerts
FROM public.l_train_development_alert_outcomes
GROUP BY
    baseline_window_weekdays,
    variation_multiplier,
    wait_weekdays
ORDER BY
    baseline_window_weekdays,
    variation_multiplier,
    wait_weekdays;
-- Waiting longer reduces total alerts for every detector (Waiting means require more consecutive slowdays or periods)
-- With 60 weekdays and multiplier 3, waiting 2 weekdays reduces alerts from 474 to 100
-- Alerts outside reference episodes fall from 430 to 74


-- Check 2: Compare episode detection and delay
-- Median delay covers detected episodes only, so also inspect missed episodes

SELECT
    baseline_window_weekdays,
    variation_multiplier,
    wait_weekdays,
    COUNT(*) AS reference_episodes,
    COUNT(*) FILTER (WHERE detected) AS detected_episodes,
    COUNT(*) FILTER (WHERE NOT detected) AS missed_episodes,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE detected) / COUNT(*),
        2
    ) AS detected_pct,
    PERCENTILE_CONT(0.5) WITHIN GROUP (
        ORDER BY detection_delay_weekdays
    ) AS median_delay_weekdays
FROM public.l_train_development_episode_scores
GROUP BY
    baseline_window_weekdays,
    variation_multiplier,
    wait_weekdays
ORDER BY
    baseline_window_weekdays,
    variation_multiplier,
    wait_weekdays;
-- With 60 weekdays and multiplier 3, requiring 2 weekdays retains 15 episode detections
-- Median detection delay increases from 0 to 1 weekday
-- With multiplier 2, requiring 2 or 3 weekdays detects 17 episodes
-- Their median detection delays are 1 and 4 weekdays respectively
-- Test reference sensitivity before making the final recommendation

-- Check 3: Inspect individual episode results
-- Start with the original detector and the policy requiring two slow weekdays

SELECT
    a_station,
    b_station,
    episode_start,
    episode_end,
    detected,
    first_detection_date,
    detection_delay_weekdays
FROM public.l_train_development_episode_scores
WHERE baseline_window_weekdays = 10
  AND variation_multiplier = 3
  AND wait_weekdays = 2
ORDER BY episode_start, a_station, b_station;
-- The original detector with a 2 weekday requirement detects 9 episodes and misses 12
-- It misses the 35 weekday Atlantic Av -> Broadway Junction episode
-- Halsey St -> Myrtle-Wyckoff Avs is detected 4 weekdays after onset
-- Zero delay can occur when an alert is already active at episode onset

-- Check 4: Look for invalid detection dates or delays
-- Expected result: Zero rows hopefully
SELECT *
FROM public.l_train_development_episode_scores
WHERE first_detection_date < episode_start
   OR first_detection_date > episode_end
   OR detection_delay_weekdays < 0
   OR (detected AND detection_delay_weekdays IS NULL)
   OR (NOT detected AND detection_delay_weekdays IS NOT NULL);
-- Verified 0 rows