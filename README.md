# CreatorBoost

Creator discovery and promotion platform. The current app is a static HTML/CSS/JavaScript site backed by Supabase Auth, Postgres RPCs, database migrations, and Supabase Edge Functions.

## Project links

- Website: https://theraees4hmad-debug.github.io/CreatorBoost/
- Repository: https://github.com/theraees4hmad-debug/CreatorBoost
- Supabase project ref: `yubjmudsbbgskeqqejob`

## Current repository features

The main `index.html` contains the responsive CreatorBoost experience, including account signup/login, Google OAuth, creator profiles and social links, creator discovery, earn tasks, campaigns, wallet screens, payment requests, withdrawals, and a creator-services marketplace.

The Supabase migrations currently in the repository cover:
- Verified task rewards and reviewer/admin approval.
- Trusted task reviewers.
- YouTube OAuth connection records.
- An authoritative points wallet and points ledger.
- Withdrawal approval and payment approval queues.
- Automatic campaign rewards.
- Creator services marketplace and service orders.

Supabase Edge Function folders are present for YouTube OAuth start/callback, connection status, and disconnect.

## Wallet transfer migration status


- Secure points-to-points transfer RPC migration: `202611220010_secure_points_transfers.sql` (prepared in source; must be applied and tested on Supabase before use).

The transfer RPC accepts the recipient's confirmed account email, enforces authenticated sender identity, locks both wallet rows in a stable order, debits/credits within one transaction, writes paired ledger entries, and accepts an idempotency key. The frontend now includes a transfer form and history panel that call these RPCs. The form will remain unavailable until this migration is applied to Supabase. Do not advertise transfers as live until the migration is applied and two-account tests pass.

## Important production boundaries

- The browser uses a Supabase **publishable** key. Never put a Supabase secret or `service_role` key in `index.html`, any other browser file, or Git history.
- Wallet balance and point mutations must remain server-authoritative through the Supabase RPCs and ledger. Do not treat browser `localStorage` activity/history as a financial or points source of truth.
- UPI, bank transfer, and crypto payment requests are submitted for verification. A submitted request is not proof that money was received. Confirm payment against the provider/bank before approving it or crediting points.
- Withdrawal requests require review and payout confirmation. Do not describe a request as paid until the payout has actually been completed.
- Social profile links are not proof of account ownership. Use the OAuth verification flow where supported.
- Keep wagering, real-money betting, casino and cash-out features disabled unless legal, age, licensing, and payment-provider approvals have been independently confirmed. Virtual points are not cash.

## Deploying the website

The `.github/workflows/pages.yml` workflow deploys the repository root to GitHub Pages on pushes to `main` and on manual workflow dispatch.

Expected public URL:
`https://theraees4hmad-debug.github.io/CreatorBoost/`

After a push, check the **Actions** tab and confirm the Pages workflow completed successfully. Then open the website on desktop and mobile and test the live routes and account flows.

## Deploying Supabase Edge Functions

The `.github/workflows/deploy-supabase-functions.yml` workflow deploys the four YouTube OAuth functions when function files or `supabase/config.toml` change.

It requires the GitHub Actions repository secret:
- `SUPABASE_ACCESS_TOKEN`

The workflow also expects the project's Supabase function environment secrets (for example, Google/YouTube OAuth client credentials and the Supabase function service credentials) to be configured securely in Supabase. Do not add those secrets to this repository.

After deployment, inspect the **Actions** run and test the OAuth connect, callback, status, and disconnect flow with a real authorized account.

## Database migrations

SQL files under `supabase/migrations/` define the database-side features. They must be applied to the intended Supabase project in timestamp order, and then tested against real authenticated users and admin/reviewer roles.

Do not blindly reset or recreate the production database. Before applying a migration:
1. Confirm the target Supabase project.
2. Review the SQL and its RLS/policy/privilege changes.
3. Back up production data.
4. Apply migrations in order.
5. Test the relevant RPCs and RLS behavior with owner, ordinary-user, and anonymous sessions.

The presence of a migration file in GitHub does **not** prove it has been applied to the hosted database.

## Go-live verification checklist

- [ ] Latest GitHub Pages workflow is green and the deployed site matches `main`.
- [ ] Signup, email confirmation, login, Google OAuth, session refresh, and logout work on the deployed origin.
- [ ] Supabase Auth redirect URLs include the production GitHub Pages URL.
- [ ] All migrations are applied to the correct Supabase project and RLS is tested.
- [ ] Wallet balance, earn rewards, campaign spend, transfers, and ledger history reconcile server-side.
- [ ] Deposit/payment requests are manually verified against actual receipts before approval.
- [ ] Withdrawals are approved and paid through a documented process.
- [ ] Admin and reviewer permissions are tested with separate accounts.
- [ ] YouTube OAuth secrets and redirect URLs are configured and all four Edge Functions are deployed.
- [ ] Marketplace orders cannot be fulfilled before payment verification.
- [ ] No secrets, test credentials, or personal payment details are committed.
- [ ] Mobile, accessibility, error, empty, and signed-out states are tested.
- [ ] Any real-money gambling or wagering functionality remains disabled until all required approvals are in place.

## Development

This repository currently has a single-page static frontend, so no Node build step is required for the website itself. For local preview, serve the repository root with any static HTTP server. OAuth redirects should be tested on an HTTPS origin or a configured localhost callback.

---

**Status note:** GitHub source files can be reviewed here, but a code push alone cannot verify the hosted Supabase schema, payment-provider settlement, OAuth provider configuration, or production user journeys. Mark the go-live checklist complete only after testing those systems in their real environments.


## CreatorBoost Newsroom

The public homepage opens the 24/7 gaming and streaming newsroom. Browse `news.html` for Gaming, Streaming, YouTube, Esports and creator stories; each story has its own `article.html?slug=...` page. The existing creator dashboard and wallet remain available at `index.html?page=dashboard` and `index.html?page=wallet`.

The Supabase `content-worker` checks configured RSS feeds and publishes AI-assisted, source-attributed briefs into `cb_public_articles`. It runs through the GitHub Actions schedule every five minutes when `CONTENT_WORKER_SECRET` matches in GitHub Actions and Supabase Edge Function secrets. See `docs/AI_CONTENT_AUTOMATION_SETUP.md` for setup and limitations.
