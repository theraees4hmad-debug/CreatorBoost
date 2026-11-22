-- Admin-only pending task review queue for CreatorBoost.
create or replace function public.admin_creatorboost_pending_submissions()
returns table(id uuid,user_id uuid,task_id text,title text,evidence text,submitted_at timestamptz)
language plpgsql stable security definer set search_path=public,auth as $$
begin
 if auth.uid() is null or coalesce(auth.jwt()->'app_metadata'->>'role','') <> 'admin' then
   raise exception 'Admin permission required';
 end if;
 return query
 select s.id,s.user_id,s.task_id,c.title,s.evidence,s.submitted_at
 from public.cb_task_submissions s
 join public.cb_task_catalog c on c.task_id=s.task_id
 where s.status='pending'
 order by s.submitted_at asc;
end $$;
revoke all on function public.admin_creatorboost_pending_submissions() from public,anon;
grant execute on function public.admin_creatorboost_pending_submissions() to authenticated;
