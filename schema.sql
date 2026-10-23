-- Rexx Hub Teachers Dashboard: run once in Supabase > SQL Editor > New query

create table profiles(
  id uuid primary key references auth.users on delete cascade,
  full_name text not null default '',
  offline_username text not null default '',
  role text not null default 'teacher' check (role in ('admin','teacher')),
  status text not null default 'pending' check (status in ('pending','approved','disabled')),
  created_at timestamptz not null default now());
create table settings(key text primary key, value text not null);
create table exams(
  id bigint primary key, teacher_username text not null, title text not null, subject text,
  duration_min int, target_class text, pass_mark numeric not null default 50,
  opens_at timestamptz, closes_at timestamptz, uploaded_at timestamptz not null default now());
create table questions(
  id bigint primary key, exam_id bigint not null references exams on delete cascade,
  pos int, qtype text, qtext text, options jsonb, answer text, marks numeric);
create table attempts(
  id bigint primary key, exam_id bigint not null references exams on delete cascade,
  student_username text, student_name text, class_name text,
  started_at timestamptz, submitted_at timestamptz, score numeric, total numeric, tab_switches int default 0);
create table answers(
  attempt_id bigint not null references attempts on delete cascade,
  question_id bigint not null references questions on delete cascade,
  exam_id bigint not null references exams on delete cascade,
  response text, correct boolean, primary key(attempt_id, question_id));
create index on questions(exam_id); create index on attempts(exam_id); create index on answers(exam_id);

create function is_admin() returns boolean language sql security definer stable set search_path=public as $$
  select exists(select 1 from profiles where id=auth.uid() and role='admin' and status='approved') $$;
create function my_username() returns text language sql security definer stable set search_path=public as $$
  select lower(offline_username) from profiles where id=auth.uid() and role='teacher' and status='approved' $$;

-- every new sign-up becomes a PENDING teacher; only an admin can approve
create function handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into profiles(id, full_name, offline_username)
  values(new.id, coalesce(new.raw_user_meta_data->>'full_name',''), trim(coalesce(new.raw_user_meta_data->>'offline_username','')));
  return new;
end $$;
create trigger on_signup after insert on auth.users for each row execute function handle_new_user();

alter table profiles enable row level security;  alter table settings enable row level security;
alter table exams enable row level security;     alter table questions enable row level security;
alter table attempts enable row level security;  alter table answers enable row level security;

create policy p_prof_read on profiles for select using (id=auth.uid() or is_admin());
create policy p_prof_upd  on profiles for update using (is_admin()) with check (is_admin());
create policy p_set_all   on settings for all using (is_admin()) with check (is_admin());
create policy p_exam_read on exams for select using (is_admin() or lower(teacher_username)=my_username());
create policy p_q_read    on questions for select using (exam_id in (select id from exams));
create policy p_a_read    on attempts  for select using (exam_id in (select id from exams));
create policy p_ans_read  on answers   for select using (exam_id in (select id from exams));
-- no insert/update/delete policies on exam data: the ONLY way in is import_exam(), admin only.

create function import_exam(p jsonb) returns void language plpgsql security definer set search_path=public as $$
declare e jsonb := p->'exam'; eid bigint := (p->'exam'->>'id')::bigint;
begin
  if not is_admin() then raise exception 'Only an approved admin can upload results'; end if;
  insert into exams(id,teacher_username,title,subject,duration_min,target_class,pass_mark,opens_at,closes_at,uploaded_at)
  values(eid,e->>'teacher_username',e->>'title',e->>'subject',(e->>'duration_min')::int,e->>'target_class',
         coalesce((e->>'pass_mark')::numeric,50),to_timestamp((e->>'opens_at')::bigint),to_timestamp((e->>'closes_at')::bigint),now())
  on conflict(id) do update set teacher_username=excluded.teacher_username,title=excluded.title,subject=excluded.subject,
    duration_min=excluded.duration_min,target_class=excluded.target_class,pass_mark=excluded.pass_mark,
    opens_at=excluded.opens_at,closes_at=excluded.closes_at,uploaded_at=now();

  delete from questions where exam_id=eid and id not in (select (x->>'id')::bigint from jsonb_array_elements(p->'questions') x);
  insert into questions(id,exam_id,pos,qtype,qtext,options,answer,marks)
    select id,eid,pos,qtype,qtext,options,answer,marks
    from jsonb_to_recordset(p->'questions') as x(id bigint,pos int,qtype text,qtext text,options jsonb,answer text,marks numeric)
  on conflict(id) do update set pos=excluded.pos,qtype=excluded.qtype,qtext=excluded.qtext,
    options=excluded.options,answer=excluded.answer,marks=excluded.marks;

  delete from attempts where exam_id=eid and id not in (select (x->>'id')::bigint from jsonb_array_elements(p->'attempts') x);
  insert into attempts(id,exam_id,student_username,student_name,class_name,started_at,submitted_at,score,total,tab_switches)
    select id,eid,student_username,student_name,class_name,to_timestamp(started_at),to_timestamp(submitted_at),score,total,tab_switches
    from jsonb_to_recordset(p->'attempts') as x(id bigint,student_username text,student_name text,class_name text,
      started_at bigint,submitted_at bigint,score numeric,total numeric,tab_switches int)
  on conflict(id) do update set student_username=excluded.student_username,student_name=excluded.student_name,
    class_name=excluded.class_name,started_at=excluded.started_at,submitted_at=excluded.submitted_at,
    score=excluded.score,total=excluded.total,tab_switches=excluded.tab_switches;

  delete from answers where exam_id=eid;
  insert into answers(attempt_id,question_id,exam_id,response,correct)
    select attempt_id,question_id,eid,response,correct
    from jsonb_to_recordset(p->'answers') as y(attempt_id bigint,question_id bigint,response text,correct boolean);
end $$;
