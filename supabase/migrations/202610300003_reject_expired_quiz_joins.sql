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
  if quiz.status = 'live'
     and quiz.overall_deadline is not null
     and now() >= quiz.overall_deadline then
    raise exception 'This quiz has ended. Ask the host to open a new run.';
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
