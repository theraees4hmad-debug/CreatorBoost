# CreatorBoost AI Content Automation

The AI Studio is available at `content-studio.html` and is linked from the main CreatorBoost navigation.

## Current implementation

- Additive `cb_content_*` database schema; existing wallet, points ledger, clip campaigns and submissions are not modified.
- Authenticated `content-generate` Edge Function generates article/social drafts with OpenAI and saves them to the signed-in user's content library.
- Recurring schedule records with timezone, frequency and next-run timestamps.
- `content-worker` processes due schedules and publishing queue.
- Publishing adapters currently support WordPress posts and X posts.
- Publishing credentials are encrypted server-side before they are stored in `cb_content_connections`.
- Analytics tables and dashboard totals are ready; the worker captures an X public-metrics snapshot when an X post is published. Periodic refresh and WordPress traffic analytics remain follow-up work.
- Review-before-publish is the default. Automatic publishing requires the user to disable review and enable generation in AI Studio settings.

## Required secrets

Set these under Supabase Dashboard → Project Settings → Edge Functions → Secrets:

- `OPENAI_API_KEY`: OpenAI API key used by article and social generation.
- `CONTENT_ENCRYPTION_KEY`: base64-encoded 32-byte random key used to encrypt provider credentials. Generate one with `openssl rand -base64 32`.
- `CONTENT_WORKER_SECRET`: long random secret used to authenticate scheduled worker requests.

Add the same `CONTENT_WORKER_SECRET` as a GitHub repository Actions secret. The scheduled workflow invokes the worker every five minutes. GitHub Actions schedules are best-effort and can be delayed; they are not a guaranteed real-time scheduler.

The existing `SUPABASE_ACCESS_TOKEN` GitHub Actions secret is also required by the Edge Function deployment workflow.

## Publishing account setup

### WordPress
Create a WordPress Application Password for a dedicated publishing user. In AI Studio → Settings, enter the HTTPS site URL, WordPress username and Application Password. The credential is encrypted by the Edge Function; it is never stored in browser local storage.

### X
Create an X OAuth 2.0 user access token with `tweet.write` and `tweet.read` permissions so the worker can publish and capture public post metrics. In AI Studio → Settings, enter the handle and token. API access and usage are subject to X developer-plan limits.

## Platform limitations

Instagram publishing requires an eligible professional account and a configured Meta app with the required publishing permissions; image publishing is not included in this first adapter. TikTok requires Content Posting API access/approval. The existing YouTube OAuth flow is read-only and does not authorize publishing. Those platforms can be used to generate drafts, but are not auto-published by the current worker.

## Safe launch checklist

1. Add the Supabase and GitHub secrets above.
2. Merge the feature branch so GitHub Actions deploys `content-connect` and the other Edge Functions and enables the scheduled workflow on `main`.
3. Connect WordPress and/or X in AI Studio.
4. Save brand settings; enable recurring generation only after the worker secret is configured.
5. Keep review-before-publish enabled for the first test. Verify a generated draft, then approve one queued post.
6. Check the GitHub Actions worker run and the provider's published post before enabling unattended publishing.
7. Add provider analytics polling before treating dashboard engagement totals as live metrics.


## Public CreatorBoost Newsroom

- Public reader: `news.html`; individual article pages: `article.html?slug=...`.
- The additive `cb_public_articles` table is publicly readable only for rows with `status = 'published'`; RLS is enabled and anonymous clients have SELECT only.
- The content worker checks the IGN, GameSpot, YouTube Official Blog and Twitch Blog RSS feeds, skips source URLs already stored, and asks the editorial model to write a short attributed brief using only the source title/description.
- The worker is capped at 2 new stories per invocation and 12 per UTC day. Feed/API failures are isolated so one unavailable feed does not stop the others.
- GitHub Actions invokes the worker every five minutes on a best-effort basis. The newsroom is not continuously live unless `CONTENT_WORKER_SECRET` is set to the same value in GitHub Actions and Supabase Edge Function secrets, and `OPENAI_API_KEY` is configured in Supabase.
- Stories link to their original publisher. The brief is an AI-assisted summary, not independent fact-checking; editorial review remains recommended before fully unattended publication.
