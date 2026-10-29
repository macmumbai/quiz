-- Keep answer grading details out of the participant submit RPC. Hosts reveal
-- the correct answer (and that question's awarded marks) with Reveal answer.
alter function public.submit_answer(text, uuid, jsonb)
  rename to submit_answer_internal;
revoke all on function public.submit_answer_internal(text, uuid, jsonb)
  from public, anon, authenticated;

create function public.submit_answer(p_token text, p_question uuid, p_answer jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  answer_result jsonb;
begin
  answer_result := public.submit_answer_internal(p_token, p_question, p_answer);
  return jsonb_build_object('accepted', coalesce((answer_result->>'accepted')::boolean, true));
end;
$$;

revoke all on function public.submit_answer(text, uuid, jsonb)
  from public, anon, authenticated;
grant execute on function public.submit_answer(text, uuid, jsonb)
  to anon, authenticated;

-- Participant state may include marks for the active question only after the
-- host reveals its answer. Overall scores and leaderboard data are withheld
-- until the quiz is complete and leaderboard visibility is enabled.
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
begin
  participant_data := public.participant_state_internal(p_token);
  quiz_is_complete := participant_data->>'quiz_status' = 'completed';
  leaderboard_enabled := coalesce((participant_data->>'show_leaderboard')::boolean, false);
  answer_revealed := coalesce((participant_data->'question'->>'answer_revealed')::boolean, false);

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

revoke all on function public.participant_state(text)
  from public, anon, authenticated;
grant execute on function public.participant_state(text)
  to anon, authenticated;

-- Previous UI versions defaulted this to true. Make score disclosure opt-in.
alter table public.quizzes
  alter column settings set default '{"progression":"manual","total_time_seconds":900,"allow_navigation":true,"allow_answer_changes":false,"show_leaderboard":false,"scoring":{"speed_points_enabled":false,"partial_marking":false,"negative_marking_percent":0}}'::jsonb;

update public.quizzes
set settings = jsonb_set(settings, '{show_leaderboard}', 'false'::jsonb, true)
where settings->>'show_leaderboard' = 'true';
