-- CreatorBoost paid mini-game unlocks. ₹20 = 2,000 points at the existing 100 points/₹1 wallet rate.
create table if not exists public.cb_game_unlocks (
  user_id uuid not null references auth.users(id) on delete cascade,
  game_id text not null check (game_id ~ '^[a-z0-9-]{2,60}$'),
  points_paid integer not null default 2000 check (points_paid = 2000),
  created_at timestamptz not null default now(),
  primary key (user_id, game_id)
);
alter table public.cb_game_unlocks enable row level security;
drop policy if exists "Users read own game unlocks" on public.cb_game_unlocks;
create policy "Users read own game unlocks" on public.cb_game_unlocks
  for select to authenticated using ((select auth.uid()) = user_id);
revoke all on public.cb_game_unlocks from anon, authenticated;
grant select on public.cb_game_unlocks to authenticated;

create or replace function public.purchase_creatorboost_game(p_game_id text)
returns table(game_id text, points_balance bigint, already_unlocked boolean)
language plpgsql security definer set search_path = public, auth as $$
declare v_uid uuid := auth.uid(); v_balance bigint;
begin
  if v_uid is null then raise exception 'Please sign in first'; end if;
  if p_game_id is distinct from 'tap-rush' then raise exception 'This game is not available to purchase yet'; end if;
  insert into public.cb_points_accounts(user_id,balance) values(v_uid,0) on conflict(user_id) do nothing;
  select a.balance into v_balance from public.cb_points_accounts a where a.user_id=v_uid for update;
  if exists(select 1 from public.cb_game_unlocks u where u.user_id=v_uid and u.game_id=p_game_id) then
    return query select p_game_id,v_balance,true; return;
  end if;
  if v_balance<2000 then raise exception 'Not enough points. This game costs 2,000 points (₹20).'; end if;
  update public.cb_points_accounts set balance=balance-2000,updated_at=now() where user_id=v_uid;
  insert into public.cb_game_unlocks(user_id,game_id,points_paid) values(v_uid,p_game_id,2000);
  insert into public.cb_points_ledger(user_id,submission_id,points,reason,entry_type,delta)
    values(v_uid,null,2000,'Game unlock: Tap Rush','game_purchase',-2000);
  select a.balance into v_balance from public.cb_points_accounts a where a.user_id=v_uid;
  return query select p_game_id,v_balance,false;
end $$;
revoke all on function public.purchase_creatorboost_game(text) from public,anon;
grant execute on function public.purchase_creatorboost_game(text) to authenticated;
