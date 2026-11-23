alter table public.cb_campaign_submissions
  add column if not exists reviewer_note text;

create or replace function public.admin_creatorboost_pending_campaign_submissions_v2()
returns table(
  id uuid,
  campaign_id uuid,
  campaign_title text,
  user_id uuid,
  evidence text,
  submitted_at timestamptz,
  reward_points integer,
  remaining_budget integer,
  duplicate_count integer
)
language plpgsql
stable
security definer
set search_path to 'public','auth'
as $function$
begin
  if auth.uid() is null or not exists (
    select 1 from public.cb_task_reviewers r where r.user_id=auth.uid()
  ) then
    raise exception 'Admin permission required';
  end if;

  return query
  select s.id,s.campaign_id,c.title,s.user_id,s.evidence,s.submitted_at,
         s.reward_points,c.remaining_budget,
         (
           select count(*)::integer
           from public.cb_campaign_submissions other_s
           where other_s.campaign_id=s.campaign_id
             and other_s.id<>s.id
             and other_s.user_id<>s.user_id
             and lower(btrim(other_s.evidence))=lower(btrim(s.evidence))
         ) as duplicate_count
  from public.cb_campaign_submissions s
  join public.cb_campaigns c on c.id=s.campaign_id
  where s.status='pending'
  order by s.submitted_at asc;
end
$function$;

create or replace function public.review_creatorboost_campaign_submission_v2(
  p_submission_id uuid,
  p_approve boolean,
  p_reviewer_note text default null
)
returns integer
language plpgsql
security definer
set search_path to 'public','auth'
as $function$
declare
  v_s public.cb_campaign_submissions%rowtype;
  v_c public.cb_campaigns%rowtype;
  v_reward integer;
  v_note text := nullif(left(btrim(coalesce(p_reviewer_note,'')),1000),'');
begin
  if auth.uid() is null or not exists (
    select 1 from public.cb_task_reviewers r where r.user_id=auth.uid()
  ) then
    raise exception 'Admin permission required';
  end if;

  if length(coalesce(p_reviewer_note,''))>1000 then
    raise exception 'Reviewer note must be 1,000 characters or fewer';
  end if;

  select * into v_s
  from public.cb_campaign_submissions
  where id=p_submission_id
  for update;

  if not found then raise exception 'Campaign submission not found'; end if;
  if v_s.status<>'pending' then raise exception 'Submission has already been reviewed'; end if;

  select * into v_c
  from public.cb_campaigns
  where id=v_s.campaign_id
  for update;

  if not found then raise exception 'Campaign not found'; end if;
  v_reward:=v_s.reward_points;

  if not p_approve then
    if v_s.budget_reserved then
      update public.cb_campaigns
      set remaining_budget=remaining_budget+v_reward,updated_at=now()
      where id=v_c.id;
    end if;
    update public.cb_campaign_submissions
    set status='rejected',budget_reserved=false,reviewed_at=now(),
        reviewer_id=auth.uid(),reviewer_note=v_note
    where id=p_submission_id;
    return 0;
  end if;

  if v_c.status not in ('active','paused') then
    raise exception 'Campaign is not eligible for review; reserved reward remains protected';
  end if;

  if not v_s.budget_reserved then
    if v_c.remaining_budget<v_reward then
      raise exception 'Insufficient campaign budget; no points were paid';
    end if;
    update public.cb_campaigns
    set remaining_budget=remaining_budget-v_reward,updated_at=now()
    where id=v_c.id;
  end if;

  insert into public.cb_points_accounts(user_id,balance)
  values(v_s.user_id,v_reward)
  on conflict(user_id) do update
  set balance=public.cb_points_accounts.balance+excluded.balance,updated_at=now();

  insert into public.cb_points_ledger(user_id,submission_id,points,reason,entry_type,delta)
  values(v_s.user_id,null,v_reward,'Approved campaign reward: '||v_c.title,'campaign_reward',v_reward);

  update public.cb_campaign_submissions
  set status='approved',paid_points=v_reward,budget_reserved=false,
      reviewed_at=now(),reviewer_id=auth.uid(),reviewer_note=v_note
  where id=p_submission_id;

  return v_reward;
end
$function$;

revoke all on function public.admin_creatorboost_pending_campaign_submissions_v2() from public, anon;
grant execute on function public.admin_creatorboost_pending_campaign_submissions_v2() to authenticated;
revoke all on function public.review_creatorboost_campaign_submission_v2(uuid,boolean,text) from public, anon;
grant execute on function public.review_creatorboost_campaign_submission_v2(uuid,boolean,text) to authenticated;
