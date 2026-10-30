alter table public.participants
  add column participant_started_at timestamptz,
  add column participant_deadline timestamptz;

create or replace function public.shift_participant_deadlines_after_resume()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.status = 'paused' and new.status = 'live' and old.paused_at is not null then
    update public.participants
    set participant_started_at = participant_started_at + (now() - old.paused_at),
        participant_deadline = participant_deadline + (now() - old.paused_at)
    where run_id = old.active_run_id
      and status in ('active', 'disconnected')
      and participant_started_at is not null
      and participant_deadline is not null;
  end if;
  return new;
end;
$$;

revoke all on function public.shift_participant_deadlines_after_resume()
  from public, anon, authenticated;

create trigger quizzes_shift_participant_deadlines
  after update of status on public.quizzes
  for each row
  execute function public.shift_participant_deadlines_after_resume();

create or replace function public.join_quiz(p_code text, p_name text, p_mobile text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  quiz public.quizzes%rowtype;
  participant_id uuid;
  participant_token text := encode(extensions.gen_random_bytes(32), 'hex');
  normalized_mobile text := nullif(regexp_replace(trim(coalesce(p_mobile, '')), '[^0-9]', '', 'g'), '');
begin
  select * into quiz
  from public.quizzes
  where join_code = upper(trim(p_code))
    and status in ('waiting_room', 'live', 'paused');
  if not found or quiz.active_run_id is null then
    raise exception 'This quiz is not accepting participants.';
  end if;
  if char_length(trim(p_name)) not between 1 and 80 then
    raise exception 'Enter a name between 1 and 80 characters.';
  end if;

  if not coalesce((quiz.settings->>'allow_reattempts')::boolean, false)
     and normalized_mobile is not null then
    perform pg_advisory_xact_lock(hashtextextended(
      concat_ws(
        ':',
        quiz.id::text,
        quiz.active_run_id::text,
        lower(trim(p_name)),
        normalized_mobile
      ),
      0
    ));

    if exists (
      select 1
      from public.participants participant
      where participant.quiz_id = quiz.id
        and participant.run_id = quiz.active_run_id
        and lower(trim(participant.display_name)) = lower(trim(p_name))
        and regexp_replace(coalesce(participant.mobile, ''), '[^0-9]', '', 'g') = normalized_mobile
    ) then
      raise exception 'You have already attempted this quiz with this username and phone number.';
    end if;
  end if;

  insert into public.participants(quiz_id, run_id, display_name, mobile, session_hash)
  values (
    quiz.id,
    quiz.active_run_id,
    trim(p_name),
    nullif(trim(p_mobile), ''),
    encode(extensions.digest(participant_token, 'sha256'), 'hex')
  )
  returning id into participant_id;

  return jsonb_build_object(
    'token', participant_token,
    'participant_id', participant_id,
    'quiz_id', quiz.id,
    'quiz_title', quiz.title,
    'status', quiz.status
  );
end;
$$;

revoke all on function public.join_quiz(text, text, text)
  from public, anon, authenticated;
grant execute on function public.join_quiz(text, text, text)
  to anon, authenticated;

create or replace function public.participant_state_internal(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  participant public.participants%rowtype;
  quiz public.quizzes%rowtype;
  question_data jsonb;
  answer_data jsonb;
  leaderboard_data jsonb;
  participant_score numeric;
  current_question uuid;
  question_duration integer;
  participant_duration integer;
  participant_done boolean := false;
  total_questions integer;
  has_next_question boolean := false;
  has_previous_question boolean := false;
begin
  select * into participant
  from public.participants
  where session_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    and status in ('active', 'disconnected', 'completed');
  if not found then
    raise exception 'Participant session expired. Rejoin the quiz.';
  end if;

  update public.participants
  set last_seen_at = now(),
      status = case when status = 'completed' then status else 'active' end
  where id = participant.id;

  select * into quiz
  from public.quizzes
  where id = participant.quiz_id;
  select count(*) into total_questions
  from public.questions
  where quiz_id = quiz.id;

  participant_done := participant.status = 'completed';

  if quiz.status = 'completed' and not participant_done then
    update public.participants
    set status = 'completed'
    where id = participant.id
    returning * into participant;
    participant_done := true;
  end if;

  if quiz.status = 'live' and participant.participant_deadline is null then
    participant_duration := greatest(
      1,
      coalesce((quiz.settings->>'total_time_seconds')::integer, 900)
    );
    update public.participants
    set participant_started_at = coalesce(participant_started_at, now()),
        participant_deadline = coalesce(
          participant_deadline,
          coalesce(participant_started_at, now())
            + make_interval(secs => participant_duration)
        )
    where id = participant.id
    returning * into participant;
  end if;

  if quiz.status = 'live'
     and participant.participant_deadline is not null
     and now() >= participant.participant_deadline
     and not participant_done then
    update public.participants
    set status = 'completed'
    where id = participant.id
    returning * into participant;
    participant_done := true;
  end if;

  if quiz.mode = 'self_paced'
     and quiz.status = 'live'
     and not participant_done
     and participant.current_question_id is null then
    select id, time_limit_seconds
    into current_question, question_duration
    from public.questions
    where quiz_id = quiz.id
    order by position
    limit 1;

    if current_question is not null then
      update public.participants
      set current_question_id = current_question,
          question_started_at = now(),
          question_deadline = case
            when question_duration is not null then least(
              now() + make_interval(secs => question_duration),
              participant.participant_deadline
            )
            else null
          end
      where id = participant.id
      returning * into participant;
    end if;
  end if;

  current_question := case
    when quiz.mode = 'self_paced' then participant.current_question_id
    else quiz.current_question_id
  end;

  if quiz.status = 'live' and current_question is not null and not participant_done then
    select exists (
      select 1
      from public.questions current_item
      join public.questions other_item
        on other_item.quiz_id = current_item.quiz_id
        and other_item.position > current_item.position
      where current_item.id = current_question
    ) into has_next_question;

    select exists (
      select 1
      from public.questions current_item
      join public.questions other_item
        on other_item.quiz_id = current_item.quiz_id
        and other_item.position < current_item.position
      where current_item.id = current_question
    ) into has_previous_question;

    select jsonb_build_object(
      'id', id,
      'position', position,
      'prompt', prompt,
      'type', type,
      'options', options,
      'points', points,
      'deadline', case
        when quiz.mode = 'self_paced' then participant.question_deadline
        else quiz.question_deadline
      end,
      'answer_revealed', quiz.answer_revealed_at is not null
        or quiz.status = 'completed'
        or participant_done,
      'correct_answer', case
        when quiz.answer_revealed_at is not null
          or quiz.status = 'completed'
          or participant_done
        then correct_answer
        else null
      end
    )
    into question_data
    from public.questions
    where id = current_question;

    select jsonb_build_object(
      'answer', answer,
      'points_awarded', points_awarded
    )
    into answer_data
    from public.answers
    where question_id = current_question
      and participant_id = participant.id;
  end if;

  if coalesce((quiz.settings->>'show_leaderboard')::boolean, false) then
    select coalesce(
      jsonb_agg(
        jsonb_build_object('rank', ranked.rank, 'name', ranked.display_name, 'score', ranked.score)
        order by ranked.rank
      ),
      '[]'::jsonb
    )
    into leaderboard_data
    from (
      select
        row_number() over (order by totals.total_score desc, totals.display_name asc) as rank,
        totals.display_name,
        totals.total_score as score
      from (
        select
          person.display_name,
          coalesce(sum(answer.points_awarded), 0) as total_score
        from public.participants person
        left join public.answers answer on answer.participant_id = person.id
        where person.quiz_id = quiz.id
          and person.status <> 'logged_out'
        group by person.id
      ) totals
      order by totals.total_score desc, totals.display_name asc
      limit 20
    ) ranked;
  end if;

  select coalesce(sum(points_awarded), 0)
  into participant_score
  from public.answers
  where participant_id = participant.id;

  return jsonb_build_object(
    'quiz_title', quiz.title,
    'quiz_status', quiz.status,
    'mode', quiz.mode,
    'question', question_data,
    'question_count', total_questions,
    'has_next_question', has_next_question,
    'has_previous_question', has_previous_question,
    'saved_answer', answer_data->'answer',
    'answer_submitted', answer_data is not null,
    'saved_points', answer_data->'points_awarded',
    'participant_name', participant.display_name,
    'participant_score', participant_score,
    'participant_completed', participant_done,
    'overall_deadline', participant.participant_deadline,
    'allow_navigation', coalesce((quiz.settings->>'allow_navigation')::boolean, true),
    'allow_answer_changes', coalesce((quiz.settings->>'allow_answer_changes')::boolean, false),
    'show_leaderboard', coalesce((quiz.settings->>'show_leaderboard')::boolean, false),
    'leaderboard', coalesce(leaderboard_data, '[]'::jsonb)
  );
end;
$$;

create or replace function public.participant_navigate(p_token text, p_direction text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  participant public.participants%rowtype;
  quiz public.quizzes%rowtype;
  target uuid;
  target_position integer;
  duration integer;
begin
  select * into participant
  from public.participants
  where session_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    and status = 'active'
  for update;
  if not found then
    raise exception 'Participant session expired.';
  end if;

  select * into quiz
  from public.quizzes
  where id = participant.quiz_id;
  if participant.run_id is distinct from quiz.active_run_id then
    raise exception 'This quiz session has ended. Rejoin the current quiz.';
  end if;
  if quiz.mode <> 'self_paced' or quiz.status <> 'live' then
    raise exception 'Participant navigation is available only in a live self-paced quiz.';
  end if;
  if participant.participant_deadline is not null
     and now() >= participant.participant_deadline then
    update public.participants
    set status = 'completed'
    where id = participant.id;
    return jsonb_build_object('ok', true, 'completed', true);
  end if;
  if p_direction not in ('next', 'previous') then
    raise exception 'Unknown navigation direction.';
  end if;
  if p_direction = 'previous'
     and not coalesce((quiz.settings->>'allow_navigation')::boolean, true) then
    raise exception 'Previous question navigation is disabled.';
  end if;

  select position into target_position
  from public.questions
  where id = participant.current_question_id
    and quiz_id = quiz.id;

  if p_direction = 'next' then
    select id, coalesce(time_limit_seconds, 30)
    into target, duration
    from public.questions
    where quiz_id = quiz.id
      and position > coalesce(target_position, 0)
    order by position
    limit 1;
  else
    select id, coalesce(time_limit_seconds, 30)
    into target, duration
    from public.questions
    where quiz_id = quiz.id
      and position < coalesce(target_position, 1)
    order by position desc
    limit 1;
  end if;

  if target is null and p_direction = 'next' then
    update public.participants
    set status = 'completed'
    where id = participant.id;
    return jsonb_build_object('ok', true, 'completed', true);
  elsif target is null then
    raise exception 'There are no more questions in that direction.';
  end if;

  update public.participants
  set current_question_id = target,
      question_started_at = now(),
      question_deadline = case
        when exists (
          select 1
          from public.questions
          where id = target
            and time_limit_seconds is not null
        ) then now() + make_interval(secs => duration)
        else null
      end
  where id = participant.id;
  return jsonb_build_object('ok', true, 'question_id', target);
end;
$$;

revoke all on function public.participant_navigate(text, text)
  from public, anon, authenticated;
grant execute on function public.participant_navigate(text, text)
  to anon, authenticated;

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
  participant public.participants%rowtype;
  quiz public.quizzes%rowtype;
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
  select * into participant
  from public.participants
  where session_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    and status = 'active';
  if not found then
    raise exception 'Participant session expired.';
  end if;

  select * into quiz
  from public.quizzes
  where id = participant.quiz_id
  for update;
  select * into item
  from public.questions
  where id = p_question
    and quiz_id = participant.quiz_id;

  if not found
     or quiz.status <> 'live'
     or (quiz.mode = 'live_controlled' and quiz.current_question_id <> p_question)
     or (quiz.mode = 'self_paced' and participant.current_question_id <> p_question) then
    raise exception 'This question is not accepting answers.';
  end if;
  if quiz.mode = 'live_controlled'
     and participant.run_id is distinct from quiz.active_run_id then
    raise exception 'This quiz session has ended. Rejoin the current quiz.';
  end if;
  if quiz.answer_revealed_at is not null then
    raise exception 'This question is closed.';
  end if;
  if participant.participant_deadline is not null
     and now() >= participant.participant_deadline then
    raise exception 'Your quiz time has ended.';
  end if;

  if item.time_limit_seconds is not null then
    if quiz.mode = 'self_paced' then
      answer_deadline := participant.question_deadline;
      answer_started_at := participant.question_started_at;
    else
      answer_deadline := quiz.question_deadline;
      answer_started_at := quiz.current_question_started_at;
    end if;
    if answer_deadline is not null and now() > answer_deadline then
      raise exception 'The answer deadline has passed.';
    end if;
  else
    answer_deadline := null;
    answer_started_at := null;
  end if;

  if p_answer is null then
    raise exception 'An answer is required.';
  end if;
  if item.type = 'multiple_select' then
    if jsonb_typeof(p_answer) is distinct from 'array' then
      raise exception 'Select one or more listed options.';
    end if;
    if jsonb_array_length(p_answer) = 0
       or exists (
         select 1
         from jsonb_array_elements(p_answer) as submitted(value)
         where not item.options @> jsonb_build_array(submitted.value)
       ) then
      raise exception 'Select one or more listed options.';
    end if;
    if jsonb_array_length(p_answer) <> (
      select count(distinct value)
      from jsonb_array_elements(p_answer) as submitted_values(value)
    ) then
      raise exception 'Do not select an option more than once.';
    end if;

    correct := jsonb_array_length(p_answer) = jsonb_array_length(item.correct_answer)
      and not exists (
        select 1
        from jsonb_array_elements(p_answer) as submitted(value)
        where not item.correct_answer @> jsonb_build_array(submitted.value)
      );
    select
      jsonb_array_length(item.correct_answer),
      count(*) filter (where item.correct_answer @> jsonb_build_array(submitted.value)),
      count(*) filter (where not item.correct_answer @> jsonb_build_array(submitted.value))
    into correct_count, matched_count, wrong_count
    from jsonb_array_elements(p_answer) as submitted(value);
    select greatest(
      0,
      jsonb_array_length(item.options) - jsonb_array_length(item.correct_answer)
    )
    into wrong_option_count;
  else
    if jsonb_typeof(p_answer) <> 'string'
       or not item.options @> jsonb_build_array(p_answer #>> '{}') then
      raise exception 'Select one listed option.';
    end if;
    correct := item.correct_answer = p_answer;
  end if;

  speed_enabled := coalesce((quiz.settings->'scoring'->>'speed_points_enabled')::boolean, false);
  partial_enabled := coalesce((quiz.settings->'scoring'->>'partial_marking')::boolean, false);
  negative_percent := least(100, greatest(0, coalesce(
    (quiz.settings->'scoring'->>'negative_marking_percent')::numeric,
    0
  )));
  marks := case
    when correct then item.points
    when item.type = 'multiple_select' and partial_enabled and correct_count > 0
      then item.points * greatest(
        0,
        (matched_count::numeric / correct_count)
          - case when wrong_option_count > 0
            then wrong_count::numeric / wrong_option_count
            else 0
          end
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
    quiz_id,
    question_id,
    participant_id,
    answer,
    is_correct,
    marks_awarded,
    speed_points,
    points_awarded
  )
  values (
    participant.quiz_id,
    p_question,
    participant.id,
    p_answer,
    correct,
    marks,
    speed_factor,
    awarded
  )
  on conflict (question_id, participant_id) do update
  set answer = excluded.answer,
      is_correct = excluded.is_correct,
      marks_awarded = excluded.marks_awarded,
      speed_points = excluded.speed_points,
      points_awarded = excluded.points_awarded,
      submitted_at = now()
  where coalesce((quiz.settings->>'allow_answer_changes')::boolean, false);
  if not found then
    raise exception 'An answer has already been submitted.';
  end if;

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

create or replace function public.participant_overview(p_token text)
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

  select
    count(*)::integer,
    count(*) filter (where answer.is_correct)::integer,
    count(*) filter (where not answer.is_correct)::integer,
    coalesce(sum(answer.points_awarded), 0),
    coalesce(sum(answer.marks_awarded), 0),
    coalesce(extract(epoch from (
      coalesce(
        participant.completed_at,
        max(answer.submitted_at),
        participant.participant_started_at,
        participant.joined_at
      ) - coalesce(participant.participant_started_at, participant.joined_at)
    ))::integer, 0)
  into attempted_count, correct_count, wrong_count, total_points, total_marks, time_taken_seconds
  from public.answers answer
  where answer.participant_id = participant.id;

  select count(*)::integer
  into question_count
  from public.questions
  where quiz_id = participant.quiz_id;

  select ranked.rank
  into rank_position
  from (
    select
      contestant.id,
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
