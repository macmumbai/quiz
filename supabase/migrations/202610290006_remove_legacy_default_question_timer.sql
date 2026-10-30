-- The former quiz creation form prefilled a 30-second default, so old quizzes
-- may carry that value even when the user never chose a question timer. Treat
-- that historical default as unset while preserving custom defaults and
-- explicit per-question limits.
alter table public.quizzes
  alter column settings set default '{"progression":"manual","total_time_seconds":900,"allow_navigation":true,"allow_answer_changes":false,"show_leaderboard":true,"scoring":{"speed_points_enabled":false,"partial_marking":false,"negative_marking_percent":0}}'::jsonb;

update public.quizzes
set settings = settings - 'question_time_seconds'
where settings->>'question_time_seconds' = '30';
