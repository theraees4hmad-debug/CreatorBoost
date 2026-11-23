-- CreatorBoost campaign categories and first-party promotion analytics.
alter table public.cb_campaigns add column if not exists category text not null default 'General';
alter table public.cb_campaigns drop constraint if exists cb_campaigns_category_check;
alter table public.cb_campaigns add constraint cb_campaigns_category_check
 check (category in ('Gaming','Education','Lifestyle','Music','Art & Design','Technology','Fitness','Business','General'));

create table if not exists public.cb_campaign_events (
 id bigint generated always as identity primary key,
 campaign_id uuid not null references public.cb_campaigns(id) on delete cascade,
 user_id uuid not null,
 event_type text not null check(event_type in ('impression','click')),
 event_day date not null default current_date,
 created_at timestamptz not null default now(),
 unique(campaign_id,user_id,event_type,event_day)
);
alter table public.cb_campaign_events enable row level security;
revoke all on public.cb_campaign_events from public,anon,authenticated;

create or replace function public.create_creatorboost_campaign_v2(
 p_title text,p_url text,p_platform text,p_budget integer,p_reward_per_creator integer,p_category text default 'General'
) returns uuid language plpgsql security definer set search_path to 'public','auth'
as $function$
declare v_uid uuid:=auth.uid(); v_id uuid; v_category text:=coalesce(nullif(trim(p_category),''),'General');
begin
 if v_uid is null then raise exception 'Please sign in first'; end if;
 if length(trim(coalesce(p_title,''))) not between 2 and 70 then raise exception 'Campaign name must be 2–70 characters'; end if;
 if p_url !~* '^https?://' then raise exception 'Enter a valid public http or https URL'; end if;
 if p_platform not in ('Instagram','YouTube','TikTok','Facebook','X','Snapchat','Twitch','Kick','Threads','Pinterest','LinkedIn','Reddit') then raise exception 'Unsupported platform'; end if;
 if v_category not in ('Gaming','Education','Lifestyle','Music','Art & Design','Technology','Fitness','Business','General') then raise exception 'Choose a valid creator category'; end if;
 if p_budget is null or p_budget<10 then raise exception 'Minimum campaign budget is 10 points'; end if;
 if p_reward_per_creator is null or p_reward_per_creator<1 or p_reward_per_creator>p_budget then raise exception 'Creator reward must be at least 1 and no more than the campaign budget'; end if;
 update public.cb_points_accounts set balance=balance-p_budget,updated_at=now() where user_id=v_uid and balance>=p_budget;
 if not found then raise exception 'Not enough points'; end if;
 insert into public.cb_campaigns(user_id,title,url,platform,bid,reward_per_creator,remaining_budget,category)
 values(v_uid,trim(p_title),trim(p_url),p_platform,p_budget,p_reward_per_creator,p_budget,v_category) returning id into v_id;
 insert into public.cb_points_ledger(user_id,submission_id,points,reason,entry_type,delta)
 values(v_uid,null,p_budget,'Campaign budget reserved: '||trim(p_title),'campaign_bid',-p_budget);
 return v_id;
end $function$;

create or replace function public.update_creatorboost_campaign_v2(
 p_campaign_id uuid,p_title text,p_url text,p_platform text,p_budget integer,p_reward_per_creator integer,p_category text default null
) returns integer language plpgsql security definer set search_path to 'public','auth'
as $function$
declare v_uid uuid:=auth.uid(); v_c public.cb_campaigns%rowtype; v_diff integer; v_unreserved_pending bigint; v_category text;
begin
 if v_uid is null then raise exception 'Please sign in first'; end if;
 select * into v_c from public.cb_campaigns where id=p_campaign_id and user_id=v_uid for update;
 if not found or v_c.status='cancelled' then raise exception 'Campaign not found'; end if;
 v_category:=coalesce(nullif(trim(p_category),''),v_c.category,'General');
 if length(trim(coalesce(p_title,''))) not between 2 and 70 or p_url !~* '^https?://' then raise exception 'Enter a valid campaign name and public URL'; end if;
 if p_platform not in ('Instagram','YouTube','TikTok','Facebook','X','Snapchat','Twitch','Kick','Threads','Pinterest','LinkedIn','Reddit') then raise exception 'Unsupported platform'; end if;
 if v_category not in ('Gaming','Education','Lifestyle','Music','Art & Design','Technology','Fitness','Business','General') then raise exception 'Choose a valid creator category'; end if;
 if p_budget is null or p_budget<10 or p_reward_per_creator is null or p_reward_per_creator<1 or p_reward_per_creator>p_budget then raise exception 'Invalid budget or creator reward'; end if;
 v_diff:=p_budget-v_c.bid;
 select coalesce(sum(s.reward_points),0) into v_unreserved_pending from public.cb_campaign_submissions s where s.campaign_id=p_campaign_id and s.status='pending' and not s.budget_reserved;
 if v_c.remaining_budget+v_diff<v_unreserved_pending then raise exception 'New budget cannot be lower than pending creator rewards'; end if;
 if v_diff>0 then
  update public.cb_points_accounts set balance=balance-v_diff,updated_at=now() where user_id=v_uid and balance>=v_diff;
  if not found then raise exception 'Not enough points for the increased budget'; end if;
 elsif v_diff<0 then update public.cb_points_accounts set balance=balance+abs(v_diff),updated_at=now() where user_id=v_uid; end if;
 update public.cb_campaigns set title=trim(p_title),url=trim(p_url),platform=p_platform,bid=p_budget,
  reward_per_creator=p_reward_per_creator,remaining_budget=remaining_budget+v_diff,category=v_category,updated_at=now()
 where id=p_campaign_id;
 if v_diff<>0 then
  insert into public.cb_points_ledger(user_id,submission_id,points,reason,entry_type,delta)
  values(v_uid,null,abs(v_diff),'Campaign budget adjustment: '||trim(p_title),'campaign_adjustment',-v_diff);
 end if;
 return v_diff;
end $function$;

drop function if exists public.my_creatorboost_campaigns_v2();
create function public.my_creatorboost_campaigns_v2()
returns table(id uuid,title text,url text,platform text,bid integer,status text,created_at timestamptz,is_mine boolean,
 reward_per_creator integer,remaining_budget integer,category text,impression_count bigint,click_count bigint,approved_count bigint)
language sql stable security definer set search_path to 'public','auth'
as $function$
 select c.id,c.title,c.url,c.platform,c.bid,c.status,c.created_at,(c.user_id=auth.uid()),c.reward_per_creator,c.remaining_budget,c.category,
 (select count(*) from public.cb_campaign_events e where e.campaign_id=c.id and e.event_type='impression'),
 (select count(*) from public.cb_campaign_events e where e.campaign_id=c.id and e.event_type='click'),
 (select count(*) from public.cb_campaign_submissions s where s.campaign_id=c.id and s.status='approved')
 from public.cb_campaigns c
 where c.status='active' or (c.user_id=auth.uid() and c.status in ('paused','cancelled'))
 order by (c.user_id=auth.uid()) desc,c.created_at desc
$function$;

create or replace function public.track_creatorboost_campaign_event(p_campaign_id uuid,p_event_type text)
returns boolean language plpgsql security definer set search_path to 'public','auth'
as $function$
declare v_uid uuid:=auth.uid();
begin
 if v_uid is null then raise exception 'Please sign in first'; end if;
 if p_event_type not in ('impression','click') then raise exception 'Invalid event'; end if;
 if not exists(select 1 from public.cb_campaigns c where c.id=p_campaign_id and c.status='active' and c.user_id<>v_uid) then return false; end if;
 insert into public.cb_campaign_events(campaign_id,user_id,event_type)
 values(p_campaign_id,v_uid,p_event_type) on conflict(campaign_id,user_id,event_type,event_day) do nothing;
 return found;
end $function$;

revoke all on function public.create_creatorboost_campaign_v2(text,text,text,integer,integer,text) from public,anon;
grant execute on function public.create_creatorboost_campaign_v2(text,text,text,integer,integer,text) to authenticated;
revoke all on function public.update_creatorboost_campaign_v2(uuid,text,text,text,integer,integer,text) from public,anon;
grant execute on function public.update_creatorboost_campaign_v2(uuid,text,text,text,integer,integer,text) to authenticated;
revoke all on function public.my_creatorboost_campaigns_v2() from public,anon;
grant execute on function public.my_creatorboost_campaigns_v2() to authenticated;
revoke all on function public.track_creatorboost_campaign_event(uuid,text) from public,anon;
grant execute on function public.track_creatorboost_campaign_event(uuid,text) to authenticated;
drop function if exists public.create_creatorboost_campaign_v2(text,text,text,integer,integer);
drop function if exists public.update_creatorboost_campaign_v2(uuid,text,text,text,integer,integer);
