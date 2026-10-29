-- Question deadlines are enabled only when a quiz default or a question
-- override is configured. Keep the trigger from migration 003 as the central
-- guard for both live-controlled and self-paced quiz flows.
create or replace function public.clear_question_timer()
returns trigger
language plpgsql
set search_path = ''
as $$
declare timer_enabled boolean := false;
begin
  if new.question_deadline is null or new.question_deadline <= now() then
    return new;
  end if;

  if tg_table_name = 'quizzes' then
    select coalesce(
      question.time_limit_seconds is not null
      or nullif(new.settings->>'question_time_seconds', '') is not null,
      false
    ) into timer_enabled
    from (select 1) marker
    left join public.questions question on question.id = new.current_question_id;
  else
    select coalesce(
      question.time_limit_seconds is not null
      or nullif(quiz.settings->>'question_time_seconds', '') is not null,
      false
    ) into timer_enabled
    from public.quizzes quiz
    left join public.questions question on question.id = new.current_question_id
    where quiz.id = new.quiz_id;
  end if;

  if not coalesce(timer_enabled, false) then
    new.question_deadline := null;
  end if;
  return new;
end;
$$;
