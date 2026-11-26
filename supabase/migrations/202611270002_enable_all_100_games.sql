create or replace function public.purchase_creatorboost_game(p_game_id text)
returns table(game_id text, points_balance bigint, already_unlocked boolean)
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_balance bigint;
begin
  if v_uid is null then raise exception 'Please sign in first'; end if;
  if p_game_id is null or not (p_game_id = any (array['tap-rush','snake-rush','flappy-challenge','stack-tower','color-switch','brick-breaker','bounce-ball','endless-runner','space-shooter','fruit-slice','2048','sudoku','number-merge','word-guess','memory-match','minesweeper','block-blast','maze-escape','jigsaw-puzzle','math-master','reaction-speed','speed-tap','color-reflex','quick-draw','hit-the-target','dont-tap-red','lightning-reflex','stop-at-10','fast-fingers','reflex-challenge','bubble-shooter','whack-a-mole','mini-golf','paper-toss','target-toss','coin-catcher','balloon-pop','jump-quest','fishing-frenzy','mini-basketball','tic-tac-toe','chess','checkers','connect-four','rock-paper-scissors','battleship','tower-defense','reversi','dots-and-boxes','four-in-a-row','traffic-racer','car-dodge','bike-rush','drift-challenge','parking-master','lane-switch','speed-racer','monster-truck','highway-escape','time-trial','simon-says','sequence-memory','picture-pairs','remember-pattern','sound-memory','flash-cards','color-memory','number-recall','pattern-master','hidden-object','word-search','hangman','crossword-mini','spell-master','word-connect','anagram-challenge','missing-letters','word-scramble','vocabulary-quiz','guess-the-word','lucky-blocks','dragon-jump','monster-escape','castle-defender','zombie-survival','robot-runner','space-mission','treasure-maze','magic-tiles','ultimate-tap-challenge','bubble-pop','orbit-dash','pixel-climber','neon-pong','mini-quiz','shape-shift','goal-rush','perfect-balance','neon-drift','astro-dodge']::text[])) then
    raise exception 'This game is not in the CreatorBoost catalog';
  end if;
  insert into public.cb_points_accounts(user_id,balance) values(v_uid,0) on conflict(user_id) do nothing;
  select a.balance into v_balance from public.cb_points_accounts a where a.user_id=v_uid for update;
  if exists(select 1 from public.cb_game_unlocks u where u.user_id=v_uid and u.game_id=p_game_id) then
    return query select p_game_id,v_balance,true; return;
  end if;
  if v_balance<2000 then raise exception 'Not enough points. This game costs 2,000 points (₹20).'; end if;
  update public.cb_points_accounts set balance=balance-2000,updated_at=now() where user_id=v_uid;
  insert into public.cb_game_unlocks(user_id,game_id,points_paid) values(v_uid,p_game_id,2000);
  insert into public.cb_points_ledger(user_id,submission_id,points,reason,entry_type,delta)
    values(v_uid,null,2000,'Game unlock: ' || p_game_id,'game_purchase',-2000);
  select a.balance into v_balance from public.cb_points_accounts a where a.user_id=v_uid;
  return query select p_game_id,v_balance,false;
end; $$;
revoke all on function public.purchase_creatorboost_game(text) from public,anon;
grant execute on function public.purchase_creatorboost_game(text) to authenticated;