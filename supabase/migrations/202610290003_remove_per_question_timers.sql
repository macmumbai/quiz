-- Keep the existing RPCs compatible while ensuring question countdowns never
-- limit participant answers. A deadline at or before now remains a sentinel
-- used by host actions that explicitly close a live question.
create or replace function public.clear_question_timer()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.question_deadline is not null and new.question_deadline > now() then
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

update public.quizzes set question_deadline = null where question_deadline is not null;
update public.participants set question_deadline = null where question_deadline is not null;
