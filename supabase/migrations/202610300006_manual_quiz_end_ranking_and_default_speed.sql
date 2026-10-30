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
  duration numeric;
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

  duration := coalesce(question.time_limit_seconds, 60);
  started_at := case
    when quiz.mode = 'self_paced' then participant.question_started_at
    else quiz.current_question_started_at
  end;
  if new.marks_awarded > 0 and started_at is not null then
    elapsed := greatest(0, extract(epoch from (coalesce(new.submitted_at, now()) - started_at)));
    multiplier := least(10, greatest(1, 1 + floor(9 * greatest(0, duration - elapsed) / duration)));
  end if;

  new.speed_points := multiplier;
  new.points_awarded := new.marks_awarded * multiplier;
  return new;
end;
$$;

revoke all on function public.apply_question_speed_points()
  from public, anon, authenticated;

drop trigger if exists answers_apply_question_speed_points on public.answers;
create trigger answers_apply_question_speed_points
  before insert or update of quiz_id, question_id, participant_id, marks_awarded, submitted_at
  on public.answers
  for each row execute function public.apply_question_speed_points();

create function public.quiz_ranked_leaderboard(
  p_run uuid,
  p_completed_only boolean,
  p_limit integer
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with selected_run as (
    select quiz_id, leaderboard_group_id
    from public.quiz_runs
    where id = p_run
  ), totals as (
    select
      participant.id,
      participant.display_name,
      participant.completed_at,
      coalesce(sum(answer.points_awarded), 0) as total_score
    from public.participants participant
    join public.quiz_runs run on run.id = participant.run_id
    join selected_run selected
      on selected.quiz_id = run.quiz_id
      and selected.leaderboard_group_id = run.leaderboard_group_id
    left join public.answers answer on answer.participant_id = participant.id
    where participant.status <> 'logged_out'
      and (not p_completed_only or participant.status = 'completed')
    group by participant.id, participant.display_name, participant.completed_at
  ), ranked as (
    select
      totals.id,
      totals.display_name,
      totals.total_score,
      row_number() over (
        order by totals.total_score desc, totals.completed_at asc nulls last, totals.id asc
      ) as rank_position
    from totals
    order by totals.total_score desc, totals.completed_at asc nulls last, totals.id asc
    limit p_limit
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', ranked.id,
        'rank', ranked.rank_position,
        'name', ranked.display_name,
        'score', ranked.total_score
      ) order by ranked.rank_position
    ),
    '[]'::jsonb
  )
  from ranked;
$$;

revoke all on function public.quiz_ranked_leaderboard(uuid, boolean, integer)
  from public, anon, authenticated;

alter function public.participant_state_internal(text)
  rename to participant_state_internal_before_ranking;
revoke all on function public.participant_state_internal_before_ranking(text)
  from public, anon, authenticated;

create function public.participant_state_internal(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  participant_run uuid;
  participant_data jsonb;
begin
  participant_data := public.participant_state_internal_before_ranking(p_token);
  if coalesce((participant_data->>'show_leaderboard')::boolean, false) then
    select run_id into participant_run
    from public.participants
    where session_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
      and status in ('active', 'disconnected', 'completed');
    if participant_run is not null then
      participant_data := jsonb_set(
        participant_data,
        '{leaderboard}',
        public.quiz_ranked_leaderboard(participant_run, false, 20),
        true
      );
    end if;
  end if;
  return participant_data;
end;
$$;

revoke all on function public.participant_state_internal(text)
  from public, anon, authenticated;

alter function public.projector_state(text)
  rename to projector_state_before_ranking;
revoke all on function public.projector_state_before_ranking(text)
  from public, anon, authenticated;

create function public.projector_state(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  projector_data jsonb;
  active_run uuid;
begin
  projector_data := public.projector_state_before_ranking(p_code);
  if coalesce((projector_data->>'leaderboard_visible')::boolean, false) then
    select quiz.active_run_id into active_run
    from public.quizzes quiz
    where quiz.join_code = upper(trim(p_code))
      and quiz.status in ('waiting_room', 'live', 'paused', 'completed');
    if active_run is not null then
      projector_data := jsonb_set(
        projector_data,
        '{leaderboard}',
        public.quiz_ranked_leaderboard(active_run, true, 50),
        true
      );
    end if;
  end if;
  return projector_data;
end;
$$;

revoke all on function public.projector_state(text)
  from public, anon, authenticated;
grant execute on function public.projector_state(text)
  to anon, authenticated;

alter function public.participant_overview(text)
  rename to participant_overview_before_tiebreak;
revoke all on function public.participant_overview_before_tiebreak(text)
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
  overview_data jsonb;
  rank_position bigint;
begin
  overview_data := public.participant_overview_before_tiebreak(p_token);
  select * into participant
  from public.participants
  where session_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    and status = 'completed';
  select * into participant_run
  from public.quiz_runs
  where id = participant.run_id;

  select ranked.rank_position into rank_position
  from (
    select
      contestant.id,
      row_number() over (
        order by coalesce(sum(answer.points_awarded), 0) desc,
                 contestant.completed_at asc nulls last,
                 contestant.id asc
      ) as rank_position
    from public.participants contestant
    join public.quiz_runs run on run.id = contestant.run_id
    left join public.answers answer on answer.participant_id = contestant.id
    where run.quiz_id = participant.quiz_id
      and run.leaderboard_group_id = participant_run.leaderboard_group_id
      and contestant.status = 'completed'
    group by contestant.id, contestant.completed_at
  ) ranked
  where ranked.id = participant.id;

  return jsonb_set(
    overview_data,
    '{rank}',
    coalesce(to_jsonb(rank_position), 'null'::jsonb),
    true
  );
end;
$$;

revoke all on function public.participant_overview(text)
  from public, anon, authenticated;
grant execute on function public.participant_overview(text)
  to anon, authenticated;

alter function public.admin_quiz_control(uuid, text, uuid, boolean)
  rename to admin_quiz_control_before_manual_end;
revoke all on function public.admin_quiz_control_before_manual_end(uuid, text, uuid, boolean)
  from public, anon, authenticated;

create function public.admin_quiz_control(
  p_quiz uuid,
  p_action text,
  p_question uuid default null,
  p_merge_leaderboard boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  quiz public.quizzes%rowtype;
begin
  if p_action = 'end' then
    if not public.is_admin() then
      raise exception 'Administrator access required.';
    end if;
    select * into quiz
    from public.quizzes
    where id = p_quiz
      and owner_id = (select auth.uid())
    for update;
    if not found then
      raise exception 'Quiz not found.';
    end if;
    if quiz.status not in ('live', 'paused', 'waiting_room') then
      raise exception 'Only an open quiz can be ended.';
    end if;

    update public.participants
    set status = 'completed'
    where run_id = quiz.active_run_id
      and status not in ('completed', 'logged_out');
  end if;

  return public.admin_quiz_control_before_manual_end(
    p_quiz,
    p_action,
    p_question,
    p_merge_leaderboard
  );
end;
$$;

revoke all on function public.admin_quiz_control(uuid, text, uuid, boolean)
  from public, anon, authenticated;
grant execute on function public.admin_quiz_control(uuid, text, uuid, boolean)
  to authenticated;