# Employees redesign verification — 28 October 2026

[Module rules](../modules/employees-and-payroll.md) · [Architecture](../architecture.md)

## Delivered architecture

Compact employee cards and one contextual profile replace the former payroll workspace. Profile editing and salary/bonus payments stay inside the same dialog. Monthly salary history and chronological activity have bounded pages. Directory display capacity is independent of cached 25-record server batches.

Salary months are automatic. The first payment establishes the applicable amount; partial/repeated/split payments can target past, current or future months. Subsequent salary/status revisions preserve established amounts. The latest active rate within a month supplies the full monthly salary; joining/leaving months are not prorated. Salary corrections can start on the joining day. Future employees show their configured salary and Not started status.

Named bonuses move funds immediately and never change salary balances. Actual returned funds retain the original payment, reason, actor, date and wallet attribution. Driver/helper payments continue to settle saved Logistics role costs; closure charges only the remaining cost.

The active schema has eight employee tables, RLS on each, and no payroll adjustment table, preparation/advance helpers or old payroll-operation RPC. Historical migrations and their replay tests remain intact. The new schema retains original payment identities and wallet evidence; prior corrections become activity evidence and their net monthly amounts remain fixed. No existing wallet/ledger/stock movements are reposted.

## Verification evidence

| Boundary | Result |
| --- | --- |
| Frontend | TypeScript/Vite build and full repository lint passed. |
| Unit checks | 54 application tests passed. |
| Existing subsystem checks | 16 print tests and deployment checks (10 Node tests, 12 Python tests) passed. No physical printing was performed. |
| Disposable PostgreSQL replay | All 38 migrations and eleven current SQL suites passed in PGlite/PostgreSQL 17.5, including deployment-batch replay. Historical payroll tests run only at their old migration boundary in standalone replay. |
| Actual PostgreSQL 17.6 | Azure disposable-database replay and all current suites passed. Concurrent duplicate/competing salary payments, future-month creation, returns, salary revision versus first payment and trip payout versus closure passed alongside existing transaction races. Only the disposable database was removed. |
| Intercepted browser fixtures | All 31 directory records appeared exactly once across pagination at 320, 390, 768 and 1440 pixels. Profile/payment/edit stayed in one dialog; future split payment, bonus independence, search, original-request response-loss/reload recovery and fixed 25-record batches passed. |
| Published Auth/PostgREST | Real login, trusted burner membership inspection, creation, revisions/status, past/current/future payments, split/repeated payments, named bonuses, returns, idempotency, competing requests, ledger attribution and role/tenant isolation passed. |
| Published browser | Responsive directory/profile, employee creation/edit, future split salary, custom bonus with description, correction/return, salary revision preserving a paid future month, Finance-to-profile link, Logistics-funded driver payment and residual-only closure passed with normal fixture-account permissions. |
| Preservation | Wallets reconciled to opening balances plus ledger movements. Disposable businesses/accounts were cleaned up; original business fingerprints were unchanged and the burner account retained. |

The final integrity migration also rejects infinite payment dates and removes the unused index for the retired global month directory. SQL checks cover scheduled joining and same-day salary correction.

## Deployment

The established Azure updater applied `20261028090057_employee_management.sql` and the forward integrity migration `20261028092350_employee_payment_date_integrity.sql`, with private database/configuration recovery files and migration-history recording. Historical migration files were not edited. The dependent Cloudflare frontend was published after the backend. The updater verified the ten services, HTTPS health, existing credentials and data-volume attachments.

Supabase MCP tools were unavailable in this session. Deployed schema/migration/RLS and wallet reconciliation were inspected through the established configured SSH/SQL path. Browser fixtures are separate from authenticated published acceptance. Physical-device/PWA installation and bank/mobile-provider settlement were not verified; the application records completed external payments and does not initiate transfers.
