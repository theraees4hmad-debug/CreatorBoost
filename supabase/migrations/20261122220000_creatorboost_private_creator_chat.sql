create table public.cb_conversations (
  id uuid primary key default gen_random_uuid(),
  user_a uuid not null references auth.users(id) on delete cascade,
  user_b uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint cb_conversations_distinct_users check (user_a <> user_b),
  constraint cb_conversations_sorted_users check (user_a < user_b),
  constraint cb_conversations_pair_unique unique (user_a,user_b)
);
create table public.cb_messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.cb_conversations(id) on delete cascade,
  sender_id uuid not null references auth.users(id) on delete cascade,
  body text not null check (length(btrim(body)) between 1 and 2000),
  created_at timestamptz not null default now()
);
create index cb_messages_conversation_created_idx on public.cb_messages(conversation_id,created_at desc);
create index cb_conversations_user_a_idx on public.cb_conversations(user_a);
create index cb_conversations_user_b_idx on public.cb_conversations(user_b);
alter table public.cb_conversations enable row level security;
alter table public.cb_messages enable row level security;
revoke all on public.cb_conversations, public.cb_messages from anon, authenticated;
grant select on public.cb_conversations to authenticated;
grant select, insert on public.cb_messages to authenticated;
create policy "chat participants can read conversations" on public.cb_conversations
for select to authenticated using ((select auth.uid())=user_a or (select auth.uid())=user_b);
create policy "chat participants can read messages" on public.cb_messages
for select to authenticated using (exists (
 select 1 from public.cb_conversations c
 where c.id=conversation_id and ((select auth.uid())=c.user_a or (select auth.uid())=c.user_b)
));
create policy "chat participants can send messages" on public.cb_messages
for insert to authenticated with check (
 sender_id=(select auth.uid()) and exists (
  select 1 from public.cb_conversations c
  where c.id=conversation_id and ((select auth.uid())=c.user_a or (select auth.uid())=c.user_b)
 )
);
create or replace function public.cb_chat_search_users(p_query text)
returns table(user_id uuid, display_name text)
language sql stable security definer
set search_path=public,pg_temp
as $$
 select p.id, coalesce(nullif(btrim(p.display_name),''),'Creator')
 from public.profiles p
 where auth.uid() is not null
   and p.id <> auth.uid()
   and length(btrim(coalesce(p_query,''))) >= 2
   and coalesce(p.display_name,'') ilike '%' || btrim(p_query) || '%'
 order by p.display_name
 limit 20;
$$;
create or replace function public.cb_chat_start(p_recipient uuid)
returns uuid
language plpgsql security definer
set search_path=public,pg_temp
as $$
declare v_me uuid := auth.uid(); v_id uuid;
begin
 if v_me is null then raise exception 'Sign in to start a chat'; end if;
 if p_recipient is null or p_recipient=v_me then raise exception 'Choose another creator'; end if;
 if not exists(select 1 from public.profiles where id=p_recipient) then raise exception 'Creator not found'; end if;
 insert into public.cb_conversations(user_a,user_b)
 values(least(v_me,p_recipient),greatest(v_me,p_recipient))
 on conflict(user_a,user_b) do update set user_a=excluded.user_a
 returning id into v_id;
 return v_id;
end;
$$;
create or replace function public.cb_chat_my_conversations()
returns table(conversation_id uuid, other_user_id uuid, other_name text, last_message text, last_message_at timestamptz)
language sql stable security definer
set search_path=public,pg_temp
as $$
 select c.id,
        case when c.user_a=auth.uid() then c.user_b else c.user_a end,
        coalesce(nullif(btrim(p.display_name),''),'Creator'),
        m.body,m.created_at
 from public.cb_conversations c
 join public.profiles p on p.id=case when c.user_a=auth.uid() then c.user_b else c.user_a end
 left join lateral (
   select body,created_at from public.cb_messages
   where conversation_id=c.id order by created_at desc limit 1
 ) m on true
 where auth.uid() is not null and (c.user_a=auth.uid() or c.user_b=auth.uid())
 order by coalesce(m.created_at,c.created_at) desc;
$$;
revoke all on function public.cb_chat_search_users(text) from public,anon;
revoke all on function public.cb_chat_start(uuid) from public,anon;
revoke all on function public.cb_chat_my_conversations() from public,anon;
grant execute on function public.cb_chat_search_users(text) to authenticated;
grant execute on function public.cb_chat_start(uuid) to authenticated;
grant execute on function public.cb_chat_my_conversations() to authenticated;
do $$
begin
 if exists(select 1 from pg_publication where pubname='supabase_realtime')
    and not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='cb_messages') then
   alter publication supabase_realtime add table public.cb_messages;
 end if;
end $$;