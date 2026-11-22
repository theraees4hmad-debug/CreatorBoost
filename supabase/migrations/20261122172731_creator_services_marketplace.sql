-- CreatorBoost creator services marketplace: persistent orders, wallet checkout and manual payment review.
create table if not exists public.cb_service_orders (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 platform text not null,
 service text not null,
 deliverables integer not null check(deliverables between 1 and 20),
 project_url text not null check(project_url ~* '^https?://'),
 notes text not null default '',
 amount_inr numeric(12,2) not null check(amount_inr > 0),
 payment_method text not null check(payment_method in ('CreatorBoost wallet','UPI','Bank transfer','Crypto')),
 payment_request_id uuid references public.cb_payment_requests(id),
 status text not null default 'pending_payment' check(status in ('pending_payment','pending_review','queued','in_progress','delivered','completed','cancelled','rejected')),
 provider_name text,
 provider_reference text,
 admin_notes text not null default '',
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now()
);
create index if not exists cb_service_orders_user_idx on public.cb_service_orders(user_id,created_at desc);
create index if not exists cb_service_orders_status_idx on public.cb_service_orders(status,created_at);
alter table public.cb_service_orders enable row level security;
revoke all on public.cb_service_orders from anon,authenticated;

create or replace function public.create_creatorboost_service_order(
 p_platform text,p_service text,p_deliverables integer,p_url text,p_notes text,
 p_amount numeric,p_payment_method text,p_payment_reference text default ''
) returns uuid
language plpgsql security definer set search_path=public,auth as $$
declare v_uid uuid:=auth.uid(); v_order uuid; v_pay uuid;
begin
 if v_uid is null then raise exception 'Please sign in first'; end if;
 if p_platform not in ('Instagram','YouTube','TikTok','Facebook','X','Snapchat','Twitch','Kick','Threads','Pinterest','LinkedIn','Reddit') then raise exception 'Unsupported platform'; end if;
 if p_service not in ('Thumbnail design','Short-form video editing','Captions and subtitles','Channel content audit','Creator branding kit','Promotion strategy') then raise exception 'Unsupported service'; end if;
 if p_deliverables not between 1 and 20 then raise exception 'Choose 1–20 deliverables'; end if;
 if p_url !~* '^https?://' then raise exception 'Enter a valid project URL'; end if;
 if p_amount is null or p_amount<=0 or p_amount>1000000 then raise exception 'Invalid order amount'; end if;
 if p_payment_method not in ('CreatorBoost wallet','UPI','Bank transfer','Crypto') then raise exception 'Choose a valid payment method'; end if;
 if p_payment_method='CreatorBoost wallet' then
   update public.cb_points_accounts set balance=balance-round(p_amount*100),updated_at=now()
    where user_id=v_uid and balance>=round(p_amount*100);
   if not found then raise exception 'Not enough wallet points. Add points or choose another payment method.'; end if;
   insert into public.cb_points_ledger(user_id,submission_id,points,reason,entry_type,delta)
    values(v_uid,null,round(p_amount*100)::integer,'Creator service order: '||p_service,'service_order',-round(p_amount*100)::bigint);
   insert into public.cb_service_orders(user_id,platform,service,deliverables,project_url,notes,amount_inr,payment_method,status)
    values(v_uid,p_platform,p_service,p_deliverables,p_url,coalesce(p_notes,''),p_amount,p_payment_method,'queued') returning id into v_order;
 else
   if length(trim(coalesce(p_payment_reference,''))) not between 3 and 300 then raise exception 'Enter the UTR or transaction reference'; end if;
   insert into public.cb_payment_requests(user_id,request_type,amount,method,reference,details)
    values(v_uid,'buyer_order',p_amount,p_payment_method,trim(p_payment_reference),
      jsonb_build_object('platform',p_platform,'goal',p_service,'target',p_deliverables,'url',p_url,'notes',coalesce(p_notes,''),'kind','creator_service_order'))
    returning id into v_pay;
   insert into public.cb_service_orders(user_id,platform,service,deliverables,project_url,notes,amount_inr,payment_method,payment_request_id,status)
    values(v_uid,p_platform,p_service,p_deliverables,p_url,coalesce(p_notes,''),p_amount,p_payment_method,v_pay,'pending_review') returning id into v_order;
 end if;
 return v_order;
end $$;

create or replace function public.my_creatorboost_service_orders()
returns table(id uuid,platform text,service text,deliverables integer,project_url text,amount_inr numeric,payment_method text,status text,provider_name text,admin_notes text,created_at timestamptz)
language plpgsql stable security definer set search_path=public,auth as $$
begin
 if auth.uid() is null then raise exception 'Please sign in first'; end if;
 return query select o.id,o.platform,o.service,o.deliverables,o.project_url,o.amount_inr,o.payment_method,o.status,o.provider_name,o.admin_notes,o.created_at
 from public.cb_service_orders o where o.user_id=auth.uid() order by o.created_at desc limit 100;
end $$;

create or replace function public.admin_creatorboost_service_orders()
returns table(id uuid,user_id uuid,email text,platform text,service text,deliverables integer,project_url text,notes text,amount_inr numeric,payment_method text,status text,provider_name text,provider_reference text,created_at timestamptz)
language plpgsql stable security definer set search_path=public,auth as $$
begin
 if auth.uid() is null or not exists(select 1 from public.cb_task_reviewers r where r.user_id=auth.uid()) then raise exception 'Admin permission required'; end if;
 return query select o.id,o.user_id,u.email::text,o.platform,o.service,o.deliverables,o.project_url,o.notes,o.amount_inr,o.payment_method,o.status,o.provider_name,o.provider_reference,o.created_at
 from public.cb_service_orders o join auth.users u on u.id=o.user_id
 order by o.created_at asc limit 200;
end $$;

create or replace function public.admin_update_creatorboost_service_order(
 p_order_id uuid,p_status text,p_provider_name text default '',p_provider_reference text default '',p_admin_notes text default ''
) returns text
language plpgsql security definer set search_path=public,auth as $$
declare v_order public.cb_service_orders%rowtype;
begin
 if auth.uid() is null or not exists(select 1 from public.cb_task_reviewers r where r.user_id=auth.uid()) then raise exception 'Admin permission required'; end if;
 if p_status not in ('queued','in_progress','delivered','completed','cancelled','rejected') then raise exception 'Invalid order status'; end if;
 select * into v_order from public.cb_service_orders where id=p_order_id for update;
 if not found then raise exception 'Service order not found'; end if;
 if v_order.status='pending_review' and v_order.payment_request_id is not null and not exists(select 1 from public.cb_payment_requests p where p.id=v_order.payment_request_id and p.status='approved') and p_status not in ('rejected','cancelled') then raise exception 'Verify the customer payment before starting this order'; end if;
 update public.cb_service_orders set status=p_status,provider_name=nullif(trim(p_provider_name),''),provider_reference=nullif(trim(p_provider_reference),''),admin_notes=coalesce(p_admin_notes,''),updated_at=now()
 where id=p_order_id;
 if not found then raise exception 'Service order not found'; end if;
 return p_status;
end $$;

create or replace function public.sync_creatorboost_service_order_payment()
returns trigger language plpgsql security definer set search_path=public as $$
begin
 if old.status is distinct from new.status then
  update public.cb_service_orders set
   status=case when new.status='approved' then 'queued' when new.status='rejected' then 'rejected' else status end,
   updated_at=now()
  where payment_request_id=new.id and status='pending_review';
 end if;
 return new;
end $$;
drop trigger if exists cb_service_order_payment_sync on public.cb_payment_requests;
create trigger cb_service_order_payment_sync after update of status on public.cb_payment_requests
for each row execute function public.sync_creatorboost_service_order_payment();

revoke all on function public.create_creatorboost_service_order(text,text,integer,text,text,numeric,text,text) from public,anon;
revoke all on function public.my_creatorboost_service_orders() from public,anon;
revoke all on function public.admin_creatorboost_service_orders() from public,anon;
revoke all on function public.admin_update_creatorboost_service_order(uuid,text,text,text,text) from public,anon;
grant execute on function public.create_creatorboost_service_order(text,text,integer,text,text,numeric,text,text) to authenticated;
grant execute on function public.my_creatorboost_service_orders() to authenticated;
grant execute on function public.admin_creatorboost_service_orders() to authenticated;
grant execute on function public.admin_update_creatorboost_service_order(uuid,text,text,text,text) to authenticated;
