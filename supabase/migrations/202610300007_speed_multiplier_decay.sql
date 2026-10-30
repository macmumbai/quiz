create or replace function public.apply_question_speed_points()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  question public.questions%rowtype;
  participant public.participants%rowtype;
  quiz public.quizzes%rowtype;
  started_at timestamptz;
  elapsed numeric;
  multiplier numeric := 1;
begin
  select * into question from public.questions where id = new.question_id;
  select * into participant from public.participants where id = new.participant_id;
  select * into quiz from public.quizzes where id = new.quiz_id;
  if question.id is null or participant.id is null or quiz.id is null then
    return new;
  end if;

  started_at := case
    when quiz.mode = 'self_paced' then participant.question_started_at
    else quiz.current_question_started_at
  end;
  if new.marks_awarded > 0 and started_at is not null then
    elapsed := greatest(0, extract(epoch from (coalesce(new.submitted_at, now()) - started_at)));
    multiplier := greatest(1, 10 - 0.16 * elapsed);
  end if;

  new.speed_points := multiplier;
  new.points_awarded := new.marks_awarded * multiplier;
  return new;
end;
$$;

revoke all on function public.apply_question_speed_points()
  from public, anon, authenticated;