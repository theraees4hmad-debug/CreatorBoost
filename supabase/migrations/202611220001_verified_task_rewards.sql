-- CreatorBoost verified task rewards
-- Run once in Supabase SQL Editor. Never expose a service-role key in the website.

create table if not exists public.cb_task_catalog (
  task_id text primary key,
  title text not null,
  reward_points integer not null check (reward_points > 0),
  active boolean not null default true
);

insert into public.cb_task_catalog(task_id,title,reward_points) values
('ytfeedback','YouTube creator feedback',15),
('igcollab','Instagram collaboration invitation',20),
('kickfeedback','Kick creator feedback',15),
('ttfeedback','TikTok creator feedback',15),
('fbfeedback','Facebook creator feedback',15),
('xfeedback','X creator conversation',15),
('snapfeedback','Snapchat creator discovery',15),
('twitchfeedback','Twitch streamer feedback',15),
('threadsfeedback','Threads discussion',15),
('pinfeedback','Pinterest creator feedback',15),
('linkedinfeedback','LinkedIn creator support',15),
('redditfeedback','Reddit community contribution',15),
('profile','Complete public creator profile',25)
on conflict (task_id) do update set title=excluded.title,reward_points=excluded.reward_points;

create table if not exists public.cb_task_submissions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  task_id text not null references public.cb_task_catalog(task_id),
  evidence text not null check (length(trim(evidence)) between 3 and 2000),
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  submitted_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewer_id uuid references auth.users(id),
  unique(user_id,task_id)
);

create table if not exists public.cb_points_accounts (
  user_id uuid primary key references auth.users(id) on delete cascade,
  balance bigint not null default 0 check (balance >= 0),
  updated_at timestamptz not null default now()
);

create table if not exists public.cb_points_ledger (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  submission_id uuid not null unique references public.cb_task_submissions(id),
  points integer not null check (points > 0),
  reason text not null,
  created_at timestamptz not null default now()
);

alter table public.cb_task_submissions enable row level security;
alter table public.cb_points_accounts enable row level security;
alter table public.cb_points_ledger enable row level security;
alter table public.cb_task_catalog enable row level security;

drop policy if exists "Users read own task submissions" on public.cb_task_submissions;
create policy "Users read own task submissions" on public.cb_task_submissions
for select to authenticated using (auth.uid() = user_id);
drop policy if exists "Users read own points account" on public.cb_points_accounts;
create policy "Users read own points account" on public.cb_points_accounts
for select to authenticated using (auth.uid() = user_id);
drop policy if exists "Users read own points ledger" on public.cb_points_ledger;
create policy "Users read own points ledger" on public.cb_points_ledger
for select to authenticated using (auth.uid() = user_id);
drop policy if exists "Anyone can read active task catalog" on public.cb_task_catalog;
create policy "Anyone can read active task catalog" on public.cb_task_catalog
for select to authenticated using (active = true);

revoke all on public.cb_task_submissions, public.cb_points_accounts, public.cb_points_ledger from anon, authenticated;
grant select on public.cb_task_submissions, public.cb_points_accounts, public.cb_points_ledger to authenticated;
grant select on public.cb_task_catalog to authenticated;

create or replace function public.submit_creatorboost_task(p_task_id text,p_evidence text)
returns uuid language plpgsql security definer set search_path=public,auth as $$
declare v_id uuid; v_uid uuid := auth.uid();
begin
 if v_uid is null then raise exception 'Please sign in first'; end if;
 if p_evidence is null or length(trim(p_evidence)) < 3 or length(p_evidence) > 2000 then
   raise exception 'Please provide a valid evidence link or description';
 end if;
 if not exists(select 1 from public.cb_task_catalog where task_id=p_task_id and active) then
   raise exception 'This task is unavailable';
 end if;
 insert into public.cb_task_submissions(user_id,task_id,evidence)
 values(v_uid,p_task_id,trim(p_evidence)) returning id into v_id;
 return v_id;
exception when unique_violation then
 raise exception 'You have already submitted this task';
end $$;

create or replace function public.my_creatorboost_task_submissions()
returns table(task_id text,status text,submitted_at timestamptz)
language sql stable security definer set search_path=public,auth as $$
 select s.task_id,s.status,s.submitted_at
 from public.cb_task_submissions s where s.user_id=auth.uid()
$$;

-- Only a trusted admin whose JWT app_metadata.role is "admin" can review.
-- Approval credits the points exactly once in the same database transaction.
create or replace function public.review_creatorboost_task(p_submission_id uuid,p_approve boolean)
returns integer language plpgsql security definer set search_path=public,auth as $$
declare v_s public.cb_task_submissions%rowtype; v_points integer;
begin
 if auth.uid() is null or coalesce(auth.jwt()->'app_metadata'->>'role','') <> 'admin' then
   raise exception 'Admin permission required';
 end if;
 select * into v_s from public.cb_task_submissions where id=p_submission_id for update;
 if not found then raise exception 'Submission not found'; end if;
 if v_s.status <> 'pending' then raise exception 'Submission has already been reviewed'; end if;
 if not p_approve then
   update public.cb_task_submissions set status='rejected',reviewed_at=now(),reviewer_id=auth.uid() where id=p_submission_id;
   return 0;
 end if;
 select reward_points into v_points from public.cb_task_catalog where task_id=v_s.task_id and active;
 if v_points is null then raise exception 'Task reward is unavailable'; end if;
 insert into public.cb_points_accounts(user_id,balance) values(v_s.user_id,v_points)
 on conflict(user_id) do update set balance=public.cb_points_accounts.balance+excluded.balance,updated_at=now();
 insert into public.cb_points_ledger(user_id,submission_id,points,reason)
 values(v_s.user_id,v_s.id,v_points,'Verified task: '||v_s.task_id);
 update public.cb_task_submissions set status='approved',reviewed_at=now(),reviewer_id=auth.uid() where id=p_submission_id;
 return v_points;
end $$;

revoke all on function public.submit_creatorboost_task(text,text) from public,anon;
revoke all on function public.my_creatorboost_task_submissions() from public,anon;
revoke all on function public.review_creatorboost_task(uuid,boolean) from public,anon,authenticated;
grant execute on function public.submit_creatorboost_task(text,text) to authenticated;
grant execute on function public.my_creatorboost_task_submissions() to authenticated;
grant execute on function public.review_creatorboost_task(uuid,boolean) to authenticated;
