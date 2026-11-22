-- Add indexes for the remaining foreign keys identified by the Supabase advisor.
create index if not exists cb_campaign_submissions_reviewer_id_idx on public.cb_campaign_submissions(reviewer_id);
create index if not exists cb_campaign_submissions_user_id_idx on public.cb_campaign_submissions(user_id);
create index if not exists cb_service_orders_payment_request_id_idx on public.cb_service_orders(payment_request_id);
create index if not exists cb_withdrawal_requests_reviewer_id_idx on public.cb_withdrawal_requests(reviewer_id);

-- Keep direct user table reads limited to the authenticated user's own rows,
-- while avoiding per-row evaluation of auth.uid().
drop policy if exists "Creators read own campaign submissions" on public.cb_campaign_submissions;
create policy "Creators read own campaign submissions" on public.cb_campaign_submissions
for select to authenticated using ((select auth.uid()) = user_id);

drop policy if exists "Users read own campaigns" on public.cb_campaigns;
create policy "Users read own campaigns" on public.cb_campaigns
for select to authenticated using ((select auth.uid()) = user_id);

drop policy if exists "Users read own points account" on public.cb_points_accounts;
create policy "Users read own points account" on public.cb_points_accounts
for select to authenticated using ((select auth.uid()) = user_id);

drop policy if exists "Users read own points ledger" on public.cb_points_ledger;
create policy "Users read own points ledger" on public.cb_points_ledger
for select to authenticated using ((select auth.uid()) = user_id);

drop policy if exists "Users read own task submissions" on public.cb_task_submissions;
create policy "Users read own task submissions" on public.cb_task_submissions
for select to authenticated using ((select auth.uid()) = user_id);
