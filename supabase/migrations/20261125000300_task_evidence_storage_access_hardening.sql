create or replace function public.cb_is_task_reviewer()
returns boolean language sql stable security definer set search_path=''
as $$ select auth.uid() is not null and exists(select 1 from public.cb_task_reviewers r where r.user_id=auth.uid()); $$;
revoke all on function public.cb_is_task_reviewer() from public,anon;
grant execute on function public.cb_is_task_reviewer() to authenticated;

drop policy if exists "CB task evidence read own or reviewer" on storage.objects;
create policy "CB task evidence read own or reviewer" on storage.objects
for select to authenticated
using (bucket_id='cb-task-evidence' and ((storage.foldername(name))[1]=auth.uid()::text or public.cb_is_task_reviewer()));

drop policy if exists "CB task evidence delete own" on storage.objects;
create policy "CB task evidence delete own" on storage.objects
for delete to authenticated
using (bucket_id='cb-task-evidence' and (storage.foldername(name))[1]=auth.uid()::text);
