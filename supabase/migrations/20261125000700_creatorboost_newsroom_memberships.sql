-- Additive CreatorBoost Newsroom memberships. Existing wallet/campaign tables are untouched.
create table if not exists public.cb_membership_plans (
  plan_key text primary key check (plan_key in ('free','pro','vip')),
  name text not null,
  monthly_price_inr integer not null check (monthly_price_inr >= 0),
  yearly_price_inr integer,
  description text not null default '',
  active boolean not null default true,
  created_at timestamptz not null default now()
);
insert into public.cb_membership_plans (plan_key,name,monthly_price_inr,yearly_price_inr,description,active)
values
 ('free','Free',0,0,'Essential gaming and streaming news',true),
 ('pro','Pro',99,999,'Ad-free reading, unlimited bookmarks and premium reports',true),
 ('vip','VIP',249,null,'Pro benefits plus VIP community and exclusive insights',false)
on conflict (plan_key) do update set name=excluded.name,monthly_price_inr=excluded.monthly_price_inr,yearly_price_inr=excluded.yearly_price_inr,description=excluded.description,active=excluded.active;

create table if not exists public.cb_membership_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references auth.users(id) on delete cascade,
  plan_key text not null default 'free' references public.cb_membership_plans(plan_key),
  billing_period text not null default 'monthly' check (billing_period in ('monthly','yearly','lifetime')),
  status text not null default 'free' check (status in ('free','pending','active','expired','cancelled')),
  started_at timestamptz,
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint cb_membership_subscription_dates check (expires_at is null or started_at is null or expires_at > started_at)
);
create index if not exists cb_membership_subscriptions_expiry_idx on public.cb_membership_subscriptions(status,expires_at);

create table if not exists public.cb_membership_payments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  plan_key text not null check (plan_key in ('pro','vip')),
  billing_period text not null check (billing_period in ('monthly','yearly')),
  amount_inr integer not null check (
    (plan_key='pro' and billing_period='monthly' and amount_inr=99) or
    (plan_key='pro' and billing_period='yearly' and amount_inr=999) or
    (plan_key='vip' and billing_period='monthly' and amount_inr=249)
  ),
  payment_method text not null default 'upi' check (payment_method='upi'),
  transaction_reference text not null check (length(trim(transaction_reference)) between 6 and 120),
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists cb_membership_payments_user_idx on public.cb_membership_payments(user_id,created_at desc);

alter table public.cb_membership_plans enable row level security;
alter table public.cb_membership_subscriptions enable row level security;
alter table public.cb_membership_payments enable row level security;

drop policy if exists "Anyone can read active membership plans" on public.cb_membership_plans;
create policy "Anyone can read active membership plans" on public.cb_membership_plans for select to anon,authenticated using (active=true);
drop policy if exists "Users can read own membership subscription" on public.cb_membership_subscriptions;
create policy "Users can read own membership subscription" on public.cb_membership_subscriptions for select to authenticated using ((select auth.uid())=user_id);
drop policy if exists "Users can read own membership payment requests" on public.cb_membership_payments;
create policy "Users can read own membership payment requests" on public.cb_membership_payments for select to authenticated using ((select auth.uid())=user_id);
drop policy if exists "Users can submit own membership payment requests" on public.cb_membership_payments;
create policy "Users can submit own membership payment requests" on public.cb_membership_payments for insert to authenticated with check (
  (select auth.uid())=user_id and status='pending' and reviewed_at is null
  and payment_method='upi'
  and ((plan_key='pro' and billing_period='monthly' and amount_inr=99)
    or (plan_key='pro' and billing_period='yearly' and amount_inr=999)
    or (plan_key='vip' and billing_period='monthly' and amount_inr=249))
);
grant select on public.cb_membership_plans to anon,authenticated;
grant select on public.cb_membership_subscriptions to authenticated;
grant select on public.cb_membership_payments to authenticated;
grant insert (user_id,plan_key,billing_period,amount_inr,payment_method,transaction_reference) on public.cb_membership_payments to authenticated;
revoke insert,update,delete on public.cb_membership_subscriptions from anon,authenticated;
revoke update,delete on public.cb_membership_payments from anon,authenticated;
revoke insert,update,delete on public.cb_membership_plans from anon,authenticated;