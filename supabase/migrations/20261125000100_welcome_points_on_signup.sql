-- Award the 50-point welcome bonus exactly once when a new auth user is created.
-- Existing users are intentionally not backfilled.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_code text;
  v_referrer uuid;
  v_wallet_user uuid;
begin
  v_code := 'CB-' || upper(substr(replace(new.id::text, '-', ''), 1, 8));

  insert into public.profiles(id, display_name, referral_code)
  values (new.id, new.raw_user_meta_data->>'display_name', v_code)
  on conflict (id) do update set
    display_name = coalesce(excluded.display_name, public.profiles.display_name),
    referral_code = coalesce(public.profiles.referral_code, excluded.referral_code);

  -- Create the initial wallet and ledger credit atomically and idempotently.
  insert into public.cb_points_accounts(user_id, balance)
  values (new.id, 50)
  on conflict (user_id) do nothing
  returning user_id into v_wallet_user;

  if v_wallet_user is not null then
    insert into public.cb_points_ledger(user_id, submission_id, points, reason, entry_type, delta)
    values (new.id, null, 50, 'Welcome bonus', 'welcome_bonus', 50);
  end if;

  if nullif(btrim(new.raw_user_meta_data->>'referred_by_code'), '') is not null then
    select id into v_referrer
    from public.profiles
    where referral_code = upper(btrim(new.raw_user_meta_data->>'referred_by_code'))
      and id <> new.id;

    if v_referrer is not null then
      insert into public.cb_referrals(referrer_id, referred_user_id)
      values (v_referrer, new.id)
      on conflict (referred_user_id) do nothing;

      if new.email_confirmed_at is not null then
        perform public.process_creatorboost_referral(new.id);
      end if;
    end if;
  end if;

  return new;
end;
$function$;
