# doas-fallback

Private, internal build. Not delivered to anyone, not shown to the delivery team.

AstraZeneca DOAS (Demand Orders Approval System): a parallel, production-grade build kept as a safety net and designed to be portable to Microsoft Power Apps (tables map to Dataverse or SharePoint lists; rules are written as rule cards that become Power Fx).

Source of requirements: Business Requirements Document v1.3 (18-Nov-2026). Anything the document does not state is not built. Open points are tracked in the Enterprise Portfolio Studio repository (`10_Product_Build`), which stays the source of truth for requirements, decisions and evidence.

## Layout
- `supabase/migrations/` schema, row-level security, functions and views. Every change is a migration file; the file name carries the version Supabase recorded. Exception: `20261121165400_file_check.sql` was applied through the SQL editor, so Supabase's migration history does not list it; its version number was chosen to sit before the next recorded one.
- `supabase/seed/` demo seed and its removal script. Synthetic rows only, all marked `demo = true`; not a migration, run on demand.
- `app/` the front end: one static page (sign in, Drafts with run-check and submit, My Orders, order detail). It reads the Distribution Manager views only and uses the publishable key. Hosted on Cloudflare Pages (direct upload, project `doas-fallback`); to redeploy, upload `app/` as a zip in the Pages dashboard.
- `supabase/tests/` access, audit, file-check and view tests. Each test ends in a rollback, so it can be run on the live project without leaving data.

## Rules for this repository
- Synthetic or demo data only, marked `demo = true`. No real client data is committed.
- No secrets in the code or the history. Keys are set by the owner in the host and in GitHub secrets.
- Every push to `main` is approved by the owner.

## State (21-Nov-2026)
Slice 1: reference-data tables (demo seed loaded), users, order files, orders, lines, check issues, insert-only audit log, row-level security, `submit_order`, the file check `run_file_check` (V-01, V-04, V-05, V-06, V-08, V-12), and read views for Drafts, My Orders and order detail. Not coded because the requirements do not say enough: V-02, V-03, the product key on an order line, the blacklist match key. Front end: sign in, Drafts, My Orders and order detail are live on Pages; file upload, approvals and Back-End screens are not built.
