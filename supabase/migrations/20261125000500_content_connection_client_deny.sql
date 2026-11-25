-- Explicitly deny direct browser access to encrypted publishing credentials.
drop policy if exists "content connections deny browser access" on public.cb_content_connections;
create policy "content connections deny browser access"
  on public.cb_content_connections
  for all to authenticated
  using (false)
  with check (false);
