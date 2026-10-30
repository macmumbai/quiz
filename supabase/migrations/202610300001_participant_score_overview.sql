alter table public.participants
  add column completed_at timestamptz;

update public.participants participant
set completed_at = coalesce(
  (select max(answer.submitted_at)
   from public.answers answer
   where answer.participant_id = participant.id),
  participant.joined_at
)
where participant.status = 'completed';

create or replace function public.set_participant_completed_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status = 'completed' and new.completed_at is null then
    new.completed_at := now();
  end if;
  return new;
end;
$$;

create trigger participants_set_completed_at
  before insert or update on public.participants
  for each row execute function public.set_participant_completed_at();

revoke all on function public.set_participant_completed_at()
  from public, anon, authenticated;

create function public.participant_overview(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  participant public.participants%rowtype;
  participant_run public.quiz_runs%rowtype;
  attempted_count integer;
  correct_count integer;
  wrong_count integer;
  question_count integer;
  total_points numeric;
  total_marks numeric;
  rank_position bigint;
  time_taken_seconds integer;
begin
  select * into participant
  from public.participants
  where session_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    and status in ('active', 'disconnected', 'completed');
  if not found then
    raise exception 'Participant session expired. Rejoin the quiz.';
  end if;
  if participant.status <> 'completed' then
    raise exception 'Submit your quiz before viewing the score overview.';
  end if;

  select * into participant_run
  from public.quiz_runs
  where id = participant.run_id;
  if not found then
    raise exception 'Quiz session is unavailable.';
  end if;

  select count(*)::integer,
         count(*) filter (where answer.is_correct)::integer,
         count(*) filter (where not answer.is_correct)::integer,
         coalesce(sum(answer.points_awarded), 0),
         coalesce(sum(answer.marks_awarded), 0),
         coalesce(extract(epoch from (
           coalesce(participant.completed_at, max(answer.submitted_at), participant.joined_at)
           - participant.joined_at
         ))::integer, 0)
  into attempted_count, correct_count, wrong_count, total_points, total_marks, time_taken_seconds
  from public.answers answer
  where answer.participant_id = participant.id;

  select count(*)::integer into question_count
  from public.questions
  where quiz_id = participant.quiz_id;

  select ranked.rank into rank_position
  from (
    select contestant.id,
           row_number() over (
             order by coalesce(sum(answer.points_awarded), 0) desc,
                      contestant.display_name asc,
                      contestant.id asc
           ) as rank
    from public.participants contestant
    join public.quiz_runs run on run.id = contestant.run_id
    left join public.answers answer on answer.participant_id = contestant.id
    where run.quiz_id = participant.quiz_id
      and run.leaderboard_group_id = participant_run.leaderboard_group_id
      and contestant.status = 'completed'
    group by contestant.id
  ) ranked
  where ranked.id = participant.id;

  return jsonb_build_object(
    'total_points', total_points,
    'total_marks', total_marks,
    'correct_count', correct_count,
    'wrong_count', wrong_count,
    'attempted_count', attempted_count,
    'total_questions', question_count,
    'time_taken_seconds', greatest(0, time_taken_seconds),
    'rank', rank_position
  );
end;
$$;

revoke all on function public.participant_overview(text)
  from public, anon, authenticated;
grant execute on function public.participant_overview(text)
  to anon, authenticated;
