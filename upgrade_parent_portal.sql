-- Rexx Hub: PARENT PORTAL upgrade. Run once in Supabase > SQL Editor > New query.
-- Safe on a database that already has the Teachers Dashboard. Existing teacher data is untouched.
--
-- Security design: parents get NO direct access to exams, questions, attempts or answers.
-- They can only call parent_results(), which returns rows for children whose link the admin approved.

alter table profiles drop constraint if exists profiles_role_check;
alter table profiles add constraint profiles_role_check check (role in ('admin','teacher','parent'));
alter table profiles add column if not exists email text;

-- "ADAOKA-7K3QD", "adaoka 7k3qd" and "adaoka7k3qd" all match the same student (same rule as the offline sign-in)
create or replace function norm_id(t text) returns text language sql immutable as
$$ select lower(regexp_replace(coalesce(t,''),'[\s-]','','g')) $$;
create index if not exists attempts_norm_student on attempts (norm_id(student_username));

create table if not exists parent_links(
  id bigint generated always as identity primary key,
  parent_id uuid not null references profiles(id) on delete cascade,
  student_key text not null check (length(student_key) between 1 and 40),
  student_id_typed text not null, child_name text not null default '', relation text not null default '',
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now(), decided_at timestamptz,
  unique(parent_id, student_key));
alter table parent_links enable row level security;

create or replace function is_parent() returns boolean language sql security definer stable set search_path=public as
$$ select exists(select 1 from profiles where id=auth.uid() and role='parent' and status='approved') $$;
create or replace function my_children() returns setof text language sql security definer stable set search_path=public as
$$ select student_key from parent_links where parent_id=auth.uid() and status='approved' and is_parent() $$;

drop policy if exists pl_read on parent_links; drop policy if exists pl_upd on parent_links; drop policy if exists pl_del on parent_links;
create policy pl_read on parent_links for select using (parent_id=auth.uid() or is_admin());
create policy pl_upd  on parent_links for update using (is_admin()) with check (is_admin());
create policy pl_del  on parent_links for delete using (is_admin() or (parent_id=auth.uid() and status='pending'));
-- no insert policy: a parent can only ask through request_child_link(), which is capped and always 'pending'.

-- New sign-ups: teachers stay PENDING; parents are created as role 'parent' (no access until a child link is approved).
-- Nobody can sign up as admin: the role is never taken from the sign-up form.
create or replace function handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
declare m jsonb := coalesce(new.raw_user_meta_data,'{}'::jsonb); par boolean := (m->>'account_type')='parent';
begin
  insert into profiles(id, full_name, offline_username, role, status, email)
  values(new.id, left(coalesce(m->>'full_name',''),80), case when par then '' else left(trim(coalesce(m->>'offline_username','')),60) end,
         case when par then 'parent' else 'teacher' end, case when par then 'approved' else 'pending' end, new.email);
  if par and trim(coalesce(m->>'child_id','')) <> '' and norm_id(m->>'child_id') <> '' then
    insert into parent_links(parent_id, student_key, student_id_typed, child_name, relation)
    values(new.id, left(norm_id(m->>'child_id'),40), left(trim(m->>'child_id'),40), left(coalesce(m->>'child_name',''),80), left(coalesce(m->>'relation',''),30))
    on conflict do nothing;
  end if;
  return new;
end $$;

-- A parent asks to link another child. The answer never says whether the ID exists (no guessing game).
create or replace function request_child_link(sid text, cname text, rel text) returns void language plpgsql security definer set search_path=public as $$
begin
  if not is_parent() then raise exception 'Only parent accounts can do this'; end if;
  if norm_id(sid) = '' or length(sid) > 40 then raise exception 'Enter the Student ID'; end if;
  if (select count(*) from parent_links where parent_id=auth.uid()) >= 8 then raise exception 'Too many children linked. Ask the school.'; end if;
  insert into parent_links(parent_id, student_key, student_id_typed, child_name, relation)
  values(auth.uid(), norm_id(sid), left(trim(sid),40), left(coalesce(cname,''),80), left(coalesce(rel,''),30)) on conflict do nothing;
end $$;

-- The ONLY way a parent reads results: approved children only, with class average and position (no other student is named).
create or replace function parent_results() returns table(student_key text, student_name text, class_name text, exam_id bigint,
  title text, subject text, pass_mark numeric, exam_date timestamptz, score numeric, total numeric, class_n bigint, class_avg numeric, pos_in_class bigint)
language sql security definer stable set search_path=public as $$
  select norm_id(m.student_username), m.student_name, m.class_name, m.exam_id, e.title, e.subject, e.pass_mark,
         coalesce(e.opens_at, m.submitted_at), m.score, m.total,
         (select count(*) from attempts x where x.exam_id=m.exam_id),
         (select round(avg(x.score/nullif(x.total,0)*100),1) from attempts x where x.exam_id=m.exam_id),
         1+(select count(*) from attempts x where x.exam_id=m.exam_id and x.score/nullif(x.total,0) > m.score/nullif(m.total,0))
  from attempts m join exams e on e.id=m.exam_id
  where is_parent() and norm_id(m.student_username) in (select my_children())
  order by 8 desc $$;

revoke all on function request_child_link(text,text,text) from public, anon;
revoke all on function parent_results() from public, anon;
grant execute on function request_child_link(text,text,text) to authenticated;
grant execute on function parent_results() to authenticated;

-- Parent: questions of an exam their child sat, with the child's answer and the correct answer (approved children only).
create or replace function parent_exam_review(eid bigint, skey text) returns table(pos int, qtype text, qtext text, options jsonb, marks numeric, response text, correct boolean, answer text)
language sql security definer stable set search_path=public as $$
  select q.pos, q.qtype, q.qtext, q.options, q.marks, an.response, coalesce(an.correct,false), split_part(q.answer,'|',1)
  from attempts a join questions q on q.exam_id=a.exam_id
  left join answers an on an.attempt_id=a.id and an.question_id=q.id
  where is_parent() and a.exam_id=eid and norm_id(a.student_username)=norm_id(skey) and norm_id(skey) in (select my_children())
  order by q.pos, q.id $$;
revoke all on function parent_exam_review(bigint,text) from public, anon;
grant execute on function parent_exam_review(bigint,text) to authenticated;

-- ===== SYNC ONLINE (offline app "Sync online" button) =====
-- Same import as the manual upload, but callable without a login by the offline app, protected by a secret sync key.
create or replace function do_import_exam(p jsonb) returns void language plpgsql security definer set search_path=public as $$
declare e jsonb := p->'exam'; eid bigint := (p->'exam'->>'id')::bigint;
begin
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
revoke all on function do_import_exam(jsonb) from public, anon, authenticated;

create or replace function import_exam(p jsonb) returns void language plpgsql security definer set search_path=public as $$
begin
  if not is_admin() then raise exception 'Only an approved admin can upload results'; end if;
  perform do_import_exam(p);
end $$;

create or replace function import_exam_sync(k text, inst text, p jsonb) returns void language plpgsql security definer set search_path=public as $$
declare h text := (select value from settings where key='sync_key_hash'); old text := (select value from settings where key='install_id');
begin
  if h is null or encode(sha256(convert_to(coalesce(k,''),'utf8')),'hex') <> h then
    perform pg_sleep(1);   -- slows down guessing
    raise exception 'Wrong sync key';
  end if;
  if old is not null and old <> inst then
    raise exception 'This exam database differs from earlier syncs (app reinstalled?). If that is expected, run in SQL Editor: delete from settings where key=''install_id'';';
  end if;
  perform do_import_exam(p);
  insert into settings(key,value) values('install_id',inst) on conflict (key) do update set value=excluded.value;
end $$;
revoke all on function import_exam_sync(text,text,jsonb) from public;
grant execute on function import_exam_sync(text,text,jsonb) to anon, authenticated;

-- ONE-TIME: choose a long secret (20+ random characters), put it here, run this line, then type the SAME secret
-- in the offline app: Admin > Sync online > Sync key. Change the text between the quotes first!
-- insert into settings(key,value) values('sync_key_hash', encode(sha256(convert_to('PUT-YOUR-LONG-SECRET-HERE','utf8')),'hex')) on conflict (key) do update set value=excluded.value;
