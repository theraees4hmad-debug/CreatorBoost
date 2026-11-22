-- Trusted reviewers are managed only in Supabase SQL Editor by the project owner.
create table if not exists public.cb_task_reviewers (
 user_id uuid primary key references auth.users(id) on delete cascade,
 added_at timestamptz not null default now()
);
alter table public.cb_task_reviewers enable row level security;
revoke all on public.cb_task_reviewers from anon,authenticated;

create or replace function public.admin_creatorboost_pending_submissions()
returns table(id uuid,user_id uuid,task_id text,title text,evidence text,submitted_at timestamptz)
language plpgsql stable security definer set search_path=public,auth as $$
begin
 if auth.uid() is null or not exists(select 1 from public.cb_task_reviewers r where r.user_id=auth.uid()) then
   raise exception 'Admin permission required';
 end if;
 return query select s.id,s.user_id,s.task_id,c.title,s.evidence,s.submitted_at
 from public.cb_task_submissions s join public.cb_task_catalog c on c.task_id=s.task_id
 where s.status='pending' order by s.submitted_at asc;
end $$;

create or replace function public.review_creatorboost_task(p_submission_id uuid,p_approve boolean)
returns integer language plpgsql security definer set search_path=public,auth as $$
declare v_s public.cb_task_submissions%rowtype; v_points integer;
begin
 if auth.uid() is null or not exists(select 1 from public.cb_task_reviewers r where r.user_id=auth.uid()) then
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
revoke all on function public.admin_creatorboost_pending_submissions() from public,anon;
revoke all on function public.review_creatorboost_task(uuid,boolean) from public,anon;
grant execute on function public.admin_creatorboost_pending_submissions() to authenticated;
grant execute on function public.review_creatorboost_task(uuid,boolean) to authenticated;

-- After the first two migrations, run this separately after replacing the email:
-- insert into public.cb_task_reviewers(user_id)
-- select id from auth.users where email='YOUR-LOGIN-EMAIL';
