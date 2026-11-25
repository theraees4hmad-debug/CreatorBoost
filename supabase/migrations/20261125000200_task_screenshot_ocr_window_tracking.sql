alter table public.cb_task_submissions
  add column if not exists screenshot_path text,
  add column if not exists ocr_text text,
  add column if not exists window_tracking jsonb not null default '{}'::jsonb;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('cb-task-evidence', 'cb-task-evidence', false, 8388608, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public=false, file_size_limit=8388608, allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists "CB task evidence upload own" on storage.objects;
create policy "CB task evidence upload own" on storage.objects
for insert to authenticated
with check (bucket_id='cb-task-evidence' and (storage.foldername(name))[1]=auth.uid()::text);

drop policy if exists "CB task evidence read own or reviewer" on storage.objects;
create policy "CB task evidence read own or reviewer" on storage.objects
for select to authenticated
using (bucket_id='cb-task-evidence' and ((storage.foldername(name))[1]=auth.uid()::text or exists(select 1 from public.cb_task_reviewers r where r.user_id=auth.uid())));

create or replace function public.submit_creatorboost_task_evidence(p_task_id text,p_evidence text,p_screenshot_path text,p_ocr_text text,p_window_tracking jsonb)
returns uuid language plpgsql security definer set search_path=''
as $$
declare v_id uuid; v_uid uuid:=auth.uid();
begin
 if v_uid is null then raise exception 'Please sign in first'; end if;
 if p_evidence is null or length(btrim(p_evidence))<3 or length(p_evidence)>2000 then raise exception 'Please provide a valid evidence description'; end if;
 if p_screenshot_path is null or split_part(p_screenshot_path,'/',1)<>v_uid::text or not exists(select 1 from storage.objects o where o.bucket_id='cb-task-evidence' and o.name=p_screenshot_path) then raise exception 'Screenshot upload could not be verified'; end if;
 if coalesce(length(p_ocr_text),0)>12000 then raise exception 'OCR text is too long'; end if;
 if p_window_tracking is null or jsonb_typeof(p_window_tracking)<>'object' or pg_column_size(p_window_tracking)>8192 then raise exception 'Window activity summary is invalid'; end if;
 if not exists(select 1 from public.cb_task_catalog c where c.task_id=p_task_id and c.active) then raise exception 'This task is unavailable'; end if;
 insert into public.cb_task_submissions(user_id,task_id,evidence,screenshot_path,ocr_text,window_tracking)
 values(v_uid,p_task_id,btrim(p_evidence),p_screenshot_path,coalesce(p_ocr_text,''),p_window_tracking) returning id into v_id;
 return v_id;
exception when unique_violation then raise exception 'You have already submitted this task';
end;
$$;
revoke all on function public.submit_creatorboost_task_evidence(text,text,text,text,jsonb) from public,anon;
grant execute on function public.submit_creatorboost_task_evidence(text,text,text,text,jsonb) to authenticated;

drop function if exists public.admin_creatorboost_pending_submissions();
create function public.admin_creatorboost_pending_submissions()
returns table(id uuid,user_id uuid,task_id text,title text,evidence text,submitted_at timestamptz,screenshot_path text,ocr_text text,window_tracking jsonb)
language plpgsql stable security definer set search_path=''
as $$
begin
 if auth.uid() is null or not exists(select 1 from public.cb_task_reviewers r where r.user_id=auth.uid()) then raise exception 'Admin permission required'; end if;
 return query select s.id,s.user_id,s.task_id,c.title,s.evidence,s.submitted_at,s.screenshot_path,s.ocr_text,s.window_tracking
 from public.cb_task_submissions s join public.cb_task_catalog c on c.task_id=s.task_id where s.status='pending' order by s.submitted_at asc;
end;
$$;
revoke all on function public.admin_creatorboost_pending_submissions() from public,anon;
grant execute on function public.admin_creatorboost_pending_submissions() to authenticated;
