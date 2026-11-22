-- Secure referral codes and verified-invite rewards.
alter table public.profiles add column if not exists referral_code text;
update public.profiles
set referral_code='CB-'||upper(substr(replace(id::text,'-',''),1,8))
where referral_code is null or btrim(referral_code)='';
create unique index if not exists profiles_referral_code_unique
  on public.profiles(referral_code);

create table if not exists public.cb_referrals (
  id uuid primary key default gen_random_uuid(),
  referrer_id uuid not null references auth.users(id) on delete cascade,
  referred_user_id uuid not null unique references auth.users(id) on delete cascade,
  points integer not null default 50 check(points=50),
  status text not null default 'pending' check(status in ('pending','credited')),
  created_at timestamptz not null default now(),
  credited_at timestamptz,
  constraint cb_referrals_not_self check(referrer_id<>referred_user_id)
);
create index if not exists cb_referrals_referrer_created_idx
  on public.cb_referrals(referrer_id,created_at desc);
alter table public.cb_referrals enable row level security;
revoke all on public.cb_referrals from public,anon,authenticated;

create or replace function public.process_creatorboost_referral(p_referred_user uuid)
returns integer
language plpgsql security definer set search_path=public,auth as $$
declare v_ref public.cb_referrals%rowtype; v_confirmed timestamptz;
begin
  select email_confirmed_at into v_confirmed from auth.users where id=p_referred_user;
  if v_confirmed is null then return 0; end if;
  select * into v_ref from public.cb_referrals
    where referred_user_id=p_referred_user for update;
  if not found or v_ref.status<>'pending' then return 0; end if;
  insert into public.cb_points_accounts(user_id,balance)
    values(v_ref.referrer_id,v_ref.points)
    on conflict(user_id) do update
      set balance=public.cb_points_accounts.balance+excluded.balance,updated_at=now();
  insert into public.cb_points_ledger(user_id,submission_id,points,reason,entry_type,delta)
    values(v_ref.referrer_id,null,v_ref.points,'Verified creator referral','referral_reward',v_ref.points);
  update public.cb_referrals set status='credited',credited_at=now() where id=v_ref.id;
  return v_ref.points;
end $$;
revoke all on function public.process_creatorboost_referral(uuid) from public,anon,authenticated;

create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path=''
as $function$
declare
  v_code text;
  v_referrer uuid;
begin
  v_code := 'CB-'||upper(substr(replace(new.id::text,'-',''),1,8));
  insert into public.profiles(id,display_name,referral_code)
    values(new.id,new.raw_user_meta_data->>'display_name',v_code)
    on conflict(id) do update set
      display_name=coalesce(excluded.display_name,public.profiles.display_name),
      referral_code=coalesce(public.profiles.referral_code,excluded.referral_code);

  if nullif(btrim(new.raw_user_meta_data->>'referred_by_code'),'') is not null then
    select id into v_referrer from public.profiles
      where referral_code=upper(btrim(new.raw_user_meta_data->>'referred_by_code'))
        and id<>new.id;
    if v_referrer is not null then
      insert into public.cb_referrals(referrer_id,referred_user_id)
        values(v_referrer,new.id)
        on conflict(referred_user_id) do nothing;
      if new.email_confirmed_at is not null then
        perform public.process_creatorboost_referral(new.id);
      end if;
    end if;
  end if;
  return new;
end;
$function$;
revoke all on function public.handle_new_user() from public,anon,authenticated;

create or replace function public.award_creatorboost_referral_after_confirmation()
returns trigger
language plpgsql security definer set search_path=public,auth as $$
begin
  if old.email_confirmed_at is null and new.email_confirmed_at is not null then
    perform public.process_creatorboost_referral(new.id);
  end if;
  return new;
end $$;
revoke all on function public.award_creatorboost_referral_after_confirmation() from public,anon,authenticated;
drop trigger if exists cb_award_referral_after_confirmation on auth.users;
create trigger cb_award_referral_after_confirmation
after update of email_confirmed_at on auth.users
for each row execute function public.award_creatorboost_referral_after_confirmation();

create or replace function public.my_creatorboost_referral_summary()
returns table(referral_code text,total_invites bigint,credited_invites bigint,pending_invites bigint,points_earned bigint)
language plpgsql stable security definer set search_path=public,auth as $$
begin
  if auth.uid() is null then raise exception 'Please sign in first'; end if;
  return query
  select p.referral_code,
    count(r.id),
    count(r.id) filter(where r.status='credited'),
    count(r.id) filter(where r.status='pending'),
    coalesce(sum(r.points) filter(where r.status='credited'),0)
  from public.profiles p
  left join public.cb_referrals r on r.referrer_id=p.id
  where p.id=auth.uid()
  group by p.referral_code;
end $$;
revoke all on function public.my_creatorboost_referral_summary() from public,anon;
grant execute on function public.my_creatorboost_referral_summary() to authenticated;
