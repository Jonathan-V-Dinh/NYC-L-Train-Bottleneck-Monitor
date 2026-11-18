-- Identify sustained slowdown episodes in development data

-- Reference slow day: At least 10 seconds above the prior 60 weekday median
-- Use the prev requirement of at least 48 usable prior timings

-- Sustained episode: At least 5 reference slow days within 7 weekdays
-- Require all 7 weekdays to have a known reference flag

CREATE OR REPLACE VIEW public.l_train_reference_days AS
SELECT
    service_date,
    analysis_period,
    a_stop,
    b_stop,
    a_station,
    b_station,
    direction,
    travel_seconds,
    baseline_seconds AS reference_baseline_seconds,
    travel_seconds - baseline_seconds AS reference_extra_seconds,
    CASE
        WHEN travel_seconds IS NOT NULL
         AND baseline_seconds IS NOT NULL
        THEN travel_seconds - baseline_seconds >= 10.0
        ELSE NULL
    END AS reference_slow_day
FROM public.l_train_baseline_candidates
WHERE baseline_window_weekdays = 60;


-- Identify qualifying seven weekday windows
-- Each window begins on its service date and looks forward six weekdays
-- Using the prepared calendar preserves missing weekdays within the window

CREATE OR REPLACE VIEW public.l_train_development_episode_windows AS
WITH window_counts AS (
    SELECT
        service_date AS window_start,
        a_stop,
        b_stop,
        COUNT(*) OVER next_seven AS calendar_days,
        COUNT(reference_slow_day) OVER next_seven AS known_days,
        COUNT(*) FILTER (
            WHERE reference_slow_day
        ) OVER next_seven AS slow_days,
        MIN(service_date) FILTER (
            WHERE reference_slow_day
        ) OVER next_seven AS first_slow_date,
        MAX(service_date) FILTER (
            WHERE reference_slow_day
        ) OVER next_seven AS last_slow_date
    FROM public.l_train_reference_days
    WHERE analysis_period = 'development'
    WINDOW next_seven AS (
        PARTITION BY a_stop, b_stop
        ORDER BY service_date
        ROWS BETWEEN CURRENT ROW AND 6 FOLLOWING
    )
)
SELECT
    window_counts.*,
    CASE
        WHEN calendar_days < 7 THEN 'incomplete_window'
        WHEN known_days < 7 THEN 'unknown_observation'
        WHEN slow_days >= 5 THEN 'qualifying'
        ELSE 'below_persistence_requirement'
    END AS window_status
FROM window_counts;


-- Merge overlapping qualifying intervals into distinct episodes
-- Episode boundaries are the first and last slow dates in those intervals

CREATE OR REPLACE VIEW public.l_train_development_episodes AS
WITH qualifying_windows AS (
    SELECT
        a_stop,
        b_stop,
        window_start,
        first_slow_date,
        last_slow_date
    FROM public.l_train_development_episode_windows
    WHERE window_status = 'qualifying'
),
previous_intervals AS (
    SELECT
        qualifying_windows.*,
        MAX(last_slow_date) OVER (
            PARTITION BY a_stop, b_stop
            ORDER BY first_slow_date, last_slow_date, window_start
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS previous_latest_end
    FROM qualifying_windows
),
episode_starts AS (
    SELECT
        previous_intervals.*,
        CASE
            WHEN previous_latest_end IS NULL
              OR first_slow_date > previous_latest_end
            THEN 1
            ELSE 0
        END AS starts_new_episode
    FROM previous_intervals
),
numbered_intervals AS (
    SELECT
        episode_starts.*,
        SUM(starts_new_episode) OVER (
            PARTITION BY a_stop, b_stop
            ORDER BY first_slow_date, last_slow_date, window_start
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS episode_number
    FROM episode_starts
),
merged_episodes AS (
    SELECT
        a_stop,
        b_stop,
        episode_number,
        MIN(first_slow_date) AS episode_start,
        MAX(last_slow_date) AS episode_end,
        COUNT(*) AS qualifying_windows
    FROM numbered_intervals
    GROUP BY a_stop, b_stop, episode_number
)
SELECT
    episode.a_stop,
    episode.b_stop,
    reference.a_station,
    reference.b_station,
    reference.direction,
    episode.episode_number,
    episode.episode_start,
    episode.episode_end,
    episode.qualifying_windows,
    COUNT(*) AS episode_weekdays,
    COUNT(*) FILTER (
        WHERE reference.reference_slow_day
    ) AS reference_slow_days,
    MAX(reference.reference_extra_seconds) AS peak_extra_seconds,
    AVG(reference.reference_extra_seconds) AS mean_extra_seconds
FROM merged_episodes AS episode
JOIN public.l_train_reference_days AS reference
    ON reference.a_stop = episode.a_stop
   AND reference.b_stop = episode.b_stop
   AND reference.service_date BETWEEN
       episode.episode_start AND episode.episode_end
WHERE reference.analysis_period = 'development'
GROUP BY
    episode.a_stop,
    episode.b_stop,
    reference.a_station,
    reference.b_station,
    reference.direction,
    episode.episode_number,
    episode.episode_start,
    episode.episode_end,
    episode.qualifying_windows;


-- Count qualifying, unknown, and incomplete windows
-- Incomplete windows occur at the end of the development period
-- They cannot establish seven weekday streaks

SELECT
    window_status,
    COUNT(*) AS windows
FROM public.l_train_development_episode_windows
GROUP BY window_status
ORDER BY window_status;
-- Window status counts sum to 11,484 development segment days
-- Found 91 qualifying windows before merging overlaps into episodes
-- Missing timings prevent classification of 35 windows


-- Count distinct episodes and affected directional stop pairs
-- Several segment episodes can belong to the same wider service disruption
SELECT
    COUNT(*) AS sustained_episodes,
    COUNT(DISTINCT (a_stop, b_stop)) AS affected_pairs,
    ROUND(AVG(episode_weekdays), 1) AS mean_episode_weekdays,
    MAX(episode_weekdays) AS longest_episode_weekdays
FROM public.l_train_development_episodes;
-- Found 21 sustained episodes across 10 of the 44 monitored stretches
-- Episodes average 9.2 weekdays and the longest is 35 weekdays
-- Episode duration can include normal days within merged qualifying windows


-- Inspect the 15 episodes with the largest peak increase
SELECT
    a_stop,
    b_stop,
    a_station,
    b_station,
    direction,
    episode_start,
    episode_end,
    episode_weekdays,
    reference_slow_days,
    ROUND(peak_extra_seconds::numeric, 2) AS peak_extra_seconds,
    ROUND(mean_extra_seconds::numeric, 2) AS mean_extra_seconds
FROM public.l_train_development_episodes
ORDER BY peak_extra_seconds DESC, episode_start, a_stop, b_stop
LIMIT 15;
-- Investigated the 15 episodes with the largest peak increases out of 21 total
-- Atlantic Av -> Broadway Junction northbound spans 35 weekdays with 30 slow days
-- The largest displayed peak increase is 41.35 seconds on Halsey St -> Myrtle-Wyckoff Avs
-- Episode boundaries run from the first to the last slow date

-- Verify merged episodes do not overlap on the same stop pair
-- Expected result: Zero rows
WITH previous_episodes AS (
    SELECT
        a_stop,
        b_stop,
        episode_start,
        episode_end,
        LAG(episode_end) OVER (
            PARTITION BY a_stop, b_stop
            ORDER BY episode_start
        ) AS previous_episode_end
    FROM public.l_train_development_episodes
)
SELECT *
FROM previous_episodes
WHERE episode_start <= previous_episode_end;
-- Output: 0 rows