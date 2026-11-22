-- Allow the YouTube OAuth Edge Functions to manage encrypted connection rows.
-- The table remains protected by RLS; these privileges are only for service_role.
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.cb_youtube_connections TO service_role;
