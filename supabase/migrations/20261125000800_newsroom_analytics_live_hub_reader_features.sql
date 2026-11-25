-- CreatorBoost newsroom analytics, Live Hub, reader features and admin access.
create table if not exists public.cb_newsroom_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  granted_at timestamptz not null default now(),
  granted_by uuid references auth.users(id)
);
alter table public.cb_newsroom_admins enable row level security;
create policy "newsroom admins can read own role" on public.cb_newsroom_admins for select to authenticated using (user_id=(select auth.uid()));

create table if not exists public.cb_newsroom_events (
  id uuid primary key default gen_random_uuid(),
  article_id uuid references public.cb_public_articles(id) on delete set null,
  event_type text not null check(event_type in ('page_view','article_view','share_click','search','bookmark')),
  session_key text not null check(length(session_key) between 12 and 80),
  page_path text not null default '/',
  referrer_host text,
  created_at timestamptz not null default now()
);
create index if not exists cb_newsroom_events_created_idx on public.cb_newsroom_events(created_at desc);
create index if not exists cb_newsroom_events_article_idx on public.cb_newsroom_events(article_id,created_at desc);
alter table public.cb_newsroom_events enable row level security;
create policy "public can record newsroom events" on public.cb_newsroom_events for insert to anon,authenticated with check(length(page_path) between 1 and 300 and (referrer_host is null or length(referrer_host)<=160));
create policy "newsroom admins can read analytics" on public.cb_newsroom_events for select to authenticated using(exists(select 1 from public.cb_newsroom_admins a where a.user_id=(select auth.uid())));

create table if not exists public.cb_reader_bookmarks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  article_id uuid not null references public.cb_public_articles(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique(user_id,article_id)
);
alter table public.cb_reader_bookmarks enable row level security;
create policy "read own bookmarks" on public.cb_reader_bookmarks for select to authenticated using(user_id=(select auth.uid()));
create policy "save own bookmarks" on public.cb_reader_bookmarks for insert to authenticated with check(user_id=(select auth.uid()));
create policy "remove own bookmarks" on public.cb_reader_bookmarks for delete to authenticated using(user_id=(select auth.uid()));

create table if not exists public.cb_newsletter_subscribers (
  id uuid primary key default gen_random_uuid(),
  email text not null unique check(email=lower(trim(email)) and email ~* '^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$'),
  consent boolean not null default false check(consent=true),
  source text not null default 'newsroom',
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.cb_newsletter_subscribers enable row level security;
create policy "public can subscribe to newsletter" on public.cb_newsletter_subscribers for insert to anon,authenticated with check(consent=true and source='newsroom');
create policy "newsroom admins can manage newsletter" on public.cb_newsletter_subscribers for all to authenticated using(exists(select 1 from public.cb_newsroom_admins a where a.user_id=(select auth.uid()))) with check(exists(select 1 from public.cb_newsroom_admins a where a.user_id=(select auth.uid())));

create table if not exists public.cb_live_events (
  id uuid primary key default gen_random_uuid(),
  title text not null check(length(trim(title)) between 3 and 180),
  category text not null default 'Gaming' check(category in ('Gaming','Streaming','Esports','YouTube','Creators')),
  description text not null default '',
  starts_at timestamptz not null,
  ends_at timestamptz,
  event_url text,
  image_url text,
  status text not null default 'draft' check(status in ('draft','published','cancelled')),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(ends_at is null or ends_at>=starts_at),
  check(event_url is null or event_url ~* '^https?://'),
  check(image_url is null or image_url ~* '^https?://')
);
create index if not exists cb_live_events_start_idx on public.cb_live_events(starts_at) where status='published';
alter table public.cb_live_events enable row level security;
create policy "public can view published live events" on public.cb_live_events for select to anon,authenticated using(status='published');
create policy "newsroom admins manage live events" on public.cb_live_events for all to authenticated using(exists(select 1 from public.cb_newsroom_admins a where a.user_id=(select auth.uid()))) with check(exists(select 1 from public.cb_newsroom_admins a where a.user_id=(select auth.uid())));

create policy "newsroom admins can read all articles" on public.cb_public_articles for select to authenticated using(exists(select 1 from public.cb_newsroom_admins a where a.user_id=(select auth.uid())));
create policy "newsroom admins can insert articles" on public.cb_public_articles for insert to authenticated with check(exists(select 1 from public.cb_newsroom_admins a where a.user_id=(select auth.uid())));
create policy "newsroom admins can update articles" on public.cb_public_articles for update to authenticated using(exists(select 1 from public.cb_newsroom_admins a where a.user_id=(select auth.uid()))) with check(exists(select 1 from public.cb_newsroom_admins a where a.user_id=(select auth.uid())));
create policy "newsroom admins can delete articles" on public.cb_public_articles for delete to authenticated using(exists(select 1 from public.cb_newsroom_admins a where a.user_id=(select auth.uid())));

grant select on public.cb_newsroom_admins to authenticated;
grant insert on public.cb_newsroom_events to anon,authenticated;
grant select on public.cb_newsroom_events to authenticated;
grant select,insert,delete on public.cb_reader_bookmarks to authenticated;
grant insert on public.cb_newsletter_subscribers to anon,authenticated;
grant select,update,delete on public.cb_newsletter_subscribers to authenticated;
grant select on public.cb_live_events to anon,authenticated;
grant insert,update,delete on public.cb_live_events to authenticated;


-- Align policies to avoid overlapping permissive checks and index foreign keys.
create index if not exists cb_live_events_created_by_idx on public.cb_live_events(created_by);
create index if not exists cb_newsroom_admins_granted_by_idx on public.cb_newsroom_admins(granted_by);
create index if not exists cb_reader_bookmarks_article_id_idx on public.cb_reader_bookmarks(article_id);
drop policy if exists "public can view published live events" on public.cb_live_events;
drop policy if exists "newsroom admins manage live events" on public.cb_live_events;
create policy "public and newsroom admins can view live events" on public.cb_live_events for select to anon,authenticated
using(status='published' or exists(select 1 from public.cb_newsroom_admins a where a.user_id=(select auth.uid())));
create policy "newsroom admins can insert live events" on public.cb_live_events for insert to authenticated
with check(exists(select 1 from public.cb_newsroom_admins a where a.user_id=(select auth.uid())));
create policy "newsroom admins can update live events" on public.cb_live_events for update to authenticated
using(exists(select 1 from public.cb_newsroom_admins a where a.user_id=(select auth.uid())))
with check(exists(select 1 from public.cb_newsroom_admins a where a.user_id=(select auth.uid())));
create policy "newsroom admins can delete live events" on public.cb_live_events for delete to authenticated
using(exists(select 1 from public.cb_newsroom_admins a where a.user_id=(select auth.uid())));
drop policy if exists "newsroom admins can manage newsletter" on public.cb_newsletter_subscribers;
create policy "newsroom admins can read newsletter" on public.cb_newsletter_subscribers for select to authenticated
using(exists(select 1 from public.cb_newsroom_admins a where a.user_id=(select auth.uid())));
create policy "newsroom admins can update newsletter" on public.cb_newsletter_subscribers for update to authenticated
using(exists(select 1 from public.cb_newsroom_admins a where a.user_id=(select auth.uid())))
with check(exists(select 1 from public.cb_newsroom_admins a where a.user_id=(select auth.uid())));
create policy "newsroom admins can delete newsletter" on public.cb_newsletter_subscribers for delete to authenticated
using(exists(select 1 from public.cb_newsroom_admins a where a.user_id=(select auth.uid())));
drop policy if exists "Public can read published CreatorBoost articles" on public.cb_public_articles;
create policy "Public and admins can read CreatorBoost articles" on public.cb_public_articles for select to anon,authenticated
using(status='published' or exists(select 1 from public.cb_newsroom_admins a where a.user_id=(select auth.uid())));
drop policy if exists "newsroom admins can read all articles" on public.cb_public_articles;
