create or replace function public.my_creatorboost_campaign_submissions()
returns table(
  id uuid,
  campaign_title text,
  status text,
  evidence text,
  submitted_at timestamptz,
  reward_points integer,
  paid_points integer,
  reviewer_note text
)
language plpgsql
stable
security definer
set search_path to 'public','auth'
as $function$
begin
  if auth.uid() is null then raise exception 'Please sign in first'; end if;
  return query
  select s.id,c.title,s.status,s.evidence,s.submitted_at,s.reward_points,
         s.paid_points,s.reviewer_note
  from public.cb_campaign_submissions s
  join public.cb_campaigns c on c.id=s.campaign_id
  where s.user_id=auth.uid()
  order by s.submitted_at desc
  limit 50;
end
$function$;

revoke all on function public.my_creatorboost_campaign_submissions() from public, anon;
grant execute on function public.my_creatorboost_campaign_submissions() to authenticated;
