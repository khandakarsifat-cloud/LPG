# Logistics overhaul verification — 2026-10-30

The primary development backend is `144.79.249.4`; the frontend is the existing Cloudflare Worker. The retired Azure backend was not used.

## Delivered behavior

- Canonical `vehicles` / `vehicle_id`; no size or manually entered vehicle location. Capacity is informational. Location follows an active destination, otherwise Home.
- Current Driver/optional Helper assignments, explicit unlink/reassignment history, and immutable departure crew snapshots.
- Deferred transit earnings, partial/multi-wallet canonical employee payments, audited payment returns and separate salary/bonus balances.
- Distinct Active, Returned, Completed and Cancelled states. Receipt/return releases the vehicle. Final completion requires paid crew and posts only non-employee expenses once.
- Server-filtered/paged vehicle, transit, assignment and payment histories; vehicle and Employee details share participation and financial summaries.
- Gas plants and officer management in Settings, including plant-only read access without other settings or mutation controls.
- Older open journeys retain unknown crew. An operator can explicitly identify actual participants once with a source/reason and audit record; assignments and money are unchanged by attribution.

## Database and deployment

Forward migrations `20261030111659` and `20261030114445` were applied through the established deployment workflow. Historical migrations were unchanged. Deployment created verified private recovery files before applying SQL; eleven backend services and public HTTPS health passed. Data volumes and server credentials were preserved.

Final Worker version: `23fa12d3-4310-47f0-9c15-644d10ba4ab9`.

## Verification evidence

- `npm run build`: TypeScript and Vite passed.
- `npx eslint src tests/authorization.test.ts tests/purchase.test.ts --no-warn-ignored`: passed.
- `npm run purchase:test` and `npm run auth:test`: 22 checks passed.
- `node supabase/tests/run-logistics.mjs --vps --with-migrations`: passed on uniquely named disposable PostgreSQL restores. Existing wallet, ledger, stock, sales, purchase-line and employee-payment evidence fingerprints were unchanged by migration. Workflow checks cover assignment/unlink/reassignment, crew snapshots, role requirements, deferred/split/partial payments, returns, cancellation payables, completion locks, purchase receipt, informational capacity, filtering/pagination and explicit historical attribution. Current authorization, Employee and Purchase wallet regression suites passed.
- Concurrent real PostgreSQL sessions: competing payments cannot overpay, eight matching requests pay once, four completion requests post one non-employee expense; wallet balances reconcile.
- `node supabase/tests/logistics-api.mjs --vps --browser`: real Auth/PostgREST and published Chrome passed. Dedicated burner membership was checked read-only. All writes used uniquely named disposable fixture businesses. Live purchase dispatch/receipt, deferred earnings, split payments, completion restrictions, vehicle creation/edit/crew, pagination, Employee integration and Settings plant/officer management passed. Dialogs were checked at 390, 768 and 1440 pixels; no browser errors were recorded. The historical attribution dialog was inspected read-only on existing burner journeys.
- Fixture wallets reconciled to the sole ledger. Fixture cleanup used the established scoped purchase-fixture mechanism; all original-business fingerprints matched afterward and the burner login was retained.
- Final diff whitespace checks passed. Screenshots are ignored local artifacts under `.temp/logistics/`.

Physical Android/PWA behavior and external bank/mobile-provider settlement were not exercised. Existing pre-task working-tree changes were retained.
