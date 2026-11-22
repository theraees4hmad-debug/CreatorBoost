-- CreatorBoost unified manual payment approval queue.
-- Run after migrations 001-006 in Supabase SQL Editor.

create table if not exists public.cb_payment_requests (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 request_type text not null check (request_type in ('deposit','buyer_order')),
 amount numeric(12,2) not null check (amount > 0),
 method text not null check (method in ('UPI','Bank transfer','Crypto')),
 reference text not null check (length(trim(reference)) between 3 and 300),
 details jsonb not null default '{}'::jsonb,
 status text not null default 'pending' check (status in ('pending','approved','rejected')),
 created_at timestamptz not null default now(),
 reviewed_at timestamptz,
 reviewer_id uuid references auth.users(id)
);
create index if not exists cb_payment_requests_pending_idx
 on public.cb_payment_requests(status,created_at);
create index if not exists cb_payment_requests_user_idx
 on public.cb_payment_requests(user_id,created_at desc);
alter table public.cb_payment_requests enable row level security;
revoke all on public.cb_payment_requests from anon,authenticated;

create or replace function public.create_creatorboost_payment_request(
 p_type text,p_amount numeric,p_method text,p_reference text,p_details jsonb default '{}'::jsonb
) returns uuid
language plpgsql security definer set search_path=public,auth as $$
declare v_uid uuid:=auth.uid();v_id uuid;
begin
 if v_uid is null then raise exception 'Please sign in first'; end if;
 if p_type not in ('deposit','buyer_order') then raise exception 'Invalid payment request type'; end if;
 if p_amount is null or p_amount<=0 or p_amount>1000000 then raise exception 'Enter a valid amount'; end if;
 if p_method not in ('UPI','Bank transfer','Crypto') then raise exception 'Choose a valid payment method'; end if;
 if length(trim(coalesce(p_reference,''))) not between 3 and 300 then raise exception 'Enter a valid transaction reference'; end if;
 if p_details is null or jsonb_typeof(p_details)<>'object' then raise exception 'Invalid request details'; end if;
 if p_type='buyer_order' and (
   length(coalesce(p_details->>'url',''))<8 or
   coalesce(p_details->>'goal','')='' or
   coalesce(p_details->>'platform','')=''
 ) then raise exception 'Buyer order details are incomplete'; end if;
 insert into public.cb_payment_requests(user_id,request_type,amount,method,reference,details)
 values(v_uid,p_type,p_amount,p_method,trim(p_reference),p_details)
 returning id into v_id;
 return v_id;
end $$;

create or replace function public.my_creatorboost_payment_requests()
returns table(id uuid,request_type text,amount numeric,method text,reference text,status text,created_at timestamptz)
language plpgsql stable security definer set search_path=public,auth as $$
begin
 if auth.uid() is null then raise exception 'Please sign in first'; end if;
 return query select p.id,p.request_type,p.amount,p.method,p.reference,p.status,p.created_at
 from public.cb_payment_requests p where p.user_id=auth.uid()
 order by p.created_at desc limit 100;
end $$;

create or replace function public.admin_creatorboost_payment_requests()
returns table(id uuid,user_id uuid,email text,request_type text,amount numeric,method text,reference text,details jsonb,created_at timestamptz)
language plpgsql stable security definer set search_path=public,auth as $$
begin
 if auth.uid() is null or not exists(select 1 from public.cb_task_reviewers r where r.user_id=auth.uid()) then
  raise exception 'Admin permission required';
 end if;
 return query select p.id,p.user_id,u.email::text,p.request_type,p.amount,p.method,p.reference,p.details,p.created_at
 from public.cb_payment_requests p join auth.users u on u.id=p.user_id
 where p.status='pending' order by p.created_at asc;
end $$;

create or replace function public.admin_review_creatorboost_payment(
 p_request_id uuid,p_action text
) returns text
language plpgsql security definer set search_path=public,auth as $$
declare v_p public.cb_payment_requests%rowtype; v_credit bigint;
begin
 if auth.uid() is null or not exists(select 1 from public.cb_task_reviewers r where r.user_id=auth.uid()) then
  raise exception 'Admin permission required';
 end if;
 if p_action not in ('approve','reject') then raise exception 'Invalid review action'; end if;
 select * into v_p from public.cb_payment_requests where id=p_request_id for update;
 if not found then raise exception 'Payment request not found'; end if;
 if v_p.status<>'pending' then raise exception 'This payment request has already been reviewed'; end if;

 -- Only a verified wallet deposit credits points. Buyer orders are payment
 -- confirmations for a campaign request and must never credit the wallet.
 if p_action='approve' and v_p.request_type='deposit' then
  v_credit:=round(v_p.amount*100)::bigint;
  if v_credit<1 then raise exception 'Deposit is too small to convert to points'; end if;
  insert into public.cb_points_accounts(user_id,balance)
   values(v_p.user_id,v_credit)
   on conflict(user_id) do update
    set balance=public.cb_points_accounts.balance+excluded.balance,updated_at=now();
  insert into public.cb_points_ledger(user_id,submission_id,points,reason,entry_type,delta)
   values(v_p.user_id,null,v_credit,'Verified wallet deposit','deposit_credit',v_credit);
 end if;

 update public.cb_payment_requests set status=case when p_action='approve' then 'approved' else 'rejected' end,
 reviewed_at=now(),reviewer_id=auth.uid() where id=p_request_id;
 return case when p_action='approve' then 'approved' else 'rejected' end;
end $;

revoke all on function public.create_creatorboost_payment_request(text,numeric,text,text,jsonb) from public,anon;
revoke all on function public.my_creatorboost_payment_requests() from public,anon;
revoke all on function public.admin_creatorboost_payment_requests() from public,anon;
revoke all on function public.admin_review_creatorboost_payment(uuid,text) from public,anon;
grant execute on function public.create_creatorboost_payment_request(text,numeric,text,text,jsonb) to authenticated;
grant execute on function public.my_creatorboost_payment_requests() to authenticated;
grant execute on function public.admin_creatorboost_payment_requests() to authenticated;
grant execute on function public.admin_review_creatorboost_payment(uuid,text) to authenticated;
