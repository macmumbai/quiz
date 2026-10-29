-- Keep the original participant state RPC as a private implementation, then
-- expose a wrapper that removes standings until the quiz has ended.
alter function public.participant_state(text) rename to participant_state_internal;
revoke all on function public.participant_state_internal(text) from public, anon, authenticated;

create function public.participant_state(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  participant_data jsonb;
begin
  participant_data := public.participant_state_internal(p_token);
  if participant_data->>'quiz_status' is distinct from 'completed' then
    participant_data := jsonb_set(participant_data, '{leaderboard}', '[]'::jsonb, true);
    participant_data := jsonb_set(participant_data, '{show_leaderboard}', 'false'::jsonb, true);
  end if;
  return participant_data;
end;
$$;

revoke all on function public.participant_state(text) from public, anon, authenticated;
grant execute on function public.participant_state(text) to anon, authenticated;
