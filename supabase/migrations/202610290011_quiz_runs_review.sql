alter table public.questions
  add column explanation text not null default '';

create table public.quiz_runs (
  id uuid primary key default gen_random_uuid(),
  quiz_id uuid not null references public.quizzes(id) on delete cascade,
  run_number integer not null check (run_number > 0),
  leaderboard_group_id uuid not null default gen_random_uuid(),
  status public.quiz_status not null default 'draft',
  review_enabled boolean not null default false,
  started_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  unique (quiz_id, run_number)
);

alter table public.quizzes add column active_run_id uuid;
alter table public.participants add column run_id uuid;

insert into public.quiz_runs
  (quiz_id, run_number, status, started_at, completed_at)
select
  id,
  1,
  status,
  started_at,
  case when status = 'completed' then updated_at else null end
from public.quizzes;

update public.quizzes quiz
set active_run_id = run.id
from public.quiz_runs run
where run.quiz_id = quiz.id and run.run_number = 1;

update public.participants participant
set run_id = quiz.active_run_id
from public.quizzes quiz
where quiz.id = participant.quiz_id;

update public.participants participant
set status = 'completed'
from public.quizzes quiz
where quiz.id = participant.quiz_id
  and quiz.status = 'completed'
  and participant.status in ('active', 'disconnected');

alter table public.quizzes
  add constraint quizzes_active_run_fk
  foreign key (active_run_id) references public.quiz_runs(id);
alter table public.participants
  alter column run_id set not null,
  add constraint participants_run_fk foreign key (run_id) references public.quiz_runs(id);

create or replace function public.create_initial_quiz_run()
returns trigger language plpgsql security definer set search_path = '' as $$
declare new_run_id uuid;
begin
  insert into public.quiz_runs(quiz_id,run_number,status,started_at,completed_at)
  values(
    new.id,
    1,
    new.status,
    new.started_at,
    case when new.status='completed' then new.updated_at else null end
  )
  returning id into new_run_id;
  update public.quizzes set active_run_id=new_run_id where id=new.id;
  return new;
end $$;

create trigger quizzes_create_initial_run
  after insert on public.quizzes
  for each row execute function public.create_initial_quiz_run();
revoke all on function public.create_initial_quiz_run() from public, anon, authenticated;

create index quiz_runs_leaderboard_group_idx
  on public.quiz_runs (quiz_id, leaderboard_group_id);
create index participants_run_status_idx
  on public.participants (run_id, status);

alter table public.quiz_runs enable row level security;
create policy "Admins view own quiz runs" on public.quiz_runs
  for select to authenticated
  using (exists (
    select 1 from public.quizzes quiz
    where quiz.id = public.quiz_runs.quiz_id and quiz.owner_id = (select auth.uid()) and public.is_admin()
  ));

create or replace function public.attach_participant_to_active_run()
returns trigger language plpgsql security definer set search_path = '' as $$
declare active_run uuid;
begin
  if new.run_id is null then
    select quiz.active_run_id into active_run
    from public.quizzes quiz
    where quiz.id = new.quiz_id and quiz.status in ('waiting_room','live','paused');
    if active_run is null then raise exception 'This quiz is not accepting participants.'; end if;
    new.run_id := active_run;
  end if;
  return new;
end $$;

create trigger participants_attach_active_run
  before insert on public.participants
  for each row execute function public.attach_participant_to_active_run();
revoke all on function public.attach_participant_to_active_run() from public, anon, authenticated;

create or replace function public.prevent_active_quiz_content_changes()
returns trigger language plpgsql security definer set search_path = '' as $$
declare target_quiz uuid; source_quiz uuid;
begin
  if tg_table_name = 'quizzes' then
    target_quiz := new.id;
    source_quiz := old.id;
  elsif tg_op = 'DELETE' then
    target_quiz := old.quiz_id;
    source_quiz := old.quiz_id;
  else
    target_quiz := new.quiz_id;
    if tg_op = 'UPDATE' then
      source_quiz := old.quiz_id;
    end if;
  end if;
  if exists (
    select 1 from public.quizzes quiz
    where quiz.id = any(array[target_quiz, source_quiz])
      and quiz.status in ('waiting_room','live','paused')
  ) then
    raise exception 'Finish the active quiz session before changing its questions.';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;

create trigger questions_lock_during_active_quiz
  before insert or update or delete on public.questions
  for each row execute function public.prevent_active_quiz_content_changes();

create trigger quizzes_lock_mode_during_active_session
  before update of mode on public.quizzes
  for each row
  when (old.mode is distinct from new.mode)
  execute function public.prevent_active_quiz_content_changes();

create or replace function public.participant_navigate(p_token text,p_direction text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  participant public.participants%rowtype;
  quiz public.quizzes%rowtype;
  target uuid;
  target_position integer;
  duration integer;
begin
  select * into participant from public.participants
  where session_hash=encode(extensions.digest(p_token,'sha256'),'hex') and status='active'
  for update;
  if not found then raise exception 'Participant session expired.'; end if;
  select * into quiz from public.quizzes where id=participant.quiz_id;
  if participant.run_id is distinct from quiz.active_run_id then
    raise exception 'This quiz session has ended. Rejoin the current quiz.';
  end if;
  if quiz.mode<>'self_paced' or quiz.status<>'live' then
    raise exception 'Participant navigation is available only in a live self-paced quiz.';
  end if;
  if quiz.overall_deadline is not null and now()>=quiz.overall_deadline then
    raise exception 'The overall quiz deadline has passed.';
  end if;
  if p_direction not in ('next','previous') then raise exception 'Unknown navigation direction.'; end if;
  if p_direction='previous' and not coalesce((quiz.settings->>'allow_navigation')::boolean,true) then
    raise exception 'Previous question navigation is disabled.';
  end if;
  select position into target_position from public.questions
  where id=participant.current_question_id and quiz_id=quiz.id;
  if p_direction='next' then
    select id,coalesce(time_limit_seconds,30) into target,duration
    from public.questions where quiz_id=quiz.id and position>coalesce(target_position,0)
    order by position limit 1;
  else
    select id,coalesce(time_limit_seconds,30) into target,duration
    from public.questions where quiz_id=quiz.id and position<coalesce(target_position,1)
    order by position desc limit 1;
  end if;
  if target is null and p_direction='next' then
    update public.participants set status='completed' where id=participant.id;
    return jsonb_build_object('ok',true,'completed',true);
  elsif target is null then
    raise exception 'There are no more questions in that direction.';
  end if;
  update public.participants
  set current_question_id=target,question_started_at=now(),
      question_deadline=case when exists(
        select 1 from public.questions where id=target and time_limit_seconds is not null
      ) then now()+make_interval(secs=>duration) else null end
  where id=participant.id;
  return jsonb_build_object('ok',true,'question_id',target);
end $$;

create or replace function public.participant_finish(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  participant public.participants%rowtype;
  quiz public.quizzes%rowtype;
begin
  select * into participant from public.participants
  where session_hash=encode(extensions.digest(p_token,'sha256'),'hex')
    and status in ('active','disconnected','completed')
  for update;
  if not found then raise exception 'Participant session expired.'; end if;
  select * into quiz from public.quizzes where id=participant.quiz_id;
  if participant.run_id is distinct from quiz.active_run_id then
    update public.participants set status='completed' where id=participant.id;
  elsif quiz.status<>'completed' then
    raise exception 'Submit your quiz after the controller ends the session.';
  else
    update public.participants set status='completed' where id=participant.id;
  end if;
  return jsonb_build_object('ok',true);
end $$;

revoke all on function public.prevent_active_quiz_content_changes() from public, anon, authenticated;
revoke all on function public.participant_navigate(text,text) from public, anon, authenticated;
grant execute on function public.participant_navigate(text,text) to anon, authenticated;
revoke all on function public.participant_finish(text) from public, anon, authenticated;
grant execute on function public.participant_finish(text) to anon, authenticated;

create or replace function public.join_quiz(p_code text, p_name text, p_mobile text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare q public.quizzes%rowtype; pid uuid; token text := encode(extensions.gen_random_bytes(32),'hex');
begin
 select * into q from public.quizzes where join_code=upper(trim(p_code)) and status in ('waiting_room','live','paused');
 if not found or q.active_run_id is null then raise exception 'This quiz is not accepting participants.'; end if;
 if char_length(trim(p_name)) not between 1 and 80 then raise exception 'Enter a name between 1 and 80 characters.'; end if;
 insert into public.participants(quiz_id,run_id,display_name,mobile,session_hash)
 values(q.id,q.active_run_id,trim(p_name),nullif(trim(p_mobile),''),encode(extensions.digest(token,'sha256'),'hex'))
 returning id into pid;
 return jsonb_build_object('token',token,'participant_id',pid,'quiz_id',q.id,'quiz_title',q.title,'status',q.status);
end $$;

create or replace function public.participant_state(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  participant_data jsonb;
  v_participant_id uuid;
  v_quiz_id uuid;
  v_run_id uuid;
  current_run public.quiz_runs%rowtype;
  quiz public.quizzes%rowtype;
  participant_done boolean;
  quiz_is_complete boolean;
  leaderboard_data jsonb := '[]'::jsonb;
  review_data jsonb := '[]'::jsonb;
begin
  participant_data := public.participant_state_internal(p_token);
  participant_done := coalesce((participant_data->>'participant_completed')::boolean, false);

  select participant.id, participant.quiz_id, participant.run_id
  into v_participant_id, v_quiz_id, v_run_id
  from public.participants participant
  where participant.session_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    and participant.status in ('active', 'disconnected', 'completed');
  if not found then raise exception 'Participant session expired. Rejoin the quiz.'; end if;

  select * into quiz from public.quizzes where id = v_quiz_id;
  select * into current_run from public.quiz_runs where id = v_run_id;
  quiz_is_complete := quiz.status = 'completed' or quiz.active_run_id is distinct from v_run_id;
  participant_done := participant_done or quiz.active_run_id is distinct from v_run_id;

  if quiz_is_complete and coalesce((quiz.settings->>'show_leaderboard')::boolean, false) then
    select coalesce(jsonb_agg(jsonb_build_object('id', ranked.id, 'rank', ranked.rank, 'name', ranked.display_name, 'score', ranked.score) order by ranked.rank), '[]'::jsonb)
    into leaderboard_data
    from (
      select score_rows.id,
             row_number() over (order by score_rows.total_score desc, score_rows.display_name asc) as rank,
             score_rows.display_name, score_rows.total_score as score
      from (
        select participant.id, participant.display_name,
               coalesce(sum(answer.points_awarded), 0) as total_score
        from public.participants participant
        join public.quiz_runs run on run.id = participant.run_id
        left join public.answers answer on answer.participant_id = participant.id
        where run.quiz_id = v_quiz_id
          and run.leaderboard_group_id = current_run.leaderboard_group_id
          and participant.status = 'completed'
        group by participant.id
      ) score_rows
      order by score_rows.total_score desc, score_rows.display_name asc
      limit 20
    ) ranked;
  end if;

  if current_run.review_enabled and quiz_is_complete then
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', question.id,
      'position', question.position,
      'prompt', question.prompt,
      'type', question.type,
      'options', question.options,
      'correct_answer', question.correct_answer,
      'explanation', question.explanation,
      'answer', answer.answer,
      'is_correct', answer.is_correct,
      'points_awarded', answer.points_awarded
    ) order by question.position), '[]'::jsonb)
    into review_data
    from public.questions question
    left join public.answers answer
      on answer.question_id = question.id and answer.participant_id = v_participant_id
    where question.quiz_id = v_quiz_id;
  end if;

  if not current_run.review_enabled
     and (quiz_is_complete or quiz.mode = 'self_paced' and participant_done or quiz.answer_revealed_at is null)
     and participant_data->'question' is not null
     and participant_data->'question' <> 'null'::jsonb then
    participant_data := jsonb_set(participant_data, '{question,correct_answer}', 'null'::jsonb, true);
  end if;
  if quiz.active_run_id is distinct from v_run_id then
    participant_data := jsonb_set(participant_data, '{quiz_status}', '"completed"'::jsonb, true);
    participant_data := jsonb_set(participant_data, '{question}', 'null'::jsonb, true);
    participant_data := jsonb_set(participant_data, '{participant_completed}', 'true'::jsonb, true);
  end if;

  participant_data := jsonb_set(participant_data, '{leaderboard}', leaderboard_data, true);
  participant_data := jsonb_set(participant_data, '{review_enabled}', to_jsonb(current_run.review_enabled), true);
  participant_data := jsonb_set(participant_data, '{review_questions}', review_data, true);
  if quiz_is_complete and not current_run.review_enabled then
    participant_data := jsonb_set(participant_data, '{saved_points}', 'null'::jsonb, true);
  end if;

  if participant_done then
    participant_data := jsonb_set(participant_data, '{participant_score}', to_jsonb((
      select coalesce(sum(answer.points_awarded), 0)
      from public.answers answer
        where answer.participant_id = v_participant_id
      )), true);
  else
    participant_data := jsonb_set(participant_data, '{participant_score}', 'null'::jsonb, true);
  end if;

  return participant_data;
end $$;

create or replace function public.submit_answer(p_token text, p_question uuid, p_answer jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  answer_result jsonb;
  participant_run uuid;
  active_run uuid;
begin
  select participant.run_id, quiz.active_run_id
    into participant_run, active_run
  from public.participants participant
  join public.quizzes quiz on quiz.id = participant.quiz_id
  where participant.session_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    and participant.status = 'active';
  if not found or participant_run is distinct from active_run then
    raise exception 'This quiz session has ended. Rejoin the current quiz.';
  end if;
  answer_result := public.submit_answer_internal(p_token, p_question, p_answer);
  return jsonb_build_object('accepted', coalesce((answer_result->>'accepted')::boolean, true));
end $$;

create or replace function public.participant_revoke(p_token text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare changed integer;
begin
  update public.participants
  set status = case when status = 'completed' then 'completed' else 'logged_out' end,
      session_hash = encode(extensions.digest(extensions.gen_random_bytes(32), 'sha256'), 'hex')
  where session_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    and status in ('active', 'disconnected', 'completed');
  get diagnostics changed = row_count;
  return changed = 1;
end $$;

create or replace function public.projector_state(p_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  quiz public.quizzes%rowtype;
  active_run public.quiz_runs%rowtype;
  question_data jsonb;
  leaderboard_data jsonb := '[]'::jsonb;
  participant_total integer;
begin
 select * into quiz from public.quizzes
 where join_code=upper(trim(p_code)) and status in ('waiting_room','live','paused','completed');
 if not found then raise exception 'Quiz projector is unavailable.'; end if;
 select * into active_run from public.quiz_runs where id=quiz.active_run_id;
 select count(*) into participant_total
 from public.participants participant
 where participant.run_id=active_run.id and participant.status<>'logged_out';
 if quiz.status in ('live','completed') and quiz.current_question_id is not null then
   select jsonb_build_object(
     'position',position,'prompt',prompt,
     'answer_revealed',quiz.answer_revealed_at is not null,
     'correct_answer',case when quiz.answer_revealed_at is not null then correct_answer else null end
   ) into question_data from public.questions where id=quiz.current_question_id;
 end if;
 if coalesce((quiz.settings->>'show_leaderboard')::boolean,false) then
   select coalesce(jsonb_agg(jsonb_build_object('id',id,'rank',rank,'name',display_name,'score',score) order by rank),'[]'::jsonb)
   into leaderboard_data
   from (
     select totals.id,row_number() over(order by totals.total_score desc,totals.display_name asc) as rank,
            totals.display_name,totals.total_score as score
     from (
       select participant.id,participant.display_name,
              coalesce(sum(answer.points_awarded),0) as total_score
       from public.participants participant
       join public.quiz_runs run on run.id=participant.run_id
       left join public.answers answer on answer.participant_id=participant.id
       where run.quiz_id=quiz.id
         and run.leaderboard_group_id=active_run.leaderboard_group_id
         and participant.status='completed'
       group by participant.id
     ) totals
     order by totals.total_score desc,totals.display_name asc limit 50
   ) ranked;
 end if;
 return jsonb_build_object(
   'title',quiz.title,'status',quiz.status,'mode',quiz.mode,'question',question_data,
   'leaderboard',leaderboard_data,'participant_count',participant_total,
   'leaderboard_visible',coalesce((quiz.settings->>'show_leaderboard')::boolean,false)
 );
end $$;

drop function public.admin_quiz_control(uuid,text,uuid);
create function public.admin_quiz_control(
  p_quiz uuid,
  p_action text,
  p_question uuid default null,
  p_merge_leaderboard boolean default false
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  quiz public.quizzes%rowtype;
  active_run public.quiz_runs%rowtype;
  latest_run public.quiz_runs%rowtype;
  deadline timestamptz;
  new_run_id uuid;
  new_group_id uuid;
begin
 if not public.is_admin() then raise exception 'Administrator access required.'; end if;
 select * into quiz from public.quizzes where id=p_quiz and owner_id=(select auth.uid()) for update;
 if not found then raise exception 'Quiz not found.'; end if;
 select * into active_run from public.quiz_runs where id=quiz.active_run_id for update;

 case p_action
 when 'open_room' then
   if quiz.status='completed' then
     if not exists(select 1 from public.questions where quiz_id=p_quiz) then raise exception 'Add at least one question before opening the quiz.'; end if;
     select * into latest_run from public.quiz_runs where quiz_id=p_quiz order by run_number desc limit 1;
     new_group_id := case when p_merge_leaderboard then latest_run.leaderboard_group_id else gen_random_uuid() end;
     insert into public.quiz_runs(quiz_id,run_number,leaderboard_group_id,status)
       values(p_quiz,latest_run.run_number+1,new_group_id,'waiting_room')
       returning id into new_run_id;
     update public.quizzes
       set active_run_id=new_run_id,status='waiting_room',started_at=null,overall_deadline=null,
           paused_at=null,paused_total_remaining_seconds=null,current_question_id=null,
           current_question_started_at=null,question_deadline=null,paused_remaining_seconds=null,
           answer_revealed_at=null
       where id=p_quiz;
   elsif quiz.status in ('draft','scheduled') then
     if not exists(select 1 from public.questions where quiz_id=p_quiz) then raise exception 'Add at least one question before opening the quiz.'; end if;
     if active_run.id is null then raise exception 'Quiz session is missing. Refresh and try again.'; end if;
     update public.quiz_runs set status='waiting_room' where id=active_run.id;
     update public.quizzes set status='waiting_room' where id=p_quiz;
   else raise exception 'Open the waiting room from a draft, scheduled, or completed quiz.'; end if;
 when 'start' then
   if quiz.status='paused' then
     update public.quizzes
       set status='live',
           question_deadline=case when current_question_id is not null and paused_remaining_seconds is not null then now()+make_interval(secs=>paused_remaining_seconds) else question_deadline end,
           overall_deadline=case when paused_total_remaining_seconds is not null then now()+make_interval(secs=>paused_total_remaining_seconds) else overall_deadline end,
           paused_remaining_seconds=null,paused_total_remaining_seconds=null,paused_at=null
       where id=p_quiz;
     update public.quiz_runs set status='live' where id=active_run.id;
     if quiz.mode='self_paced' and quiz.paused_at is not null then
       update public.participants
       set question_deadline=question_deadline+(now()-quiz.paused_at),
           question_started_at=question_started_at+(now()-quiz.paused_at)
       where run_id=active_run.id and question_deadline is not null;
     end if;
   elsif quiz.status='waiting_room' then
     update public.quizzes set status='live',started_at=now(),
       overall_deadline=now()+make_interval(secs=>coalesce((settings->>'total_time_seconds')::integer,900))
       where id=p_quiz;
     update public.quiz_runs set status='live',started_at=now() where id=active_run.id;
   else raise exception 'Start the quiz from its waiting room, or resume it from paused.'; end if;
 when 'pause' then
   if quiz.status<>'live' then raise exception 'Only a live quiz can be paused.'; end if;
   update public.quizzes set status='paused',paused_at=now(),
     paused_remaining_seconds=case when question_deadline is not null then greatest(0,ceil(extract(epoch from question_deadline-now()))::integer) else null end,
     paused_total_remaining_seconds=case when overall_deadline is not null then greatest(0,ceil(extract(epoch from overall_deadline-now()))::integer) else null end
     where id=p_quiz;
   update public.quiz_runs set status='paused' where id=active_run.id;
 when 'end' then
   if quiz.status not in ('live','paused','waiting_room') then raise exception 'Only an open quiz can be ended.'; end if;
   if quiz.mode='self_paced' and quiz.status='live' and exists(
     select 1 from public.participants
     where run_id=active_run.id and status not in ('completed','logged_out')
   ) then raise exception 'Wait until every participant has submitted before ending this quiz.'; end if;
   update public.quizzes set status='completed',question_deadline=now(),paused_remaining_seconds=null where id=p_quiz;
   update public.quiz_runs set status='completed',completed_at=now() where id=active_run.id;
 when 'reveal' then
   if quiz.mode<>'live_controlled' then raise exception 'Question reveal controls are only available for live controlled quizzes.'; end if;
   if quiz.status<>'live' then raise exception 'Start the quiz before revealing a question.'; end if;
   if not exists(select 1 from public.questions where id=p_question and quiz_id=p_quiz) then raise exception 'Question does not belong to this quiz.'; end if;
   select now()+make_interval(secs=>coalesce(time_limit_seconds,30)) into deadline from public.questions where id=p_question;
   update public.quizzes set current_question_id=p_question,current_question_started_at=now(),question_deadline=deadline,answer_revealed_at=null,paused_remaining_seconds=null where id=p_quiz;
 when 'next_question' then
   if quiz.mode<>'live_controlled' or quiz.status<>'live' then raise exception 'Question progression is only available in a live controlled quiz.'; end if;
   select id into p_question from public.questions where quiz_id=p_quiz and position>(select coalesce(position,0) from public.questions where id=quiz.current_question_id) order by position limit 1;
   if p_question is null then
     update public.quizzes set status='completed',question_deadline=null where id=p_quiz;
     update public.quiz_runs set status='completed',completed_at=now() where id=active_run.id;
   else
     select now()+make_interval(secs=>coalesce(time_limit_seconds,30)) into deadline from public.questions where id=p_question;
     update public.quizzes set current_question_id=p_question,current_question_started_at=now(),question_deadline=deadline,answer_revealed_at=null,paused_remaining_seconds=null where id=p_quiz;
   end if;
 when 'previous_question' then
   if quiz.mode<>'live_controlled' or quiz.status<>'live' then raise exception 'Question progression is only available in a live controlled quiz.'; end if;
   select id into p_question from public.questions where quiz_id=p_quiz and position<(select coalesce(position,1) from public.questions where id=quiz.current_question_id) order by position desc limit 1;
   if p_question is null then raise exception 'There is no previous question.'; end if;
   select now()+make_interval(secs=>coalesce(time_limit_seconds,30)) into deadline from public.questions where id=p_question;
   update public.quizzes set current_question_id=p_question,current_question_started_at=now(),question_deadline=deadline,answer_revealed_at=null,paused_remaining_seconds=null where id=p_quiz;
 when 'reveal_answer' then
   if quiz.mode<>'live_controlled' or quiz.status<>'live' then raise exception 'Answer reveal is only available in a live controlled quiz.'; end if;
   if quiz.current_question_id is null then raise exception 'No question is currently active.'; end if;
   update public.quizzes set answer_revealed_at=now(),question_deadline=now() where id=p_quiz;
 when 'show_leaderboard' then
   update public.quizzes set settings=jsonb_set(settings,'{show_leaderboard}','true'::jsonb,true) where id=p_quiz;
 when 'hide_leaderboard' then
   update public.quizzes set settings=jsonb_set(settings,'{show_leaderboard}','false'::jsonb,true) where id=p_quiz;
 when 'enable_review' then
   if quiz.status<>'completed' or exists(
     select 1 from public.participants
     where run_id=active_run.id and status not in ('completed','logged_out')
   ) then raise exception 'Complete the quiz and wait for every participant to submit before enabling review.'; end if;
   update public.quiz_runs set review_enabled=true where id=active_run.id;
 when 'disable_review' then
   update public.quiz_runs set review_enabled=false where id=active_run.id;
 when 'close_question' then
   if quiz.mode<>'live_controlled' or quiz.status<>'live' or quiz.current_question_id is null then raise exception 'There is no live controlled question to close.'; end if;
   update public.quizzes set question_deadline=now() where id=p_quiz;
 else raise exception 'Unsupported quiz action.';
 end case;

 insert into public.quiz_events(quiz_id,event_type,payload)
 values(p_quiz,p_action,jsonb_build_object('question_id',p_question,'run_id',coalesce(new_run_id,active_run.id)));
 return jsonb_build_object('ok',true,'action',p_action,'run_id',coalesce(new_run_id,active_run.id));
end $$;

revoke all on function public.admin_quiz_control(uuid,text,uuid,boolean) from public, anon, authenticated;
grant execute on function public.admin_quiz_control(uuid,text,uuid,boolean) to authenticated;
