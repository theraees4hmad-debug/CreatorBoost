-- CreatorBoost secure withdrawal requests and admin approval queue.
-- Run this migration in the Supabase SQL Editor after migration 005.

create table if not exists public.cb_withdrawal_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  points integer not null check (points between 1000 and 5000 and points % 100 = 0),
  amount numeric(10,2) not null check (amount between 10 and 50),
  method text not null check (method in ('UPI','Bank transfer','Crypto')),
  destination text not null check (length(trim(destination)) between 3 and 500),
  status text not null default 'pending' check (status in ('pending','paid','rejected')),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewer_id uuid references auth.users(id)
);
create index if not exists cb_withdrawal_requests_status_created_idx
  on public.cb_withdrawal_requests(status,created_at);
create index if not exists cb_withdrawal_requests_user_created_idx
  on public.cb_withdrawal_requests(user_id,created_at desc);
alter table public.cb_withdrawal_requests enable row level security;
revoke all on public.cb_withdrawal_requests from anon, authenticated;

create or replace function public.create_creatorboost_withdrawal(
  p_points integer, p_method text, p_destination text
) returns uuid
language plpgsql security definer set search_path=public,auth as $$
declare v_uid uuid := auth.uid(); v_id uuid; v_balance bigint;
begin
  if v_uid is null then raise exception 'Please sign in first'; end if;
  if p_points is null or p_points < 1000 or p_points > 5000 or p_points % 100 <> 0 then
    raise exception 'Withdrawal must be between 1,000 and 5,000 points in 100-point steps';
  end if;
  if p_method not in ('UPI','Bank transfer','Crypto') then raise exception 'Choose a valid payout method'; end if;
  if length(trim(coalesce(p_destination,''))) not between 3 and 500 then raise exception 'Enter valid payout details'; end if;
  select balance into v_balance from public.cb_points_accounts where user_id=v_uid for update;
  if not found or v_balance < p_points then raise exception 'Not enough available points'; end if;
  update public.cb_points_accounts set balance=balance-p_points,updated_at=now() where user_id=v_uid;
  insert into public.cb_withdrawal_requests(user_id,points,amount,method,destination)
    values(v_uid,p_points,p_points/100.0,p_method,trim(p_destination)) returning id into v_id;
  insert into public.cb_points_ledger(user_id,submission_id,points,reason,entry_type,delta)
    values(v_uid,null,p_points,'Withdrawal request reserved','withdrawal_hold',-p_points);
  return v_id;
end $$;

create or replace function public.my_creatorboost_withdrawals()
returns table(id uuid,points integer,amount numeric,method text,destination text,status text,created_at timestamptz)
language plpgsql stable security definer set search_path=public,auth as $$
begin
  if auth.uid() is null then raise exception 'Please sign in first'; end if;
  return query select w.id,w.points,w.amount,w.method,w.destination,w.status,w.created_at
  from public.cb_withdrawal_requests w where w.user_id=auth.uid()
  order by w.created_at desc limit 50;
end $$;

create or replace function public.admin_creatorboost_withdrawals()
returns table(id uuid,user_id uuid,email text,points integer,amount numeric,method text,destination text,created_at timestamptz)
language plpgsql stable security definer set search_path=public,auth as $$
begin
  if auth.uid() is null or not exists(select 1 from public.cb_task_reviewers r where r.user_id=auth.uid()) then
    raise exception 'Admin permission required';
  end if;
  return query
  select w.id,w.user_id,u.email::text,w.points,w.amount,w.method,w.destination,w.created_at
  from public.cb_withdrawal_requests w
  join auth.users u on u.id=w.user_id
  where w.status='pending'
  order by w.created_at asc;
end $$;

create or replace function public.admin_review_creatorboost_withdrawal(
  p_request_id uuid, p_action text
) returns text
language plpgsql security definer set search_path=public,auth as $$
declare v_w public.cb_withdrawal_requests%rowtype;
begin
  if auth.uid() is null or not exists(select 1 from public.cb_task_reviewers r where r.user_id=auth.uid()) then
    raise exception 'Admin permission required';
  end if;
  if p_action not in ('paid','reject') then raise exception 'Invalid review action'; end if;
  select * into v_w from public.cb_withdrawal_requests where id=p_request_id for update;
  if not found then raise exception 'Withdrawal request not found'; end if;
  if v_w.status <> 'pending' then raise exception 'This withdrawal has already been reviewed'; end if;
  if p_action='paid' then
    update public.cb_withdrawal_requests set status='paid',reviewed_at=now(),reviewer_id=auth.uid() where id=p_request_id;
    return 'paid';
  end if;
  update public.cb_points_accounts set balance=balance+v_w.points,updated_at=now() where user_id=v_w.user_id;
  insert into public.cb_points_ledger(user_id,submission_id,points,reason,entry_type,delta)
    values(v_w.user_id,null,v_w.points,'Rejected withdrawal refunded','withdrawal_refund',v_w.points);
  update public.cb_withdrawal_requests set status='rejected',reviewed_at=now(),reviewer_id=auth.uid() where id=p_request_id;
  return 'rejected';
end $$;

revoke all on function public.create_creatorboost_withdrawal(integer,text,text) from public,anon;
revoke all on function public.my_creatorboost_withdrawals() from public,anon;
revoke all on function public.admin_creatorboost_withdrawals() from public,anon;
revoke all on function public.admin_review_creatorboost_withdrawal(uuid,text) from public,anon;
grant execute on function public.create_creatorboost_withdrawal(integer,text,text) to authenticated;
grant execute on function public.my_creatorboost_withdrawals() to authenticated;
grant execute on function public.admin_creatorboost_withdrawals() to authenticated;
grant execute on function public.admin_review_creatorboost_withdrawal(uuid,text) to authenticated;
