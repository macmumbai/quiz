-- Untimed questions must never retain a deadline. The old guard returned early
-- for expired deadlines, which left stale values that submit_answer rejected.
create or replace function public.clear_question_timer()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  timer_enabled boolean;
begin
  select exists (
    select 1
    from public.questions question
    where question.id = new.current_question_id
      and question.time_limit_seconds is not null
  ) into timer_enabled;

  -- Preserve a deadline set to now() by an explicit host close/reveal action;
  -- clear absent or stale deadlines for all untimed questions.
  if not timer_enabled
     and (new.question_deadline is null or new.question_deadline < now()) then
    new.question_deadline := null;
  end if;
  return new;
end;
$$;

drop trigger if exists quizzes_no_question_timer on public.quizzes;
create trigger quizzes_no_question_timer
before insert or update of question_deadline on public.quizzes
for each row execute function public.clear_question_timer();

drop trigger if exists participants_no_question_timer on public.participants;
create trigger participants_no_question_timer
before insert or update of question_deadline on public.participants
for each row execute function public.clear_question_timer();

update public.quizzes quiz
set question_deadline = null
where quiz.question_deadline is not null
  and not exists (
    select 1
    from public.questions question
    where question.id = quiz.current_question_id
      and question.time_limit_seconds is not null
  );

update public.participants participant
set question_deadline = null
where participant.question_deadline is not null
  and not exists (
    select 1
    from public.questions question
    where question.id = participant.current_question_id
      and question.time_limit_seconds is not null
  );
