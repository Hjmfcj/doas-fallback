# doas-fallback

Private, internal build. Not delivered to anyone, not shown to the delivery team.

AstraZeneca DOAS (Demand Orders Approval System): a parallel, production-grade build kept as a safety net and designed to be portable to Microsoft Power Apps (tables map to Dataverse or SharePoint lists; rules are written as rule cards that become Power Fx).

Source of requirements: Business Requirements Document v1.3 (18-Nov-2026). Anything the document does not state is not built. Open points are tracked in the Enterprise Portfolio Studio repository (`10_Product_Build`), which stays the source of truth for requirements, decisions and evidence.

## Layout
- `supabase/migrations/` schema, row-level security and functions. Every change is a migration file; the file name carries the version Supabase recorded.
- `supabase/tests/` access and audit tests. Each test ends in a rollback, so it can be run on the live project without leaving data.

## Rules for this repository
- Synthetic or demo data only, marked `demo = true`. No real client data is committed.
- No secrets in the code or the history. Keys are set by the owner in the host and in GitHub secrets.
- Every push to `main` is approved by the owner.

## State (21-Nov-2026)
Slice 1: reference-data tables (empty), users, order files, orders, lines, check issues, insert-only audit log, row-level security, `submit_order`. Front end and hosting: not started.
