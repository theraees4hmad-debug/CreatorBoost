-- Public CreatorBoost newsroom. Additive only; existing wallet and campaign tables remain untouched.
create table if not exists public.cb_public_articles (
  id uuid primary key default gen_random_uuid(),
  source_url text not null unique,
  source_name text not null,
  source_title text not null,
  title text not null,
  slug text not null unique,
  excerpt text not null default '',
  body text not null,
  category text not null default 'Gaming' check (category in ('Gaming','Streaming','YouTube','Esports','Creators')),
  image_url text,
  status text not null default 'published' check (status in ('draft','published')),
  published_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index if not exists cb_public_articles_feed_idx on public.cb_public_articles (status, published_at desc);
alter table public.cb_public_articles enable row level security;
drop policy if exists "Public can read published CreatorBoost articles" on public.cb_public_articles;
create policy "Public can read published CreatorBoost articles" on public.cb_public_articles
  for select to anon, authenticated using (status = 'published');
grant select on public.cb_public_articles to anon, authenticated;
revoke insert, update, delete on public.cb_public_articles from anon, authenticated;
