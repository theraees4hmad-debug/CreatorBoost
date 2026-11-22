-- Trigger-only SECURITY DEFINER functions must not be callable through the public API.
revoke execute on function public.handle_new_user() from public, anon;
revoke execute on function public.apply_creatorboost_verified_task_milestone() from public, anon;

-- Cover foreign keys to avoid avoidable table scans during joins/deletes.
create index if not exists campaigns_owner_id_idx on public.campaigns(owner_id);
create index if not exists cb_campaigns_user_id_idx on public.cb_campaigns(user_id);
create index if not exists cb_payment_requests_reviewer_id_idx on public.cb_payment_requests(reviewer_id);
create index if not exists cb_points_ledger_user_id_idx on public.cb_points_ledger(user_id);
create index if not exists cb_task_submissions_reviewer_id_idx on public.cb_task_submissions(reviewer_id);
create index if not exists cb_task_submissions_task_id_idx on public.cb_task_submissions(task_id);
create index if not exists creator_profiles_user_id_idx on public.creator_profiles(user_id);
create index if not exists deposits_user_id_idx on public.deposits(user_id);
create index if not exists point_ledger_user_id_idx on public.point_ledger(user_id);
create index if not exists tasks_campaign_id_idx on public.tasks(campaign_id);
create index if not exists tasks_participant_id_idx on public.tasks(participant_id);
create index if not exists withdrawals_user_id_idx on public.withdrawals(user_id);