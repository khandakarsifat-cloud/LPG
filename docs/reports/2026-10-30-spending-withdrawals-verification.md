# Spending, withdrawals and modal corrections — 2026-10-30

Deployed migration `20261030152540` to the primary development VPS and published Worker version `e29a9538-f057-4e77-bf44-82c4d78edd72`. The established updater retained recovery files, preserved volumes/credentials and passed eleven-service/public HTTPS health checks. The retired Azure backend was untouched.

Finance and Dashboard share a confirmed Spending / withdrawal form. Business and Logistics default to costs; Home and Others to withdrawals. Settings manages category names, classifications and active states. Existing records retain their category/classification/wallet snapshots. The sole wallet ledger trigger posts the debit, with canonical request recovery and duplicate-request protection. Finance provides filtered/paged entries and separate cost/withdrawal totals; the same transactions appear in Wallet ledger.

Employee attendance headings show clock status instead of Today. Vehicle crew has only role-filtered Driver/Helper dropdowns. Vehicle saves and transit cost saves require confirmation. Child employee-payment form submissions do not trigger the parent's transit-save confirmation.

Verification:

- TypeScript/Vite builds, source ESLint and final whitespace checks passed.
- Purchase/authorization unit suites passed (22 checks).
- Disposable PostgreSQL restore/migration verification passed Logistics, spending, authorization, Employee and Purchase wallet suites, financial/stock preservation checks and payment/completion races.
- Spending SQL checks cover cost/withdrawal totals, wallet reconciliation, historical classification snapshots, stale revisions, validation, idempotency, server paging and tenant isolation.
- `node supabase/tests/spending-api.mjs --vps --browser` passed real Auth/PostgREST and published Chrome checks: eight simultaneous matching requests posted one debit, category changes preserved history, foreign-tenant requests failed, Dashboard confirmation retained cancelled drafts, Finance filtering and Settings category creation worked, role dropdowns excluded unrelated employees, and the employee profile had a status heading. Forms were checked at 390/768/1440 pixels.
- `node supabase/tests/logistics-api.mjs --vps --browser` passed after the confirmation change, including vehicle create/edit/assignment confirmations, custom journeys, split employee payments, paid completion, purchase receipt, Employee integration and Settings plant/officer workflows.
- Both live suites used uniquely named disposable businesses. Cleanup completed and original-business fingerprints matched; the burner account was retained. Canonical wallet balances reconciled.

Physical devices and actual bank/mobile-provider settlement were not exercised. These forms record money already paid; they do not execute provider transfers.

## Employee card correction and requirement audit

The initial attendance-label verification targeted the profile modal and missed the directory card's Today label. Cards now show Clocked in / Clocked out with the corresponding AM/PM time, retaining arrival time after clock-out, or Not clocked in without an arrival. Loading and unavailable states stay explicit. Worker version `6dc59c01-2bc0-4d07-b1f9-1684214b3962` contains the correction; deployment confirmed no pending migrations and eleven healthy backend services.

Fresh published-browser inspection confirmed Finance and Dashboard entry buttons, four correctly classified default categories, Settings category creation/classification controls, exactly two role-scoped crew selects, vehicle save confirmation and transit-cost save confirmation. Confirmation-only checks were cancelled without business writes. The real spending API/browser suite passed again, including eight matching retries, immutable category snapshots, wallet reconciliation, Settings creation and fixture cleanup with original business fingerprints unchanged. Real employee cards were checked at 390/768/1440 pixels. Intercepted attendance responses separately verified clocked-in, clocked-out, no-arrival and unavailable card states; these were browser fixtures, not physical scans.
