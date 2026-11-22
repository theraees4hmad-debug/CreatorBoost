create table if not exists public.cb_youtube_connections (
  user_id uuid primary key references auth.users(id) on delete cascade,
  refresh_token text not null,
  channel_id text,
  channel_title text,
  connected_at timestamptz not null default now()
);

alter table public.cb_youtube_connections enable row level security;
revoke all on public.cb_youtube_connections from anon, authenticated;
