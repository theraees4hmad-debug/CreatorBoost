# CreatorBoost Newsroom admin setup

The admin dashboard is available at:

https://theraees4hmad-debug.github.io/CreatorBoost/newsroom-admin.html

## Grant the first administrator

Admin access is deliberately not self-service. A Supabase project owner must grant it to the intended account.

1. Create/sign in to the intended administrator account at the membership sign-in page.
2. In Supabase Dashboard → SQL Editor, run this statement after replacing the email with the administrator's exact login email:

```sql
insert into public.cb_newsroom_admins (user_id)
select id from auth.users
where lower(email) = lower('YOUR_ADMIN_EMAIL')
on conflict (user_id) do nothing;
```

3. Sign in at the admin dashboard using that account.

Only a project owner/service role can insert or remove admin grants. The browser cannot promote itself. Admin article, event, newsletter and analytics access is protected by Row Level Security.

## What the dashboard includes

- Article creation, editing, publish/unpublish
- Live Hub event creation and cancellation
- First-party page/article/share event totals (last 30 days)
- Newsletter subscriber list

## Reader features

- Category filters and article search on the newsroom
- Per-article bookmarks for signed-in readers
- Local reading history (stored in the reader's browser)
- Newsletter opt-in

## Analytics note

The dashboard reports first-party events recorded by CreatorBoost pages. These are not deduplicated Google Analytics users and should not be presented as audited unique visitors. Referrer host and page path are stored; no email or account identity is attached to analytics events.
