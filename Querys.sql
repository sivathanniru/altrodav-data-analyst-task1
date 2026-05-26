-- =============================================================================
-- Altrodav Technologies | Data Analyst Task 1 — SQL Queries & Analytics
-- Engine  : PostgreSQL 15+
-- Author  : Candidate Submission
-- Purpose : 5 optimized analytical queries covering engagement, risk, and
--           placement metrics across the student learning platform.
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- ASSUMED SCHEMA (included for evaluator reference)
-- ─────────────────────────────────────────────────────────────────────────────
--
-- students(student_id PK, college_id FK, name, enrolled_at)
--
-- colleges(college_id PK, college_name)
--
-- aptitude_progress(
--   progress_id PK, student_id FK, current_level INT,
--   started_at TIMESTAMPTZ, reached_level_50_at TIMESTAMPTZ
-- )
--
-- learning_tracks(track_id PK, track_name, level_label)
--
-- student_track_attempts(
--   attempt_id PK, student_id FK, track_id FK,
--   status VARCHAR,   -- 'completed' | 'failed' | 'in_progress'
--   attempted_at TIMESTAMPTZ
-- )
--
-- activity_logs(
--   log_id PK, student_id FK, activity_date DATE, is_active BOOLEAN
-- )
--
-- skill_modules(skill_id PK, skill_name)
--
-- skill_completions(
--   completion_id PK, student_id FK, skill_id FK, completed_at TIMESTAMPTZ
-- )
--
-- placements(
--   placement_id PK, student_id FK, college_id FK,
--   placed BOOLEAN, placement_year INT
-- )
-- ─────────────────────────────────────────────────────────────────────────────


-- =============================================================================
-- Q1: Average time (in days) for a student to reach Level 50 in Aptitude,
--     grouped by college.
-- =============================================================================

SELECT
    c.college_name,

    -- Compute mean days-to-level-50 rounded to 2 decimal places per college
    ROUND(
        AVG(
            EXTRACT(EPOCH FROM (ap.reached_level_50_at - ap.started_at))
            / 86400.0          -- convert seconds → days
        )::NUMERIC,
        2
    ) AS avg_days_to_level_50,

    COUNT(ap.student_id) AS students_who_reached_level_50

FROM aptitude_progress  ap
JOIN students           s  ON s.student_id  = ap.student_id
JOIN colleges           c  ON c.college_id  = s.college_id

-- Only include students who have actually reached Level 50
WHERE ap.reached_level_50_at IS NOT NULL
  AND ap.current_level        >= 50

GROUP BY c.college_id, c.college_name
ORDER BY avg_days_to_level_50 ASC;   -- fastest colleges first


-- =============================================================================
-- Q2: Structural tracks / learning levels with a fail rate exceeding 40 %
--     (Dropout Risk Identification).
-- =============================================================================

WITH attempt_summary AS (
    -- Aggregate attempt counts per track in a single pass to avoid N+1 patterns
    SELECT
        track_id,
        COUNT(*)                                            AS total_attempts,
        COUNT(*) FILTER (WHERE status = 'failed')           AS failed_attempts
    FROM student_track_attempts
    GROUP BY track_id
)
SELECT
    lt.track_name,
    lt.level_label,
    ats.total_attempts,
    ats.failed_attempts,

    -- Express fail rate as a clean percentage rounded to 1 decimal place
    ROUND(
        (ats.failed_attempts::NUMERIC / NULLIF(ats.total_attempts, 0)) * 100,
        1
    ) AS fail_rate_pct

FROM attempt_summary  ats
JOIN learning_tracks  lt ON lt.track_id = ats.track_id

-- Filter to only high-risk tracks (fail rate strictly above 40 %)
WHERE (ats.failed_attempts::NUMERIC / NULLIF(ats.total_attempts, 0)) > 0.40

ORDER BY fail_rate_pct DESC;   -- highest risk at the top


-- =============================================================================
-- Q3: Count of unique students who have maintained a 7+ consecutive-day
--     active platform streak at any point in their history (Engagement).
-- =============================================================================

WITH daily_activity AS (
    -- Deduplicate: one row per student per calendar day
    SELECT DISTINCT student_id, activity_date
    FROM   activity_logs
    WHERE  is_active = TRUE
),
streak_groups AS (
    -- Classic gaps-and-islands: subtract a dense row-number from the date
    -- so that consecutive active days share the same "island" identifier
    SELECT
        student_id,
        activity_date,
        activity_date
            - (ROW_NUMBER() OVER (PARTITION BY student_id
                                  ORDER BY activity_date))::INT  AS streak_group
    FROM daily_activity
),
streak_lengths AS (
    -- Count how many consecutive days are in each island per student
    SELECT
        student_id,
        streak_group,
        COUNT(*) AS streak_days
    FROM streak_groups
    GROUP BY student_id, streak_group
)
SELECT
    -- Return a single scalar: unique students with at least one 7-day streak
    COUNT(DISTINCT student_id) AS students_with_7day_streak

FROM streak_lengths
WHERE streak_days >= 7;


-- =============================================================================
-- Q4: Skill completion rate — % of total enrolled students who have completed
--     each specific skill module.
-- =============================================================================

WITH total_students AS (
    -- Materialise the denominator once; referenced twice below
    SELECT COUNT(DISTINCT student_id) AS n FROM students
),
completions_per_skill AS (
    -- Count unique completers per skill (a student may appear multiple times)
    SELECT
        skill_id,
        COUNT(DISTINCT student_id) AS completed_by
    FROM skill_completions
    GROUP BY skill_id
)
SELECT
    sm.skill_name,
    COALESCE(cps.completed_by, 0)  AS students_completed,
    ts.n                           AS total_students,

    -- Completion rate as a percentage of all enrolled students
    ROUND(
        (COALESCE(cps.completed_by, 0)::NUMERIC / NULLIF(ts.n, 0)) * 100,
        2
    ) AS completion_rate_pct

FROM skill_modules       sm
CROSS JOIN total_students ts
LEFT JOIN  completions_per_skill cps ON cps.skill_id = sm.skill_id

ORDER BY completion_rate_pct DESC;   -- most-completed skills first


-- =============================================================================
-- Q5: Top 10 colleges ranked by historical student placement rate (all years).
-- =============================================================================

WITH placement_stats AS (
    -- One aggregation step over the placements table — avoids repeated scans
    SELECT
        college_id,
        COUNT(*)                                   AS total_students_tracked,
        COUNT(*) FILTER (WHERE placed = TRUE)      AS placed_students
    FROM placements
    GROUP BY college_id
)
SELECT
    -- Dense rank so ties share the same position with no gaps
    DENSE_RANK() OVER (ORDER BY
        ROUND(
            (ps.placed_students::NUMERIC / NULLIF(ps.total_students_tracked, 0)) * 100,
            2
        ) DESC
    )                                AS placement_rank,

    c.college_name,
    ps.total_students_tracked,
    ps.placed_students,

    -- Historical placement rate as a clean percentage
    ROUND(
        (ps.placed_students::NUMERIC / NULLIF(ps.total_students_tracked, 0)) * 100,
        2
    ) AS placement_rate_pct

FROM placement_stats  ps
JOIN colleges         c  ON c.college_id = ps.college_id

ORDER BY placement_rate_pct DESC
LIMIT 10;
