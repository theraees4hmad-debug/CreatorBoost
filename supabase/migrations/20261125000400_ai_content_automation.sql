-- CreatorBoost AI content automation foundation. Additive only; existing wallet/campaign tables are untouched.
create table if not exists public.cb_content_settings (
  user_id uuid primary key references auth.users(id) on delete cascade,
  brand_name text not null default '',
  niche text not null default '',
  target_audience text not null default '',
  tone text not null default 'energetic',
  language text not null default 'English',
  timezone text not null default 'Asia/Kolkata',
  generation_enabled boolean not null default false,
  review_before_publish boolean not null default true,
  daily_article_limit integer not null default 1 check (daily_article_limit between 0 and 20),
  daily_social_limit integer not null default 3 check (daily_social_limit between 0 and 50),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.cb_content_schedules (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  content_type text not null check (content_type in ('article','social')),
  platform text not null check (platform in ('website','wordpress','x','facebook','instagram','tiktok','youtube')),
  topic_prompt text not null default '',
  publish_time time not null default '10:00',
  timezone text not null default 'Asia/Kolkata',
  frequency text not null default 'daily' check (frequency in ('daily','weekdays','weekly')),
  enabled boolean not null default false,
  next_run_at timestamptz,
  last_run_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists cb_content_schedules_due_idx
  on public.cb_content_schedules (enabled, next_run_at) where enabled = true;
create index if not exists cb_content_schedules_user_idx
  on public.cb_content_schedules (user_id, created_at desc);

create table if not exists public.cb_content_items (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  content_type text not null check (content_type in ('article','social')),
  platform text not null check (platform in ('website','wordpress','x','facebook','instagram','tiktok','youtube')),
  topic text not null default '',
  title text not null default '',
  body text not null,
  excerpt text not null default '',
  hashtags text[] not null default '{}',
  seo_title text not null default '',
  seo_description text not null default '',
  status text not null default 'draft' check (status in ('draft','review','queued','publishing','published','failed')),
  scheduled_at timestamptz,
  published_at timestamptz,
  provider_post_id text,
  idempotency_key uuid unique default gen_random_uuid(),
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists cb_content_items_user_created_idx
  on public.cb_content_items (user_id, created_at desc);
create index if not exists cb_content_items_publish_due_idx
  on public.cb_content_items (status, scheduled_at) where status = 'queued';

create table if not exists public.cb_content_connections (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  platform text not null check (platform in ('wordpress','x','facebook','instagram','tiktok','youtube')),
  account_id text not null,
  account_name text not null default '',
  site_url text,
  access_token_ciphertext text,
  refresh_token_ciphertext text,
  token_expires_at timestamptz,
  scopes text[] not null default '{}',
  status text not null default 'connected' check (status in ('connected','expired','revoked','error')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, platform, account_id)
);

create table if not exists public.cb_content_publications (
  id uuid primary key default gen_random_uuid(),
  content_item_id uuid not null references public.cb_content_items(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  platform text not null,
  status text not null check (status in ('pending','published','failed','skipped')),
  provider_post_id text,
  response_data jsonb not null default '{}'::jsonb,
  error_message text,
  attempts integer not null default 0,
  attempted_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (content_item_id, platform)
);
create index if not exists cb_content_publications_user_idx
  on public.cb_content_publications (user_id, attempted_at desc);

create table if not exists public.cb_content_metrics (
  id uuid primary key default gen_random_uuid(),
  publication_id uuid not null references public.cb_content_publications(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  captured_at timestamptz not null default now(),
  views bigint not null default 0 check (views >= 0),
  likes bigint not null default 0 check (likes >= 0),
  comments bigint not null default 0 check (comments >= 0),
  shares bigint not null default 0 check (shares >= 0),
  clicks bigint not null default 0 check (clicks >= 0),
  raw_metrics jsonb not null default '{}'::jsonb,
  unique (publication_id, captured_at)
);
create index if not exists cb_content_metrics_user_idx
  on public.cb_content_metrics (user_id, captured_at desc);

alter table public.cb_content_settings enable row level security;
alter table public.cb_content_schedules enable row level security;
alter table public.cb_content_items enable row level security;
alter table public.cb_content_connections enable row level security;
alter table public.cb_content_publications enable row level security;
alter table public.cb_content_metrics enable row level security;

drop policy if exists "content settings owner read" on public.cb_content_settings;
create policy "content settings owner read" on public.cb_content_settings
  for select to authenticated using ((select auth.uid()) = user_id);
drop policy if exists "content settings owner insert" on public.cb_content_settings;
create policy "content settings owner insert" on public.cb_content_settings
  for insert to authenticated with check ((select auth.uid()) = user_id);
drop policy if exists "content settings owner update" on public.cb_content_settings;
create policy "content settings owner update" on public.cb_content_settings
  for update to authenticated using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists "content schedules owner all" on public.cb_content_schedules;
create policy "content schedules owner all" on public.cb_content_schedules
  for all to authenticated using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

drop policy if exists "content items owner read" on public.cb_content_items;
create policy "content items owner read" on public.cb_content_items
  for select to authenticated using ((select auth.uid()) = user_id);
drop policy if exists "content items owner create draft" on public.cb_content_items;
create policy "content items owner create draft" on public.cb_content_items
  for insert to authenticated with check (
    (select auth.uid()) = user_id and status in ('draft','review','queued')
  );
drop policy if exists "content items owner update draft" on public.cb_content_items;
create policy "content items owner update draft" on public.cb_content_items
  for update to authenticated using (
    (select auth.uid()) = user_id and status in ('draft','review','queued')
  ) with check (
    (select auth.uid()) = user_id and status in ('draft','review','queued')
  );
drop policy if exists "content items owner delete draft" on public.cb_content_items;
create policy "content items owner delete draft" on public.cb_content_items
  for delete to authenticated using ((select auth.uid()) = user_id and status in ('draft','review','queued'));

drop policy if exists "content publications owner read" on public.cb_content_publications;
create policy "content publications owner read" on public.cb_content_publications
  for select to authenticated using ((select auth.uid()) = user_id);
drop policy if exists "content metrics owner read" on public.cb_content_metrics;
create policy "content metrics owner read" on public.cb_content_metrics
  for select to authenticated using ((select auth.uid()) = user_id);

-- Connection credentials are accessed only by trusted Edge Functions using the service role.
revoke all on public.cb_content_connections from anon, authenticated;
grant select, insert, update, delete on public.cb_content_settings, public.cb_content_schedules, public.cb_content_items to authenticated;
grant select on public.cb_content_publications, public.cb_content_metrics to authenticated;
