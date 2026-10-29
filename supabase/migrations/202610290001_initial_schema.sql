-- LiveQuiz Pro initial schema. Apply with `supabase db push` or the Supabase SQL editor.
create extension if not exists pgcrypto with schema extensions;

create type public.app_role as enum ('admin');
create type public.quiz_mode as enum ('live_controlled','self_paced');
create type public.quiz_status as enum ('draft','scheduled','waiting_room','live','paused','completed','archived');
create type public.question_type as enum ('single_select','multiple_select','true_false');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  role public.app_role not null default 'admin',
  created_at timestamptz not null default now()
);
create table public.quizzes (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete restrict default auth.uid(),
  title text not null check (char_length(title) between 1 and 120),
  description text not null default '',
  instructions text not null default '',
  mode public.quiz_mode not null default 'live_controlled',
  status public.quiz_status not null default 'draft',
  join_code text not null unique check (join_code ~ '^[A-Z0-9]{6}$'),
  settings jsonb not null default '{"progression":"manual","total_time_seconds":900,"question_time_seconds":30,"allow_navigation":true,"allow_answer_changes":false,"show_leaderboard":true,"scoring":{"speed_points_enabled":false,"partial_marking":false,"negative_marking_percent":0}}'::jsonb,
  started_at timestamptz,
  overall_deadline timestamptz,
  paused_at timestamptz,
  paused_total_remaining_seconds integer,
  current_question_id uuid,
  current_question_started_at timestamptz,
  question_deadline timestamptz,
  paused_remaining_seconds integer,
  answer_revealed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table public.questions (
  id uuid primary key default gen_random_uuid(),
  quiz_id uuid not null references public.quizzes(id) on delete cascade,
  position integer not null check (position > 0),
  prompt text not null check (char_length(prompt) between 1 and 2000),
  type public.question_type not null default 'single_select',
  options jsonb not null default '[]'::jsonb,
  correct_answer jsonb not null,
  points numeric(8,2) not null default 1 check (points >= 0),
  time_limit_seconds integer check (time_limit_seconds is null or time_limit_seconds between 1 and 3600),
  created_at timestamptz not null default now(),
  unique(quiz_id, position)
);
alter table public.quizzes add constraint quizzes_current_question_fk foreign key(current_question_id) references public.questions(id) on delete set null;
create table public.participants (
  id uuid primary key default gen_random_uuid(),
  quiz_id uuid not null references public.quizzes(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 80),
  mobile text,
  session_hash text not null,
  current_question_id uuid references public.questions(id) on delete set null,
  question_started_at timestamptz,
  question_deadline timestamptz,
  joined_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  status text not null default 'active' check (status in ('active','disconnected','completed','logged_out')),
  unique(quiz_id, session_hash)
);
create index participants_quiz_status_idx on public.participants(quiz_id,status);
create table public.answers (
  id uuid primary key default gen_random_uuid(),
  quiz_id uuid not null references public.quizzes(id) on delete cascade,
  question_id uuid not null references public.questions(id) on delete cascade,
  participant_id uuid not null references public.participants(id) on delete cascade,
  answer jsonb not null,
  is_correct boolean not null default false,
  marks_awarded numeric(10,2) not null default 0,
  speed_points numeric(4,2) not null default 1 check (speed_points between 1 and 10),
  points_awarded numeric(10,2) not null default 0,
  submitted_at timestamptz not null default now(),
  unique(question_id,participant_id)
);
create index answers_quiz_participant_idx on public.answers(quiz_id,participant_id);
create table public.quiz_events (
  id bigint generated always as identity primary key,
  quiz_id uuid not null references public.quizzes(id) on delete cascade,
  event_type text not null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create or replace function public.touch_updated_at() returns trigger language plpgsql set search_path = '' as $$
begin new.updated_at = now(); return new; end $$;
create trigger quizzes_touch_updated before update on public.quizzes for each row execute function public.touch_updated_at();

create or replace function public.is_admin() returns boolean language sql stable security definer set search_path = '' as $$
 select exists(select 1 from public.profiles p where p.id = (select auth.uid()) and p.role = 'admin'::public.app_role)
$$;

alter table public.profiles enable row level security;
alter table public.quizzes enable row level security;
alter table public.questions enable row level security;
alter table public.participants enable row level security;
alter table public.answers enable row level security;
alter table public.quiz_events enable row level security;

create policy "Admins read own profile" on public.profiles for select to authenticated using (id = (select auth.uid()) and public.is_admin());
create policy "Admins read own quizzes" on public.quizzes for select to authenticated using (owner_id = (select auth.uid()) and public.is_admin());
create policy "Admins create own quizzes" on public.quizzes for insert to authenticated with check (owner_id = (select auth.uid()) and public.is_admin());
create policy "Admins update own quizzes" on public.quizzes for update to authenticated using (owner_id = (select auth.uid()) and public.is_admin()) with check (owner_id = (select auth.uid()) and public.is_admin());
create policy "Admins delete own quizzes" on public.quizzes for delete to authenticated using (owner_id = (select auth.uid()) and public.is_admin());
create policy "Admins manage quiz questions" on public.questions for all to authenticated using (exists(select 1 from public.quizzes q where q.id=quiz_id and q.owner_id=(select auth.uid()) and public.is_admin())) with check (exists(select 1 from public.quizzes q where q.id=quiz_id and q.owner_id=(select auth.uid()) and public.is_admin()));
create policy "Admins view quiz participants" on public.participants for select to authenticated using (exists(select 1 from public.quizzes q where q.id=quiz_id and q.owner_id=(select auth.uid()) and public.is_admin()));
create policy "Admins view quiz answers" on public.answers for select to authenticated using (exists(select 1 from public.quizzes q where q.id=quiz_id and q.owner_id=(select auth.uid()) and public.is_admin()));
create policy "Admins view quiz events" on public.quiz_events for select to authenticated using (exists(select 1 from public.quizzes q where q.id=quiz_id and q.owner_id=(select auth.uid()) and public.is_admin()));

-- Participant access is mediated by narrowly scoped security-definer RPCs; table access stays private.
create or replace function public.join_quiz(p_code text, p_name text, p_mobile text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare q public.quizzes%rowtype; pid uuid; token text := encode(extensions.gen_random_bytes(32),'hex');
begin
 select * into q from public.quizzes where join_code=upper(trim(p_code)) and status in ('waiting_room','live','paused');
 if not found then raise exception 'This quiz is not accepting participants.'; end if;
 if char_length(trim(p_name)) not between 1 and 80 then raise exception 'Enter a name between 1 and 80 characters.'; end if;
 insert into public.participants(quiz_id,display_name,mobile,session_hash) values(q.id,trim(p_name),nullif(trim(p_mobile),''),encode(extensions.digest(token,'sha256'),'hex')) returning id into pid;
 return jsonb_build_object('token',token,'participant_id',pid,'quiz_id',q.id,'quiz_title',q.title,'status',q.status);
end $$;

create or replace function public.participant_state(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p public.participants%rowtype; q public.quizzes%rowtype; question_data jsonb; answer_data jsonb; leaderboard_data jsonb; participant_score numeric; current_q uuid; question_duration integer; participant_done boolean := false; total_questions integer; has_next_question boolean := false; has_previous_question boolean := false;
begin
 select * into p from public.participants where session_hash=encode(extensions.digest(p_token,'sha256'),'hex') and status in ('active','disconnected','completed');
 if not found then raise exception 'Participant session expired. Rejoin the quiz.'; end if;
 update public.participants set last_seen_at=now(),status=case when status='completed' then status else 'active' end where id=p.id;
 select * into q from public.quizzes where id=p.quiz_id;
 select count(*) into total_questions from public.questions where quiz_id=q.id;
 participant_done := p.status='completed';
 if q.mode='self_paced' and q.status='live' then
   if q.overall_deadline is not null and now()>=q.overall_deadline then
     participant_done := true;
     update public.participants set status='completed' where id=p.id;
   elsif p.current_question_id is null then
     select id,coalesce(time_limit_seconds,(q.settings->>'question_time_seconds')::integer,30) into current_q,question_duration from public.questions where quiz_id=q.id order by position limit 1;
     if current_q is not null then
       update public.participants set current_question_id=current_q,question_started_at=now(),question_deadline=least(now()+make_interval(secs=>question_duration),q.overall_deadline) where id=p.id;
       p.current_question_id := current_q;
       p.question_deadline := least(now()+make_interval(secs=>question_duration),q.overall_deadline);
     end if;
   end if;
 end if;
 current_q := case when q.mode='self_paced' then p.current_question_id else q.current_question_id end;
 if q.status='live' and current_q is not null and not participant_done then
   select exists(select 1 from public.questions current_question join public.questions other_question on other_question.quiz_id=current_question.quiz_id and other_question.position>current_question.position where current_question.id=current_q) into has_next_question;
   select exists(select 1 from public.questions current_question join public.questions other_question on other_question.quiz_id=current_question.quiz_id and other_question.position<current_question.position where current_question.id=current_q) into has_previous_question;
   select jsonb_build_object('id',id,'position',position,'prompt',prompt,'type',type,'options',options,'points',points,'deadline',case when q.mode='self_paced' then p.question_deadline else q.question_deadline end,'answer_revealed',q.answer_revealed_at is not null or q.status='completed' or participant_done,'correct_answer',case when q.answer_revealed_at is not null or q.status='completed' or participant_done then correct_answer else null end) into question_data from public.questions where id=current_q;
   select jsonb_build_object('answer',answer,'points_awarded',points_awarded) into answer_data from public.answers where question_id=current_q and participant_id=p.id;
 end if;
 if coalesce((q.settings->>'show_leaderboard')::boolean,false) then
   select coalesce(jsonb_agg(jsonb_build_object('rank',rank,'name',display_name,'score',score) order by rank),'[]'::jsonb) into leaderboard_data from (
     select row_number() over(order by total_score desc, display_name asc) as rank, display_name, total_score as score from (
       select pp.display_name, coalesce(sum(a.points_awarded),0) as total_score from public.participants pp left join public.answers a on a.participant_id=pp.id where pp.quiz_id=q.id and pp.status<>'logged_out' group by pp.id
     ) scores order by total_score desc, display_name asc limit 20
   ) ranked;
 end if;
 select coalesce(sum(points_awarded),0) into participant_score from public.answers where participant_id=p.id;
 return jsonb_build_object('quiz_title',q.title,'quiz_status',q.status,'mode',q.mode,'question',question_data,'question_count',total_questions,'has_next_question',has_next_question,'has_previous_question',has_previous_question,'saved_answer',answer_data->'answer','answer_submitted',answer_data is not null,'saved_points',answer_data->'points_awarded','participant_name',p.display_name,'participant_score',participant_score,'participant_completed',participant_done,'overall_deadline',q.overall_deadline,'allow_navigation',coalesce((q.settings->>'allow_navigation')::boolean,true),'allow_answer_changes',coalesce((q.settings->>'allow_answer_changes')::boolean,false),'show_leaderboard',coalesce((q.settings->>'show_leaderboard')::boolean,false),'leaderboard',leaderboard_data);
end $$;

create or replace function public.participant_navigate(p_token text,p_direction text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p public.participants%rowtype; q public.quizzes%rowtype; target uuid; target_position integer; duration integer;
begin
 select * into p from public.participants where session_hash=encode(extensions.digest(p_token,'sha256'),'hex') and status='active' for update;
 if not found then raise exception 'Participant session expired.'; end if;
 select * into q from public.quizzes where id=p.quiz_id;
 if q.mode<>'self_paced' or q.status<>'live' then raise exception 'Participant navigation is available only in a live self-paced quiz.'; end if;
 if q.overall_deadline is not null and now()>=q.overall_deadline then raise exception 'The overall quiz deadline has passed.'; end if;
 if p_direction not in ('next','previous') then raise exception 'Unknown navigation direction.'; end if;
 if p_direction='previous' and not coalesce((q.settings->>'allow_navigation')::boolean,true) then raise exception 'Previous question navigation is disabled.'; end if;
 select position into target_position from public.questions where id=p.current_question_id and quiz_id=q.id;
 if p_direction='next' then
   select id,coalesce(time_limit_seconds,(q.settings->>'question_time_seconds')::integer,30) into target,duration from public.questions where quiz_id=q.id and position>coalesce(target_position,0) order by position limit 1;
 else
   select id,coalesce(time_limit_seconds,(q.settings->>'question_time_seconds')::integer,30) into target,duration from public.questions where quiz_id=q.id and position<coalesce(target_position,1) order by position desc limit 1;
 end if;
 if target is null and p_direction='next' then
   update public.participants set status='completed' where id=p.id;
   return jsonb_build_object('ok',true,'completed',true);
 elsif target is null then raise exception 'There are no more questions in that direction.'; end if;
 update public.participants set current_question_id=target,question_started_at=now(),question_deadline=least(now()+make_interval(secs=>duration),q.overall_deadline) where id=p.id;
 return jsonb_build_object('ok',true,'question_id',target);
end $$;

create or replace function public.projector_state(p_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare q public.quizzes%rowtype; question_data jsonb; leaderboard_data jsonb; participant_total integer;
begin
 select * into q from public.quizzes where join_code=upper(trim(p_code)) and status in ('waiting_room','live','paused','completed');
 if not found then raise exception 'Quiz projector is unavailable.'; end if;
 select count(*) into participant_total from public.participants where quiz_id=q.id and status<>'logged_out';
 if q.status in ('live','completed') and q.current_question_id is not null then
   select jsonb_build_object('position',position,'prompt',prompt,'answer_revealed',q.answer_revealed_at is not null,'correct_answer',case when q.answer_revealed_at is not null then correct_answer else null end) into question_data from public.questions where id=q.current_question_id;
 end if;
 if coalesce((q.settings->>'show_leaderboard')::boolean,false) then
   select coalesce(jsonb_agg(jsonb_build_object('rank',rank,'name',display_name,'score',score) order by rank),'[]'::jsonb) into leaderboard_data from (
     select row_number() over(order by total_score desc, display_name asc) as rank,display_name,total_score as score from (
       select p.display_name,coalesce(sum(a.points_awarded),0) as total_score from public.participants p left join public.answers a on a.participant_id=p.id where p.quiz_id=q.id and p.status<>'logged_out' group by p.id
     ) scores order by total_score desc,display_name asc limit 50
   ) ranked;
 end if;
 return jsonb_build_object('title',q.title,'status',q.status,'mode',q.mode,'question',question_data,'leaderboard',leaderboard_data,'participant_count',participant_total,'leaderboard_visible',coalesce((q.settings->>'show_leaderboard')::boolean,false));
end $$;

create or replace function public.submit_answer(p_token text,p_question uuid,p_answer jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare p public.participants%rowtype; q public.quizzes%rowtype; item public.questions%rowtype; correct boolean; awarded numeric; marks numeric; speed_factor numeric := 1; correct_count integer; matched_count integer; wrong_count integer; wrong_option_count integer; seconds_total numeric; seconds_left numeric; speed_enabled boolean; partial_enabled boolean; negative_percent numeric; answer_deadline timestamptz; answer_started_at timestamptz;
begin
 select * into p from public.participants where session_hash=encode(extensions.digest(p_token,'sha256'),'hex') and status='active';
 if not found then raise exception 'Participant session expired.'; end if;
 select * into q from public.quizzes where id=p.quiz_id for update;
 select * into item from public.questions where id=p_question and quiz_id=p.quiz_id;
 if not found or q.status<>'live' or (q.mode='live_controlled' and q.current_question_id<>p_question) or (q.mode='self_paced' and p.current_question_id<>p_question) then raise exception 'This question is not accepting answers.'; end if;
 if q.answer_revealed_at is not null then raise exception 'This question is closed.'; end if;
 if q.mode='self_paced' then
   answer_deadline := p.question_deadline; answer_started_at := p.question_started_at;
   if q.overall_deadline is not null and now()>q.overall_deadline then raise exception 'The overall quiz deadline has passed.'; end if;
 else answer_deadline := q.question_deadline; answer_started_at := q.current_question_started_at;
 end if;
 if answer_deadline is not null and now()>answer_deadline then raise exception 'The answer deadline has passed.'; end if;
 if p_answer is null then raise exception 'An answer is required.'; end if;
 if item.type='multiple_select' then
   if jsonb_typeof(p_answer) is distinct from 'array' then raise exception 'Select one or more listed options.'; end if;
   if jsonb_array_length(p_answer)=0 or exists(select 1 from jsonb_array_elements(p_answer) as submitted(value) where not item.options @> jsonb_build_array(submitted.value)) then raise exception 'Select one or more listed options.'; end if;
   if jsonb_array_length(p_answer)<>(select count(distinct value) from jsonb_array_elements(p_answer) as submitted_values(value)) then raise exception 'Do not select an option more than once.'; end if;
   correct := jsonb_array_length(p_answer)=jsonb_array_length(item.correct_answer) and not exists(select 1 from jsonb_array_elements(p_answer) as submitted(value) where not item.correct_answer @> jsonb_build_array(submitted.value));
   select jsonb_array_length(item.correct_answer),count(*) filter (where item.correct_answer @> jsonb_build_array(submitted.value)),count(*) filter (where not item.correct_answer @> jsonb_build_array(submitted.value)) into correct_count,matched_count,wrong_count from jsonb_array_elements(p_answer) as submitted(value);
   select greatest(0,jsonb_array_length(item.options)-jsonb_array_length(item.correct_answer)) into wrong_option_count;
 else
   if jsonb_typeof(p_answer)<>'string' or not item.options @> jsonb_build_array(p_answer #>> '{}') then raise exception 'Select one listed option.'; end if;
   correct := item.correct_answer=p_answer;
 end if;
 speed_enabled := coalesce((q.settings->'scoring'->>'speed_points_enabled')::boolean,false);
 partial_enabled := coalesce((q.settings->'scoring'->>'partial_marking')::boolean,false);
 negative_percent := least(100,greatest(0,coalesce((q.settings->'scoring'->>'negative_marking_percent')::numeric,0)));
 marks := case when correct then item.points
   when item.type='multiple_select' and partial_enabled and correct_count>0 then item.points*greatest(0,(matched_count::numeric/correct_count)-case when wrong_option_count>0 then wrong_count::numeric/wrong_option_count else 0 end)
   when not correct then -item.points*negative_percent/100
   else 0 end;
 if speed_enabled and marks>0 and answer_deadline is not null and answer_started_at is not null then
   seconds_total := greatest(1,extract(epoch from answer_deadline-answer_started_at));
   seconds_left := greatest(0,extract(epoch from answer_deadline-now()));
   speed_factor := least(10,greatest(1,1+floor(9*seconds_left/seconds_total)));
 end if;
 awarded := marks*speed_factor;
 insert into public.answers(quiz_id,question_id,participant_id,answer,is_correct,marks_awarded,speed_points,points_awarded) values(p.quiz_id,p_question,p.id,p_answer,correct,marks,speed_factor,awarded)
 on conflict(question_id,participant_id) do update set answer=excluded.answer,is_correct=excluded.is_correct,marks_awarded=excluded.marks_awarded,speed_points=excluded.speed_points,points_awarded=excluded.points_awarded,submitted_at=now()
 where coalesce((q.settings->>'allow_answer_changes')::boolean,false);
 if not found then raise exception 'An answer has already been submitted.'; end if;
 return jsonb_build_object('accepted',true,'is_correct',correct,'marks_awarded',marks,'speed_points',speed_factor,'points_awarded',awarded);
end $$;

create or replace function public.participant_logout(p_token text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare changed integer;
begin
 update public.participants set status=case when status='completed' then 'completed' else 'disconnected' end,last_seen_at=now() where session_hash=encode(extensions.digest(p_token,'sha256'),'hex') and status in ('active','disconnected','completed');
 get diagnostics changed = row_count;
 return changed = 1;
end $$;

create or replace function public.participant_revoke(p_token text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare changed integer;
begin
 update public.participants set status='logged_out' where session_hash=encode(extensions.digest(p_token,'sha256'),'hex') and status in ('active','disconnected','completed');
 get diagnostics changed = row_count;
 return changed = 1;
end $$;

create or replace function public.admin_quiz_control(p_quiz uuid,p_action text,p_question uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare q public.quizzes%rowtype; deadline timestamptz;
begin
 if not public.is_admin() then raise exception 'Administrator access required.'; end if;
 select * into q from public.quizzes where id=p_quiz and owner_id=(select auth.uid()) for update;
 if not found then raise exception 'Quiz not found.'; end if;
 if q.status in ('completed','archived') then raise exception 'Completed or archived quizzes cannot be restarted.'; end if;
 case p_action
 when 'open_room' then
   if q.status not in ('draft','scheduled') then raise exception 'Open the waiting room from a draft or scheduled quiz.'; end if;
   update public.quizzes set status='waiting_room' where id=p_quiz;
 when 'start' then
   if q.status='paused' then
     update public.quizzes set status='live',question_deadline=case when current_question_id is not null and paused_remaining_seconds is not null then now()+make_interval(secs=>paused_remaining_seconds) else question_deadline end,overall_deadline=case when paused_total_remaining_seconds is not null then now()+make_interval(secs=>paused_total_remaining_seconds) else overall_deadline end,paused_remaining_seconds=null,paused_total_remaining_seconds=null,paused_at=null where id=p_quiz;
     if q.mode='self_paced' and q.paused_at is not null then update public.participants set question_deadline=question_deadline+(now()-q.paused_at),question_started_at=question_started_at+(now()-q.paused_at) where quiz_id=p_quiz and question_deadline is not null; end if;
   elsif q.status='waiting_room' then update public.quizzes set status='live',started_at=now(),overall_deadline=now()+make_interval(secs=>coalesce((settings->>'total_time_seconds')::integer,900)) where id=p_quiz;
   else raise exception 'Start the quiz from its waiting room, or resume it from paused.'; end if;
 when 'pause' then
   if q.status<>'live' then raise exception 'Only a live quiz can be paused.'; end if;
   update public.quizzes set status='paused',paused_at=now(),paused_remaining_seconds=case when question_deadline is not null then greatest(0,ceil(extract(epoch from question_deadline-now()))::integer) else null end,paused_total_remaining_seconds=case when overall_deadline is not null then greatest(0,ceil(extract(epoch from overall_deadline-now()))::integer) else null end where id=p_quiz;
 when 'end' then
   if q.status not in ('live','paused','waiting_room') then raise exception 'Only an open quiz can be ended.'; end if;
   update public.quizzes set status='completed',question_deadline=now(),paused_remaining_seconds=null where id=p_quiz;
 when 'reveal' then
   if q.status<>'live' then raise exception 'Start the quiz before revealing a question.'; end if;
   if not exists(select 1 from public.questions where id=p_question and quiz_id=p_quiz) then raise exception 'Question does not belong to this quiz.'; end if;
   select now()+make_interval(secs=>coalesce((time_limit_seconds), (q.settings->>'question_time_seconds')::integer,30)) into deadline from public.questions where id=p_question;
   update public.quizzes set status='live',current_question_id=p_question,current_question_started_at=now(),question_deadline=deadline,answer_revealed_at=null,paused_remaining_seconds=null where id=p_quiz;
 when 'next_question' then
   if q.status<>'live' then raise exception 'Question progression is only available while the quiz is live.'; end if;
   select id into p_question from public.questions where quiz_id=p_quiz and position > coalesce((select position from public.questions where id=q.current_question_id),0) order by position limit 1;
   if p_question is null then update public.quizzes set status='completed',question_deadline=null where id=p_quiz;
   else
     select now()+make_interval(secs=>coalesce(time_limit_seconds,(q.settings->>'question_time_seconds')::integer,30)) into deadline from public.questions where id=p_question;
     update public.quizzes set status='live',current_question_id=p_question,current_question_started_at=now(),question_deadline=deadline,answer_revealed_at=null,paused_remaining_seconds=null where id=p_quiz;
   end if;
 when 'previous_question' then
   if q.status<>'live' then raise exception 'Question progression is only available while the quiz is live.'; end if;
   select id into p_question from public.questions where quiz_id=p_quiz and position < coalesce((select position from public.questions where id=q.current_question_id),1) order by position desc limit 1;
   if p_question is null then raise exception 'There is no previous question.'; end if;
   select now()+make_interval(secs=>coalesce(time_limit_seconds,(q.settings->>'question_time_seconds')::integer,30)) into deadline from public.questions where id=p_question;
   update public.quizzes set status='live',current_question_id=p_question,current_question_started_at=now(),question_deadline=deadline,answer_revealed_at=null,paused_remaining_seconds=null where id=p_quiz;
 when 'reveal_answer' then
   if q.status<>'live' then raise exception 'Answer reveal is only available while the quiz is live.'; end if;
   if q.current_question_id is null then raise exception 'No question is currently active.'; end if;
   update public.quizzes set answer_revealed_at=now(),question_deadline=now() where id=p_quiz;
 when 'show_leaderboard' then update public.quizzes set settings=jsonb_set(settings,'{show_leaderboard}','true'::jsonb,true) where id=p_quiz;
 when 'hide_leaderboard' then update public.quizzes set settings=jsonb_set(settings,'{show_leaderboard}','false'::jsonb,true) where id=p_quiz;
 when 'close_question' then
   if q.status<>'live' or q.current_question_id is null then raise exception 'There is no live question to close.'; end if;
   update public.quizzes set question_deadline=now() where id=p_quiz;
 else raise exception 'Unsupported quiz action.';
 end case;
 insert into public.quiz_events(quiz_id,event_type,payload) values(p_quiz,p_action,jsonb_build_object('question_id',p_question));
 return jsonb_build_object('ok',true,'action',p_action);
end $$;

revoke all on function public.join_quiz(text,text,text) from public, anon, authenticated;
grant execute on function public.join_quiz(text,text,text) to anon, authenticated;
revoke all on function public.participant_state(text) from public, anon, authenticated;
grant execute on function public.participant_state(text) to anon, authenticated;
revoke all on function public.projector_state(text) from public, anon, authenticated;
grant execute on function public.projector_state(text) to anon, authenticated;
revoke all on function public.participant_navigate(text,text) from public, anon, authenticated;
grant execute on function public.participant_navigate(text,text) to anon, authenticated;
revoke all on function public.submit_answer(text,uuid,jsonb) from public, anon, authenticated;
grant execute on function public.submit_answer(text,uuid,jsonb) to anon, authenticated;
revoke all on function public.participant_logout(text) from public, anon, authenticated;
grant execute on function public.participant_logout(text) to anon, authenticated;
revoke all on function public.participant_revoke(text) from public, anon, authenticated;
grant execute on function public.participant_revoke(text) to anon, authenticated;
revoke all on function public.admin_quiz_control(uuid,text,uuid) from public, anon, authenticated;
grant execute on function public.admin_quiz_control(uuid,text,uuid) to authenticated;

-- Create the first administrator in Supabase Auth, then run once with that user's UUID:
-- insert into public.profiles (id, display_name, role) values ('AUTH-USER-UUID','Administrator','admin');
