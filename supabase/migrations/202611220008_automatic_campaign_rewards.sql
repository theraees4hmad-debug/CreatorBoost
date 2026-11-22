-- Campaign creator submissions and automatic, budget-capped rewards.
-- Run this migration in Supabase SQL Editor after migrations 001-007.

alter table public.cb_campaigns
  add column if not exists reward_per_creator integer not null default 10 check (reward_per_creator > 0),
  add column if not exists remaining_budget integer;
update public.cb_campaigns set remaining_budget=bid where remaining_budget is null;
alter table public.cb_campaigns alter column remaining_budget set not null;
alter table public.cb_campaigns add constraint cb_campaigns_remaining_budget_check
  check (remaining_budget >= 0 and remaining_budget <= bid);

create table if not exists public.cb_campaign_submissions (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid not null references public.cb_campaigns(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  evidence text not null check (length(trim(evidence)) between 3 and 2000),
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  reward_points integer not null check (reward_points > 0),
  paid_points integer not null default 0 check (paid_points >= 0),
  submitted_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewer_id uuid references auth.users(id),
  unique(campaign_id,user_id)
);
alter table public.cb_campaign_submissions enable row level security;
drop policy if exists "Creators read own campaign submissions" on public.cb_campaign_submissions;
create policy "Creators read own campaign submissions" on public.cb_campaign_submissions
  for select to authenticated using (auth.uid()=user_id);
revoke all on public.cb_campaign_submissions from anon,authenticated;
grant select on public.cb_campaign_submissions to authenticated;

create or replace function public.my_creatorboost_campaigns_v2()
returns table(id uuid,title text,url text,platform text,bid integer,status text,created_at timestamptz,is_mine boolean,reward_per_creator integer,remaining_budget integer)
language sql stable security definer set search_path=public,auth as $$
 select c.id,c.title,c.url,c.platform,c.bid,c.status,c.created_at,(c.user_id=auth.uid()),c.reward_per_creator,c.remaining_budget
 from public.cb_campaigns c
 where c.status='active' or (c.user_id=auth.uid() and c.status in ('paused','cancelled'))
 order by (c.user_id=auth.uid()) desc,c.created_at desc
$$;

create or replace function public.create_creatorboost_campaign_v2(
 p_title text,p_url text,p_platform text,p_budget integer,p_reward_per_creator integer
) returns uuid
language plpgsql security definer set search_path=public,auth as $$
declare v_uid uuid:=auth.uid(); v_id uuid;
begin
 if v_uid is null then raise exception 'Please sign in first'; end if;
 if length(trim(coalesce(p_title,''))) not between 2 and 70 then raise exception 'Campaign name must be 2–70 characters'; end if;
 if p_url !~* '^https?://' then raise exception 'Enter a valid public http or https URL'; end if;
 if p_platform not in ('Instagram','YouTube','TikTok','Facebook','X','Snapchat','Twitch','Kick','Threads','Pinterest','LinkedIn','Reddit') then raise exception 'Unsupported platform'; end if;
 if p_budget is null or p_budget<10 then raise exception 'Minimum campaign budget is 10 points'; end if;
 if p_reward_per_creator is null or p_reward_per_creator<1 or p_reward_per_creator>p_budget then raise exception 'Creator reward must be at least 1 and no more than the campaign budget'; end if;
 update public.cb_points_accounts set balance=balance-p_budget,updated_at=now()
 where user_id=v_uid and balance>=p_budget;
 if not found then raise exception 'Not enough points'; end if;
 insert into public.cb_campaigns(user_id,title,url,platform,bid,reward_per_creator,remaining_budget)
 values(v_uid,trim(p_title),trim(p_url),p_platform,p_budget,p_reward_per_creator,p_budget)
 returning id into v_id;
 insert into public.cb_points_ledger(user_id,submission_id,points,reason,entry_type,delta)
 values(v_uid,null,p_budget,'Campaign budget reserved: '||trim(p_title),'campaign_bid',-p_budget);
 return v_id;
end $$;

create or replace function public.update_creatorboost_campaign_v2(
 p_campaign_id uuid,p_title text,p_url text,p_platform text,p_budget integer,p_reward_per_creator integer
) returns integer
language plpgsql security definer set search_path=public,auth as $$
declare v_uid uuid:=auth.uid(); v_c public.cb_campaigns%rowtype; v_diff integer;
begin
 if v_uid is null then raise exception 'Please sign in first'; end if;
 select * into v_c from public.cb_campaigns where id=p_campaign_id and user_id=v_uid for update;
 if not found or v_c.status='cancelled' then raise exception 'Campaign not found'; end if;
 if length(trim(coalesce(p_title,''))) not between 2 and 70 or p_url !~* '^https?://' then raise exception 'Enter a valid campaign name and public URL'; end if;
 if p_platform not in ('Instagram','YouTube','TikTok','Facebook','X','Snapchat','Twitch','Kick','Threads','Pinterest','LinkedIn','Reddit') then raise exception 'Unsupported platform'; end if;
 if p_budget is null or p_budget<10 or p_reward_per_creator is null or p_reward_per_creator<1 or p_reward_per_creator>p_budget then raise exception 'Invalid budget or creator reward'; end if;
 v_diff:=p_budget-v_c.bid;
 if v_c.remaining_budget+v_diff < coalesce((select sum(s.reward_points) from public.cb_campaign_submissions s where s.campaign_id=p_campaign_id and s.status='pending'),0) then raise exception 'New budget cannot be lower than pending creator rewards'; end if;
 if v_diff>0 then
  update public.cb_points_accounts set balance=balance-v_diff,updated_at=now() where user_id=v_uid and balance>=v_diff;
  if not found then raise exception 'Not enough points for the increased budget'; end if;
 elsif v_diff<0 then
  update public.cb_points_accounts set balance=balance+abs(v_diff),updated_at=now() where user_id=v_uid;
 end if;
 update public.cb_campaigns set title=trim(p_title),url=trim(p_url),platform=p_platform,bid=p_budget,
 reward_per_creator=p_reward_per_creator,remaining_budget=remaining_budget+v_diff,updated_at=now()
 where id=p_campaign_id;
 if v_diff<>0 then
  insert into public.cb_points_ledger(user_id,submission_id,points,reason,entry_type,delta)
  values(v_uid,null,abs(v_diff),'Campaign budget adjustment: '||trim(p_title),'campaign_adjustment',-v_diff);
 end if;
 return v_diff;
end $$;

create or replace function public.set_creatorboost_campaign_status(p_campaign_id uuid,p_status text)
returns integer language plpgsql security definer set search_path=public,auth as $$
declare v_uid uuid:=auth.uid(); v_c public.cb_campaigns%rowtype; v_refund integer;
begin
 if v_uid is null then raise exception 'Please sign in first'; end if;
 if p_status not in ('active','paused','cancelled') then raise exception 'Invalid campaign status'; end if;
 select * into v_c from public.cb_campaigns where id=p_campaign_id and user_id=v_uid for update;
 if not found then raise exception 'Campaign not found'; end if;
 if v_c.status='cancelled' then raise exception 'Campaign is already cancelled'; end if;
 v_refund:=case when p_status='cancelled' then v_c.remaining_budget else 0 end;
 if p_status='cancelled' and v_refund>0 then
  insert into public.cb_points_accounts(user_id,balance) values(v_uid,v_refund)
  on conflict(user_id) do update set balance=public.cb_points_accounts.balance+v_refund,updated_at=now();
  insert into public.cb_points_ledger(user_id,submission_id,points,reason,entry_type,delta)
  values(v_uid,null,v_refund,'Unused campaign budget refund: '||v_c.title,'campaign_refund',v_refund);
 end if;
 update public.cb_campaigns set status=p_status,remaining_budget=remaining_budget-v_refund,updated_at=now() where id=p_campaign_id;
 return v_refund;
end $$;

create or replace function public.submit_creatorboost_campaign(p_campaign_id uuid,p_evidence text)
returns uuid language plpgsql security definer set search_path=public,auth as $$
declare v_uid uuid:=auth.uid(); v_campaign public.cb_campaigns%rowtype; v_id uuid;
begin
 if v_uid is null then raise exception 'Please sign in first'; end if;
 if length(trim(coalesce(p_evidence,''))) not between 3 and 2000 then raise exception 'Add evidence or a public link (3–2000 characters)'; end if;
 select * into v_campaign from public.cb_campaigns where id=p_campaign_id and status='active';
 if not found then raise exception 'Campaign is not currently accepting submissions'; end if;
 if v_campaign.user_id=v_uid then raise exception 'You cannot submit to your own campaign'; end if;
 if v_campaign.remaining_budget<v_campaign.reward_per_creator then raise exception 'This campaign has no remaining reward budget'; end if;
 insert into public.cb_campaign_submissions(campaign_id,user_id,evidence,reward_points)
 values(p_campaign_id,v_uid,trim(p_evidence),v_campaign.reward_per_creator) returning id into v_id;
 return v_id;
exception when unique_violation then raise exception 'You have already submitted to this campaign';
end $$;

create or replace function public.admin_creatorboost_pending_campaign_submissions()
returns table(id uuid,campaign_id uuid,campaign_title text,user_id uuid,evidence text,submitted_at timestamptz,reward_points integer,remaining_budget integer)
language plpgsql stable security definer set search_path=public,auth as $$
begin
 if auth.uid() is null or not exists(select 1 from public.cb_task_reviewers r where r.user_id=auth.uid()) then raise exception 'Admin permission required'; end if;
 return query
 select s.id,s.campaign_id,c.title,s.user_id,s.evidence,s.submitted_at,s.reward_points,c.remaining_budget
 from public.cb_campaign_submissions s join public.cb_campaigns c on c.id=s.campaign_id
 where s.status='pending' order by s.submitted_at asc;
end $$;

create or replace function public.review_creatorboost_campaign_submission(p_submission_id uuid,p_approve boolean)
returns integer language plpgsql security definer set search_path=public,auth as $$
declare v_s public.cb_campaign_submissions%rowtype; v_c public.cb_campaigns%rowtype; v_reward integer;
begin
 if auth.uid() is null or not exists(select 1 from public.cb_task_reviewers r where r.user_id=auth.uid()) then raise exception 'Admin permission required'; end if;
 select * into v_s from public.cb_campaign_submissions where id=p_submission_id for update;
 if not found then raise exception 'Campaign submission not found'; end if;
 if v_s.status<>'pending' then raise exception 'Submission has already been reviewed'; end if;
 if not p_approve then
  update public.cb_campaign_submissions set status='rejected',reviewed_at=now(),reviewer_id=auth.uid() where id=p_submission_id;
  return 0;
 end if;
 select * into v_c from public.cb_campaigns where id=v_s.campaign_id for update;
 if not found or v_c.status<>'active' then raise exception 'Campaign is not active; submission cannot be paid'; end if;
 v_reward:=v_s.reward_points;
 if v_c.remaining_budget<v_reward then raise exception 'Insufficient campaign budget; no points were paid'; end if;
 update public.cb_campaigns set remaining_budget=remaining_budget-v_reward,updated_at=now() where id=v_c.id;
 insert into public.cb_points_accounts(user_id,balance) values(v_s.user_id,v_reward)
 on conflict(user_id) do update set balance=public.cb_points_accounts.balance+excluded.balance,updated_at=now();
 insert into public.cb_points_ledger(user_id,submission_id,points,reason,entry_type,delta)
 values(v_s.user_id,null,v_reward,'Approved campaign reward: '||v_c.title,'campaign_reward',v_reward);
 update public.cb_campaign_submissions set status='approved',paid_points=v_reward,reviewed_at=now(),reviewer_id=auth.uid() where id=p_submission_id;
 return v_reward;
end $$;

revoke all on function public.my_creatorboost_campaigns_v2() from public,anon;
revoke all on function public.create_creatorboost_campaign_v2(text,text,text,integer,integer) from public,anon;
revoke all on function public.update_creatorboost_campaign_v2(uuid,text,text,text,integer,integer) from public,anon;
revoke all on function public.submit_creatorboost_campaign(uuid,text) from public,anon;
revoke all on function public.admin_creatorboost_pending_campaign_submissions() from public,anon;
revoke all on function public.review_creatorboost_campaign_submission(uuid,boolean) from public,anon;
revoke all on function public.set_creatorboost_campaign_status(uuid,text) from public,anon;
revoke all on function public.update_creatorboost_campaign(uuid,text,text,text,integer) from public,anon,authenticated;
grant execute on function public.my_creatorboost_campaigns_v2() to authenticated;
grant execute on function public.create_creatorboost_campaign_v2(text,text,text,integer,integer) to authenticated;
grant execute on function public.update_creatorboost_campaign_v2(uuid,text,text,text,integer,integer) to authenticated;
grant execute on function public.submit_creatorboost_campaign(uuid,text) to authenticated;
grant execute on function public.admin_creatorboost_pending_campaign_submissions() to authenticated;
grant execute on function public.review_creatorboost_campaign_submission(uuid,boolean) to authenticated;
grant execute on function public.set_creatorboost_campaign_status(uuid,text) to authenticated;
