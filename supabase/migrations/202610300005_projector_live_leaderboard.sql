create or replace function public.projector_state(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  quiz public.quizzes%rowtype;
  active_run public.quiz_runs%rowtype;
  question_data jsonb;
  leaderboard_data jsonb := '[]'::jsonb;
  participant_total integer;
begin
  select * into quiz
  from public.quizzes
  where join_code = upper(trim(p_code))
    and status in ('waiting_room', 'live', 'paused', 'completed');
  if not found or quiz.active_run_id is null then
    raise exception 'Quiz projector is unavailable.';
  end if;

  select * into active_run
  from public.quiz_runs
  where id = quiz.active_run_id;
  if not found then
    raise exception 'Quiz projector is unavailable.';
  end if;

  select count(*)::integer
  into participant_total
  from public.participants participant
  join public.quiz_runs run on run.id = participant.run_id
  where run.quiz_id = quiz.id
    and run.leaderboard_group_id = active_run.leaderboard_group_id
    and participant.status <> 'logged_out';

  if quiz.status in ('live', 'completed') and quiz.current_question_id is not null then
    select jsonb_build_object(
      'position', position,
      'prompt', prompt,
      'answer_revealed', quiz.answer_revealed_at is not null,
      'correct_answer', case
        when quiz.answer_revealed_at is not null then correct_answer
        else null
      end
    )
    into question_data
    from public.questions
    where id = quiz.current_question_id;
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', ranked.id,
        'rank', ranked.rank,
        'name', ranked.display_name,
        'score', ranked.score
      )
      order by ranked.rank
    ),
    '[]'::jsonb
  )
  into leaderboard_data
  from (
    select
      totals.id,
      row_number() over (
        order by totals.total_score desc, totals.display_name asc, totals.id asc
      ) as rank,
      totals.display_name,
      totals.total_score as score
    from (
      select
        participant.id,
        participant.display_name,
        coalesce(sum(answer.points_awarded), 0) as total_score
      from public.participants participant
      join public.quiz_runs run on run.id = participant.run_id
      left join public.answers answer on answer.participant_id = participant.id
      where run.quiz_id = quiz.id
        and run.leaderboard_group_id = active_run.leaderboard_group_id
        and participant.status <> 'logged_out'
      group by participant.id, participant.display_name
    ) totals
  ) ranked;

  return jsonb_build_object(
    'title', quiz.title,
    'status', quiz.status,
    'mode', quiz.mode,
    'question', question_data,
    'leaderboard', leaderboard_data,
    'participant_count', participant_total,
    'leaderboard_visible', true
  );
end;
$$;
