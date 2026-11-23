-- Reserve campaign reward budget when a creator submits work.
-- This prevents multiple pending submissions from overcommitting the same budget.
alter table public.cb_campaign_submissions
  add column if not exists budget_reserved boolean not null default false;

create or replace function public.submit_creatorboost_campaign(p_campaign_id uuid, p_evidence text)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'auth'
as $function$
declare
  v_uid uuid := auth.uid();
  v_campaign public.cb_campaigns%rowtype;
  v_id uuid;
begin
  if v_uid is null then raise exception 'Please sign in first'; end if;
  if length(trim(coalesce(p_evidence,''))) not between 8 and 2000 then
    raise exception 'Add meaningful evidence or a public link (8–2000 characters)';
  end if;

  select * into v_campaign
  from public.cb_campaigns
  where id=p_campaign_id and status='active'
  for update;

  if not found then raise exception 'Campaign is not currently accepting submissions'; end if;
  if v_campaign.user_id=v_uid then raise exception 'You cannot submit to your own campaign'; end if;
  if v_campaign.remaining_budget < v_campaign.reward_per_creator then
    raise exception 'This campaign has no remaining reward budget';
  end if;

  update public.cb_campaigns
  set remaining_budget=remaining_budget-v_campaign.reward_per_creator, updated_at=now()
  where id=p_campaign_id;

  insert into public.cb_campaign_submissions(campaign_id,user_id,evidence,reward_points,budget_reserved)
  values(p_campaign_id,v_uid,trim(p_evidence),v_campaign.reward_per_creator,true)
  returning id into v_id;

  return v_id;
exception
  when unique_violation then raise exception 'You have already submitted to this campaign';
end
$function$;

create or replace function public.review_creatorboost_campaign_submission(p_submission_id uuid, p_approve boolean)
returns integer
language plpgsql
security definer
set search_path to 'public', 'auth'
as $function$
declare
  v_s public.cb_campaign_submissions%rowtype;
  v_c public.cb_campaigns%rowtype;
  v_reward integer;
begin
  if auth.uid() is null or not exists(
    select 1 from public.cb_task_reviewers r where r.user_id=auth.uid()
  ) then raise exception 'Admin permission required'; end if;

  select * into v_s
  from public.cb_campaign_submissions
  where id=p_submission_id
  for update;

  if not found then raise exception 'Campaign submission not found'; end if;
  if v_s.status<>'pending' then raise exception 'Submission has already been reviewed'; end if;

  select * into v_c
  from public.cb_campaigns
  where id=v_s.campaign_id
  for update;

  if not found then raise exception 'Campaign not found'; end if;
  v_reward:=v_s.reward_points;

  if not p_approve then
    if v_s.budget_reserved then
      update public.cb_campaigns
      set remaining_budget=remaining_budget+v_reward, updated_at=now()
      where id=v_c.id;
    end if;
    update public.cb_campaign_submissions
    set status='rejected', budget_reserved=false, reviewed_at=now(), reviewer_id=auth.uid()
    where id=p_submission_id;
    return 0;
  end if;

  if v_c.status not in ('active','paused') then
    raise exception 'Campaign is not eligible for review; reserved reward remains protected';
  end if;

  if not v_s.budget_reserved then
    if v_c.remaining_budget<v_reward then
      raise exception 'Insufficient campaign budget; no points were paid';
    end if;
    update public.cb_campaigns
    set remaining_budget=remaining_budget-v_reward, updated_at=now()
    where id=v_c.id;
  end if;

  insert into public.cb_points_accounts(user_id,balance)
  values(v_s.user_id,v_reward)
  on conflict(user_id) do update
  set balance=public.cb_points_accounts.balance+excluded.balance,updated_at=now();

  insert into public.cb_points_ledger(user_id,submission_id,points,reason,entry_type,delta)
  values(v_s.user_id,null,v_reward,'Approved campaign reward: '||v_c.title,'campaign_reward',v_reward);

  update public.cb_campaign_submissions
  set status='approved',paid_points=v_reward,budget_reserved=false,reviewed_at=now(),reviewer_id=auth.uid()
  where id=p_submission_id;

  return v_reward;
end
$function$;

create or replace function public.set_creatorboost_campaign_status(p_campaign_id uuid, p_status text)
returns integer
language plpgsql
security definer
set search_path to 'public', 'auth'
as $function$
declare
  v_uid uuid:=auth.uid();
  v_c public.cb_campaigns%rowtype;
  v_refund integer;
begin
  if v_uid is null then raise exception 'Please sign in first'; end if;
  if p_status not in ('active','paused','cancelled') then raise exception 'Invalid campaign status'; end if;

  select * into v_c
  from public.cb_campaigns
  where id=p_campaign_id and user_id=v_uid
  for update;

  if not found then raise exception 'Campaign not found'; end if;
  if v_c.status='cancelled' then raise exception 'Campaign is already cancelled'; end if;

  if p_status='cancelled' and exists(
    select 1 from public.cb_campaign_submissions
    where campaign_id=p_campaign_id and status='pending'
  ) then
    raise exception 'Review or reject pending creator submissions before cancelling this campaign';
  end if;

  v_refund:=case when p_status='cancelled' then v_c.remaining_budget else 0 end;

  if p_status='cancelled' and v_refund>0 then
    insert into public.cb_points_accounts(user_id,balance)
    values(v_uid,v_refund)
    on conflict(user_id) do update
    set balance=public.cb_points_accounts.balance+excluded.balance,updated_at=now();

    insert into public.cb_points_ledger(user_id,submission_id,points,reason,entry_type,delta)
    values(v_uid,null,v_refund,'Unused campaign budget refund: '||v_c.title,'campaign_refund',v_refund);
  end if;

  update public.cb_campaigns
  set status=p_status,remaining_budget=remaining_budget-v_refund,updated_at=now()
  where id=p_campaign_id;

  return v_refund;
end
$function$;

create or replace function public.update_creatorboost_campaign_v2(
  p_campaign_id uuid, p_title text, p_url text, p_platform text,
  p_budget integer, p_reward_per_creator integer
)
returns integer
language plpgsql
security definer
set search_path to 'public', 'auth'
as $function$
declare
  v_uid uuid:=auth.uid();
  v_c public.cb_campaigns%rowtype;
  v_diff integer;
  v_unreserved_pending bigint;
begin
  if v_uid is null then raise exception 'Please sign in first'; end if;

  select * into v_c
  from public.cb_campaigns
  where id=p_campaign_id and user_id=v_uid
  for update;

  if not found or v_c.status='cancelled' then raise exception 'Campaign not found'; end if;
  if length(trim(coalesce(p_title,''))) not between 2 and 70 or p_url !~* '^https?://' then
    raise exception 'Enter a valid campaign name and public URL';
  end if;
  if p_platform not in ('Instagram','YouTube','TikTok','Facebook','X','Snapchat','Twitch','Kick','Threads','Pinterest','LinkedIn','Reddit') then
    raise exception 'Unsupported platform';
  end if;
  if p_budget is null or p_budget<10 or p_reward_per_creator is null
     or p_reward_per_creator<1 or p_reward_per_creator>p_budget then
    raise exception 'Invalid budget or creator reward';
  end if;

  v_diff:=p_budget-v_c.bid;

  select coalesce(sum(s.reward_points),0) into v_unreserved_pending
  from public.cb_campaign_submissions s
  where s.campaign_id=p_campaign_id and s.status='pending' and not s.budget_reserved;

  if v_c.remaining_budget+v_diff < v_unreserved_pending then
    raise exception 'New budget cannot be lower than pending creator rewards';
  end if;

  if v_diff>0 then
    update public.cb_points_accounts
    set balance=balance-v_diff,updated_at=now()
    where user_id=v_uid and balance>=v_diff;
    if not found then raise exception 'Not enough points for the increased budget'; end if;
  elsif v_diff<0 then
    update public.cb_points_accounts
    set balance=balance+abs(v_diff),updated_at=now()
    where user_id=v_uid;
  end if;

  update public.cb_campaigns
  set title=trim(p_title),url=trim(p_url),platform=p_platform,bid=p_budget,
      reward_per_creator=p_reward_per_creator,remaining_budget=remaining_budget+v_diff,updated_at=now()
  where id=p_campaign_id;

  if v_diff<>0 then
    insert into public.cb_points_ledger(user_id,submission_id,points,reason,entry_type,delta)
    values(v_uid,null,abs(v_diff),'Campaign budget adjustment: '||trim(p_title),'campaign_adjustment',-v_diff);
  end if;

  return v_diff;
end
$function$;
