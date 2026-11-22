create or replace function public.cb_chat_set_display_name(p_name text)
returns void
language plpgsql
security definer
set search_path=public,pg_temp
as $$
declare v_me uuid:=auth.uid(); v_name text:=btrim(coalesce(p_name,''));
begin
 if v_me is null then raise exception 'Sign in to update your creator name'; end if;
 if length(v_name)<2 or length(v_name)>50 then raise exception 'Display name must be 2 to 50 characters'; end if;
 insert into public.profiles(id,display_name) values(v_me,v_name)
 on conflict(id) do update set display_name=excluded.display_name;
end;
$$;
revoke all on function public.cb_chat_set_display_name(text) from public,anon;
grant execute on function public.cb_chat_set_display_name(text) to authenticated;