-- CreatorBoost authoritative points wallet, daily rewards and campaign bidding.
-- Run this migration in the Supabase SQL Editor after migrations 001-004.

alter table public.cb_points_ledger
  alter column submission_id drop not null;

alter table public.cb_points_ledger
  add column if not exists entry_type text not null default 'task_reward';

create table if not exists public.cb_campaigns (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  title text not null check (length(trim(title)) between 2 and 70),
  url text not null check (url ~* '^https?://'),
  platform text not null check (platform in ('Instagram','YouTube','TikTok','Facebook','X','Snapchat','Twitch','Kick','Threads','Pinterest','LinkedIn','Reddit')),
  bid integer not null check (bid >= 10),
  status text not null default 'active' check (status in ('active','paused','cancelled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.cb_campaigns enable row level security;
drop policy if exists "Users read own campaigns" on public.cb_campaigns;
create policy "Users read own campaigns" on public.cb_campaigns
  for select to authenticated using (auth.uid() = user_id);
revoke all on public.cb_campaigns from anon, authenticated;
grant select on public.cb_campaigns to authenticated;

create table if not exists public.cb_daily_points_claims (
  user_id uuid not null references auth.users(id) on delete cascade,
  claim_date date not null default (timezone('utc',now())::date),
  points integer not null default 10 check (points > 0),
  created_at timestamptz not null default now(),
  primary key(user_id,claim_date)
);
alter table public.cb_daily_points_claims enable row level security;
revoke all on public.cb_daily_points_claims from anon, authenticated;

create table if not exists public.cb_daily_verified_task_progress (
  user_id uuid not null references auth.users(id) on delete cascade,
  task_date date not null,
  verified_count integer not null default 0,
  claimed_milestones integer[] not null default '{}',
  primary key(user_id,task_date)
);
alter table public.cb_daily_verified_task_progress enable row level security;
revoke all on public.cb_daily_verified_task_progress from anon, authenticated;

create or replace function public.my_creatorboost_wallet()
returns table(balance bigint)
language plpgsql security definer set search_path=public,auth as $$
begin
  if auth.uid() is null then raise exception 'Please sign in first'; end if;
  insert into public.cb_points_accounts(user_id,balance)
  values(auth.uid(),0) on conflict(user_id) do nothing;
  return query select a.balance from public.cb_points_accounts a where a.user_id=auth.uid();
end $$;

create or replace function public.my_creatorboost_daily_claim_status()
returns boolean language sql stable security definer set search_path=public,auth as $
  select exists(select 1 from public.cb_daily_points_claims
    where user_id=auth.uid() and claim_date=timezone('utc',now())::date)
$;

create or replace function public.claim_creatorboost_daily_points()
returns integer
language plpgsql security definer set search_path=public,auth as $$
declare v_uid uuid := auth.uid(); v_day date := timezone('utc',now())::date; v_points integer := 10;
begin
  if v_uid is null then raise exception 'Please sign in first'; end if;
  insert into public.cb_daily_points_claims(user_id,claim_date,points)
  values(v_uid,v_day,v_points);
  insert into public.cb_points_accounts(user_id,balance) values(v_uid,v_points)
  on conflict(user_id) do update set balance=public.cb_points_accounts.balance+v_points,updated_at=now();
  insert into public.cb_points_ledger(user_id,submission_id,points,reason,entry_type)
  values(v_uid,null,v_points,'Daily check-in','daily_bonus');
  return v_points;
exception when unique_violation then
  raise exception 'You have already claimed today’s daily points';
end $$;

create or replace function public.my_creatorboost_campaigns()
returns table(id uuid,title text,url text,platform text,bid integer,status text,created_at timestamptz,is_mine boolean)
language sql stable security definer set search_path=public,auth as $
  select c.id,c.title,c.url,c.platform,c.bid,c.status,c.created_at,(c.user_id=auth.uid())
  from public.cb_campaigns c
  where c.status='active' or (c.user_id=auth.uid() and c.status='paused')
  order by (c.user_id=auth.uid()) desc,c.created_at desc
$;

create or replace function public.create_creatorboost_campaign(
  p_title text,p_url text,p_platform text,p_bid integer
) returns uuid
language plpgsql security definer set search_path=public,auth as $$
declare v_uid uuid := auth.uid(); v_id uuid;
begin
  if v_uid is null then raise exception 'Please sign in first'; end if;
  if length(trim(coalesce(p_title,''))) not between 2 and 70 then raise exception 'Campaign name must be 2–70 characters'; end if;
  if p_url !~* '^https?://' then raise exception 'Enter a valid public http or https URL'; end if;
  if p_platform not in ('Instagram','YouTube','TikTok','Facebook','X','Snapchat','Twitch','Kick','Threads','Pinterest','LinkedIn','Reddit') then raise exception 'Unsupported platform'; end if;
  if p_bid is null or p_bid < 10 then raise exception 'Minimum bid is 10 points'; end if;
  update public.cb_points_accounts set balance=balance-p_bid,updated_at=now()
    where user_id=v_uid and balance >= p_bid;
  if not found then raise exception 'Not enough points'; end if;
  insert into public.cb_campaigns(user_id,title,url,platform,bid)
    values(v_uid,trim(p_title),trim(p_url),p_platform,p_bid) returning id into v_id;
  insert into public.cb_points_ledger(user_id,submission_id,points,reason,entry_type)
    values(v_uid,null,p_bid,'Campaign bid: '||trim(p_title),'campaign_bid');
  return v_id;
end $$;

create or replace function public.update_creatorboost_campaign(
  p_campaign_id uuid,p_title text,p_url text,p_platform text,p_bid integer
) returns integer
language plpgsql security definer set search_path=public,auth as $$
declare v_uid uuid := auth.uid(); v_c public.cb_campaigns%rowtype; v_diff integer;
begin
  if v_uid is null then raise exception 'Please sign in first'; end if;
  select * into v_c from public.cb_campaigns where id=p_campaign_id and user_id=v_uid for update;
  if not found or v_c.status='cancelled' then raise exception 'Campaign not found'; end if;
  if length(trim(coalesce(p_title,''))) not between 2 and 70 or p_url !~* '^https?://' then raise exception 'Enter a valid campaign name and public URL'; end if;
  if p_platform not in ('Instagram','YouTube','TikTok','Facebook','X','Snapchat','Twitch','Kick','Threads','Pinterest','LinkedIn','Reddit') then raise exception 'Unsupported platform'; end if;
  if p_bid is null or p_bid < 10 then raise exception 'Minimum bid is 10 points'; end if;
  v_diff := p_bid-v_c.bid;
  if v_diff > 0 then
    update public.cb_points_accounts set balance=balance-v_diff,updated_at=now()
      where user_id=v_uid and balance >= v_diff;
    if not found then raise exception 'Not enough points for the increased bid'; end if;
  elsif v_diff < 0 then
    update public.cb_points_accounts set balance=balance+abs(v_diff),updated_at=now() where user_id=v_uid;
  end if;
  update public.cb_campaigns set title=trim(p_title),url=trim(p_url),platform=p_platform,bid=p_bid,updated_at=now()
    where id=p_campaign_id;
  if v_diff <> 0 then
    insert into public.cb_points_ledger(user_id,submission_id,points,reason,entry_type)
      values(v_uid,null,abs(v_diff),'Campaign bid adjustment: '||trim(p_title),'campaign_adjustment');
  end if;
  return v_diff;
end $$;

create or replace function public.set_creatorboost_campaign_status(p_campaign_id uuid,p_status text)
returns integer
language plpgsql security definer set search_path=public,auth as $$
declare v_uid uuid := auth.uid(); v_c public.cb_campaigns%rowtype;
begin
  if v_uid is null then raise exception 'Please sign in first'; end if;
  if p_status not in ('active','paused','cancelled') then raise exception 'Invalid campaign status'; end if;
  select * into v_c from public.cb_campaigns where id=p_campaign_id and user_id=v_uid for update;
  if not found then raise exception 'Campaign not found'; end if;
  if v_c.status='cancelled' then raise exception 'Campaign is already cancelled'; end if;
  if p_status='cancelled' then
    update public.cb_points_accounts set balance=balance+v_c.bid,updated_at=now() where user_id=v_uid;
    insert into public.cb_points_ledger(user_id,submission_id,points,reason,entry_type)
      values(v_uid,null,v_c.bid,'Campaign refund: '||v_c.title,'campaign_refund');
  end if;
  update public.cb_campaigns set status=p_status,updated_at=now() where id=p_campaign_id;
  return case when p_status='cancelled' then v_c.bid else 0 end;
end $$;

create or replace function public.apply_creatorboost_verified_task_milestone()
returns trigger language plpgsql security definer set search_path=public,auth as $$
declare v_count integer; v_claimed integer[]; v_milestone integer; v_reward integer;
begin
  if new.status='approved' and old.status='pending' then
    insert into public.cb_daily_verified_task_progress(user_id,task_date,verified_count)
      values(new.user_id,timezone('utc',now())::date,1)
    on conflict(user_id,task_date) do update
      set verified_count=public.cb_daily_verified_task_progress.verified_count+1
    returning verified_count,claimed_milestones into v_count,v_claimed;
    for v_milestone,v_reward in
      select * from (values (10,10),(20,20),(50,70),(100,100)) as rewards(milestone,reward)
    loop
      if v_count >= v_milestone and not (v_milestone = any(v_claimed)) then
        insert into public.cb_points_accounts(user_id,balance) values(new.user_id,v_reward)
        on conflict(user_id) do update set balance=public.cb_points_accounts.balance+v_reward,updated_at=now();
        insert into public.cb_points_ledger(user_id,submission_id,points,reason,entry_type)
          values(new.user_id,null,v_reward,'Daily verified-task milestone: '||v_milestone,'daily_task_milestone');
        update public.cb_daily_verified_task_progress
          set claimed_milestones=array_append(claimed_milestones,v_milestone)
          where user_id=new.user_id and task_date=timezone('utc',now())::date;
        v_claimed:=array_append(v_claimed,v_milestone);
      end if;
    end loop;
  end if;
  return new;
end $$;

drop trigger if exists cb_verified_task_milestone on public.cb_task_submissions;
create trigger cb_verified_task_milestone
after update of status on public.cb_task_submissions
for each row execute function public.apply_creatorboost_verified_task_milestone();

create or replace function public.my_creatorboost_daily_progress()
returns table(verified_count integer,claimed_milestones integer[])
language sql stable security definer set search_path=public,auth as $$
  select coalesce(p.verified_count,0),coalesce(p.claimed_milestones,'{}'::integer[])
  from (select auth.uid() as user_id) u
  left join public.cb_daily_verified_task_progress p
    on p.user_id=u.user_id and p.task_date=timezone('utc',now())::date
$$;

revoke all on function public.my_creatorboost_wallet() from public,anon;
revoke all on function public.claim_creatorboost_daily_points() from public,anon;
revoke all on function public.my_creatorboost_daily_claim_status() from public,anon;
revoke all on function public.my_creatorboost_campaigns() from public,anon;
revoke all on function public.create_creatorboost_campaign(text,text,text,integer) from public,anon;
revoke all on function public.update_creatorboost_campaign(uuid,text,text,text,integer) from public,anon;
revoke all on function public.set_creatorboost_campaign_status(uuid,text) from public,anon;
revoke all on function public.my_creatorboost_daily_progress() from public,anon;
grant execute on function public.my_creatorboost_wallet() to authenticated;
grant execute on function public.claim_creatorboost_daily_points() to authenticated;
grant execute on function public.my_creatorboost_daily_claim_status() to authenticated;
grant execute on function public.my_creatorboost_campaigns() to authenticated;
grant execute on function public.create_creatorboost_campaign(text,text,text,integer) to authenticated;
grant execute on function public.update_creatorboost_campaign(uuid,text,text,text,integer) to authenticated;
grant execute on function public.set_creatorboost_campaign_status(uuid,text) to authenticated;
grant execute on function public.my_creatorboost_daily_progress() to authenticated;
