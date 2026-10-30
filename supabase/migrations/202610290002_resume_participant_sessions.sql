-- Keep a disconnected participant attempt recoverable with its high-entropy
-- browser token. Explicitly forgetting the device revokes the token.
create or replace function public.participant_logout(p_token text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare changed integer;
begin
 update public.participants
 set status=case when status='completed' then 'completed' else 'disconnected' end,
     last_seen_at=now()
 where session_hash=encode(extensions.digest(p_token,'sha256'),'hex')
   and status in ('active','disconnected','completed');
 get diagnostics changed = row_count;
 return changed = 1;
end $$;

create or replace function public.participant_revoke(p_token text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare changed integer;
begin
 update public.participants set status='logged_out'
 where session_hash=encode(extensions.digest(p_token,'sha256'),'hex')
   and status in ('active','disconnected','completed');
 get diagnostics changed = row_count;
 return changed = 1;
end $$;

revoke all on function public.participant_logout(text) from public, anon, authenticated;
grant execute on function public.participant_logout(text) to anon, authenticated;
revoke all on function public.participant_revoke(text) from public, anon, authenticated;
grant execute on function public.participant_revoke(text) to anon, authenticated;
