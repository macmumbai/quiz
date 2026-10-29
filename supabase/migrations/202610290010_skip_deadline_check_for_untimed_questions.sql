-- The private grading RPC must ignore stale question_deadline values unless
-- the question itself explicitly has time_limit_seconds configured.
create or replace function public.submit_answer_internal(
  p_token text,
  p_question uuid,
  p_answer jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  p public.participants%rowtype;
  q public.quizzes%rowtype;
  item public.questions%rowtype;
  correct boolean;
  awarded numeric;
  marks numeric;
  speed_factor numeric := 1;
  correct_count integer;
  matched_count integer;
  wrong_count integer;
  wrong_option_count integer;
  seconds_total numeric;
  seconds_left numeric;
  speed_enabled boolean;
  partial_enabled boolean;
  negative_percent numeric;
  answer_deadline timestamptz;
  answer_started_at timestamptz;
begin
  select * into p
  from public.participants
  where session_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    and status = 'active';
  if not found then raise exception 'Participant session expired.'; end if;

  select * into q from public.quizzes where id = p.quiz_id for update;
  select * into item from public.questions where id = p_question and quiz_id = p.quiz_id;
  if not found or q.status <> 'live'
     or (q.mode = 'live_controlled' and q.current_question_id <> p_question)
     or (q.mode = 'self_paced' and p.current_question_id <> p_question) then
    raise exception 'This question is not accepting answers.';
  end if;
  if q.answer_revealed_at is not null then raise exception 'This question is closed.'; end if;

  if q.mode = 'self_paced' and q.overall_deadline is not null
     and now() > q.overall_deadline then
    raise exception 'The overall quiz deadline has passed.';
  end if;

  if item.time_limit_seconds is not null then
    if q.mode = 'self_paced' then
      answer_deadline := p.question_deadline;
      answer_started_at := p.question_started_at;
    else
      answer_deadline := q.question_deadline;
      answer_started_at := q.current_question_started_at;
    end if;
    if answer_deadline is not null and now() > answer_deadline then
      raise exception 'The answer deadline has passed.';
    end if;
  else
    answer_deadline := null;
    answer_started_at := null;
  end if;

  if p_answer is null then raise exception 'An answer is required.'; end if;
  if item.type = 'multiple_select' then
    if jsonb_typeof(p_answer) is distinct from 'array' then
      raise exception 'Select one or more listed options.';
    end if;
    if jsonb_array_length(p_answer) = 0
       or exists (
         select 1 from jsonb_array_elements(p_answer) as submitted(value)
         where not item.options @> jsonb_build_array(submitted.value)
       ) then
      raise exception 'Select one or more listed options.';
    end if;
    if jsonb_array_length(p_answer) <> (
      select count(distinct value)
      from jsonb_array_elements(p_answer) as submitted_values(value)
    ) then raise exception 'Do not select an option more than once.'; end if;
    correct := jsonb_array_length(p_answer) = jsonb_array_length(item.correct_answer)
      and not exists (
        select 1 from jsonb_array_elements(p_answer) as submitted(value)
        where not item.correct_answer @> jsonb_build_array(submitted.value)
      );
    select jsonb_array_length(item.correct_answer),
      count(*) filter (where item.correct_answer @> jsonb_build_array(submitted.value)),
      count(*) filter (where not item.correct_answer @> jsonb_build_array(submitted.value))
    into correct_count, matched_count, wrong_count
    from jsonb_array_elements(p_answer) as submitted(value);
    select greatest(0, jsonb_array_length(item.options) - jsonb_array_length(item.correct_answer))
    into wrong_option_count;
  else
    if jsonb_typeof(p_answer) <> 'string'
       or not item.options @> jsonb_build_array(p_answer #>> '{}') then
      raise exception 'Select one listed option.';
    end if;
    correct := item.correct_answer = p_answer;
  end if;

  speed_enabled := coalesce((q.settings->'scoring'->>'speed_points_enabled')::boolean, false);
  partial_enabled := coalesce((q.settings->'scoring'->>'partial_marking')::boolean, false);
  negative_percent := least(100, greatest(0, coalesce(
    (q.settings->'scoring'->>'negative_marking_percent')::numeric, 0
  )));
  marks := case
    when correct then item.points
    when item.type = 'multiple_select' and partial_enabled and correct_count > 0
      then item.points * greatest(0,
        (matched_count::numeric / correct_count)
        - case when wrong_option_count > 0 then wrong_count::numeric / wrong_option_count else 0 end
      )
    when not correct then -item.points * negative_percent / 100
    else 0
  end;
  if speed_enabled and marks > 0 and answer_deadline is not null and answer_started_at is not null then
    seconds_total := greatest(1, extract(epoch from answer_deadline - answer_started_at));
    seconds_left := greatest(0, extract(epoch from answer_deadline - now()));
    speed_factor := least(10, greatest(1, 1 + floor(9 * seconds_left / seconds_total)));
  end if;
  awarded := marks * speed_factor;

  insert into public.answers(
    quiz_id, question_id, participant_id, answer, is_correct,
    marks_awarded, speed_points, points_awarded
  ) values (
    p.quiz_id, p_question, p.id, p_answer, correct,
    marks, speed_factor, awarded
  )
  on conflict (question_id, participant_id) do update
    set answer = excluded.answer,
        is_correct = excluded.is_correct,
        marks_awarded = excluded.marks_awarded,
        speed_points = excluded.speed_points,
        points_awarded = excluded.points_awarded,
        submitted_at = now()
    where coalesce((q.settings->>'allow_answer_changes')::boolean, false);
  if not found then raise exception 'An answer has already been submitted.'; end if;

  return jsonb_build_object(
    'accepted', true,
    'is_correct', correct,
    'marks_awarded', marks,
    'speed_points', speed_factor,
    'points_awarded', awarded
  );
end;
$$;

revoke all on function public.submit_answer_internal(text, uuid, jsonb)
  from public, anon, authenticated;
