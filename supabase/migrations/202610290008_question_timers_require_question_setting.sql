-- A quiz-wide default must not create a question countdown. Only the
-- question's explicit time_limit_seconds value enables its timer.
create or replace function public.clear_question_timer()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  timer_enabled boolean;
begin
  if new.question_deadline is null or new.question_deadline <= now() then
    return new;
  end if;

  select exists (
    select 1
    from public.questions question
    where question.id = new.current_question_id
      and question.time_limit_seconds is not null
  ) into timer_enabled;

  if not timer_enabled then
    new.question_deadline := null;
  end if;
  return new;
end;
$$;

-- Remove every legacy quiz-wide default. Preserve an active deadline only if
-- its current question has an explicit timer.
update public.quizzes quiz
set settings = quiz.settings - 'question_time_seconds',
    question_deadline = case
      when exists (
        select 1 from public.questions question
        where question.id = quiz.current_question_id
          and question.time_limit_seconds is not null
      ) then quiz.question_deadline
      else null
    end
where quiz.settings ? 'question_time_seconds'
   or (quiz.question_deadline is not null and not exists (
      select 1 from public.questions question
      where question.id = quiz.current_question_id
        and question.time_limit_seconds is not null
   ));

update public.participants participant
set question_deadline = null
where participant.question_deadline is not null
  and not exists (
    select 1 from public.questions question
    where question.id = participant.current_question_id
      and question.time_limit_seconds is not null
  );

-- participant_state can briefly construct a deadline in a local row variable
-- before the trigger clears the stored value. Mask that value in the RPC too.
create or replace function public.participant_state(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  participant_data jsonb;
  quiz_is_complete boolean;
  leaderboard_enabled boolean;
  answer_revealed boolean;
  question_timer_enabled boolean;
begin
  participant_data := public.participant_state_internal(p_token);
  quiz_is_complete := participant_data->>'quiz_status' = 'completed';
  leaderboard_enabled := coalesce((participant_data->>'show_leaderboard')::boolean, false);
  answer_revealed := coalesce((participant_data->'question'->>'answer_revealed')::boolean, false);

  select exists (
    select 1
    from public.participants participant
    join public.quizzes quiz on quiz.id = participant.quiz_id
    join public.questions question on question.id = case
      when quiz.mode = 'self_paced' then participant.current_question_id
      else quiz.current_question_id
    end
    where participant.session_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
      and question.time_limit_seconds is not null
  ) into question_timer_enabled;

  if not question_timer_enabled
     and participant_data->'question' is not null
     and participant_data->'question' <> 'null'::jsonb then
    participant_data := jsonb_set(participant_data, '{question,deadline}', 'null'::jsonb, true);
  end if;

  if not answer_revealed and not quiz_is_complete then
    participant_data := jsonb_set(participant_data, '{saved_points}', 'null'::jsonb, true);
  end if;

  if not quiz_is_complete then
    participant_data := jsonb_set(participant_data, '{leaderboard}', '[]'::jsonb, true);
    participant_data := jsonb_set(participant_data, '{show_leaderboard}', 'false'::jsonb, true);
    participant_data := jsonb_set(participant_data, '{participant_score}', 'null'::jsonb, true);
  elsif not leaderboard_enabled then
    participant_data := jsonb_set(participant_data, '{leaderboard}', '[]'::jsonb, true);
    participant_data := jsonb_set(participant_data, '{saved_points}', 'null'::jsonb, true);
    participant_data := jsonb_set(participant_data, '{participant_score}', 'null'::jsonb, true);
  end if;

  return participant_data;
end;
$$;

revoke all on function public.participant_state(text) from public, anon, authenticated;
grant execute on function public.participant_state(text) to anon, authenticated;
