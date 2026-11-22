-- CreatorBoost secure points transfers (points only; never cash).
-- Apply after migrations 001-009, after reviewing/backing up the production database.

create table if not exists public.cb_point_transfers (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references auth.users(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  points integer not null check (points between 1 and 100000),
  idempotency_key uuid not null,
  created_at timestamptz not null default now(),
  constraint cb_point_transfers_not_self check (sender_id <> recipient_id),
  constraint cb_point_transfers_sender_request_unique unique(sender_id,idempotency_key)
);
create index if not exists cb_point_transfers_sender_created_idx
  on public.cb_point_transfers(sender_id,created_at desc);
create index if not exists cb_point_transfers_recipient_created_idx
  on public.cb_point_transfers(recipient_id,created_at desc);
alter table public.cb_point_transfers enable row level security;
revoke all on public.cb_point_transfers from anon,authenticated;

create or replace function public.transfer_creatorboost_points(
  p_recipient_email text,
  p_points integer,
  p_idempotency_key uuid
) returns uuid
language plpgsql security definer set search_path=public,auth as $$
declare
  v_sender uuid := auth.uid();
  v_recipient uuid;
  v_transfer uuid;
  v_existing uuid;
begin
  if v_sender is null then raise exception 'Please sign in first'; end if;
  if p_points is null or p_points < 1 or p_points > 100000 then
    raise exception 'Transfer must be between 1 and 100,000 points';
  end if;
  if p_idempotency_key is null then raise exception 'Transfer request key is required'; end if;
  if length(trim(coalesce(p_recipient_email,''))) not between 5 and 254
     or position('@' in p_recipient_email)=0 then
    raise exception 'Enter the recipient account email';
  end if;

  select id into v_recipient from auth.users
    where lower(email)=lower(trim(p_recipient_email)) and email_confirmed_at is not null;
  if v_recipient is null or v_recipient=v_sender then
    raise exception 'Recipient account not found or not eligible';
  end if;

  select id into v_existing from public.cb_point_transfers
    where sender_id=v_sender and idempotency_key=p_idempotency_key;
  if v_existing is not null then return v_existing; end if;

  insert into public.cb_points_accounts(user_id,balance)
    values(v_sender,0),(v_recipient,0) on conflict(user_id) do nothing;

  perform 1 from public.cb_points_accounts
    where user_id in (v_sender,v_recipient)
    order by user_id for update;

  select id into v_existing from public.cb_point_transfers
    where sender_id=v_sender and idempotency_key=p_idempotency_key;
  if v_existing is not null then return v_existing; end if;

  update public.cb_points_accounts set balance=balance-p_points,updated_at=now()
    where user_id=v_sender and balance>=p_points;
  if not found then raise exception 'Not enough points in your wallet'; end if;

  update public.cb_points_accounts set balance=balance+p_points,updated_at=now()
    where user_id=v_recipient;

  insert into public.cb_point_transfers(sender_id,recipient_id,points,idempotency_key)
    values(v_sender,v_recipient,p_points,p_idempotency_key)
    returning id into v_transfer;

  insert into public.cb_points_ledger(user_id,submission_id,points,reason,entry_type,delta)
    values
      (v_sender,null,p_points,'Points sent to another CreatorBoost user','point_transfer',-p_points),
      (v_recipient,null,p_points,'Points received from a CreatorBoost user','point_transfer',p_points);

  return v_transfer;
end $$;

revoke all on function public.transfer_creatorboost_points(text,integer,uuid) from public,anon;
grant execute on function public.transfer_creatorboost_points(text,integer,uuid) to authenticated;

create or replace function public.my_creatorboost_transfers()
returns table(id uuid,direction text,points integer,created_at timestamptz)
language sql stable security definer set search_path=public,auth as $$
  select t.id,
    case when t.sender_id=auth.uid() then 'sent' else 'received' end,
    t.points,t.created_at
  from public.cb_point_transfers t
  where t.sender_id=auth.uid() or t.recipient_id=auth.uid()
  order by t.created_at desc limit 100
$$;
revoke all on function public.my_creatorboost_transfers() from public,anon;
grant execute on function public.my_creatorboost_transfers() to authenticated;
