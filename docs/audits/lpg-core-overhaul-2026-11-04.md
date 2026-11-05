# LPG component core: release and security evidence

This is the schema-106 overhaul baseline. The later manual purchase-rebate feature is documented in the current purchase/finance guides and its own acceptance tests.

## Review decision

High inherent risk: inventory valuation, cash posting, server-side backups and an explicitly authorized development business reset. No unresolved exploitable security defect was identified in the reviewed paths. The final weekly receipt correction is deployed, and its matching full cloud backup passed isolated recovery. Approved for the development environment within the tested boundary. This is a development release, not certification for production use.

| Unresolved severity | Count |
| --- | ---: |
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 0 |

Baseline: working tree against `b3788a1`, including previously uncommitted attendance/transit changes that are preserved and regression-tested. Focused review covered the three forward migrations, backup/controller/recovery code, guarded reset, financial mutation/query hooks and their UI callers. Supporting styling and unrelated attendance changes were not treated as newly authored security changes or subjected to a separate exhaustive line-by-line audit.

## Authoritative paths and blast radius

- `20261103175450` replaces component purchases/FIFO, pooled treasury and report contracts. `20261104011500` removes the inspected empty financial archive, compatibility RPC/read paths and unused single-SKU FIFO wrapper; purchase refunds accept the canonical payment component only.
- `app_private.post_wallet_entry` remains the sole wallet projection writer. Live catalog inspection found 22 functions referencing the wallet source table and five direct mutable-journal synchronization callers. These are high-impact shared paths; coverage spans sales, purchases, customer collections/refunds, payroll, loans, assets, custom entries and Logistics.
- After schema 106, no current public/private function body references commissions, the retired wallet-business balance table or the removed financial archive. Historical migration/replay source remains intentionally immutable.
- The canonical FIFO set rebuild is called from the inventory-cost trigger; the unused single-SKU wrapper has no callers and is removed. Source locks precede journal/savepoint invalidation.
- Backup authorization in `deploy/backup/control.py:41` retains the active-superadmin, password-change and reset-pending checks introduced in `9abcbe4`; the new immediate-full endpoint does not weaken them. The API supplies a request UUID, not a shell command or destination path.
- `deploy/development-baseline.py` requires explicit deletion intent, the identified original administrator, stopped business writers, a full capture after maintenance began, matching isolated restore proof and verified Storage paths. Original administrator identity/password/authority fingerprints and foreign keys are checked before committing deletion. Completion refuses a backup from an older schema or backend source.

## Concrete adversarial checks

| Attempt | Verified result |
| --- | --- |
| Ordinary owner starts/views admin backup operations | HTTP 403 |
| Duplicate full request / overlapping new request | Original job returned / HTTP 409 |
| Browser closes or refreshes during backup | Same durable server job recovered |
| Foreign tenant reads products, prices or private Storage; submits purchase/treasury mutation | Hidden data or rejected mutation; retained stock fingerprint unchanged |
| Salesman submits purchase, treasury or financial report operation | Rejected under actual Auth/PostgREST |
| Anonymous caller invokes Finance/receipt helpers; browser writes raw journals | Denied; private helper grants remain closed |
| Concurrent sales, empty dispatch or loan repayments | No overselling, lost ownership or overpayment |
| Changed retry body / changed completed transit costs | Rejected; matching intent settles once |
| Real transfer commits but HTTP response is discarded | Reload/original-ID UI recovery; exactly two principal legs |
| Old recovery generation or stale final schema/source | Restore/baseline guard rejects; protected pre-reset copy remains pinned |

No raw credentials/session tokens are included in committed test data or this report. Engine progress exposes only parsed numeric counters; tool failures return sanitized errors. Restic processed bytes and rclone network traffic are kept distinct from the final compressed new-data amount.

## Advisory interpretation

The live Supabase advisor also reports generic notices: default-deny RLS tables without browser policies and authenticated SECURITY DEFINER RPCs. Those are intentional access boundaries here, not evidence of bypass; normal-role, foreign-tenant and anonymous probes remain required. See the [RLS notice](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy) and [RPC notice](https://supabase.com/docs/guides/database/database-linter?lint=0029_authenticated_security_definer_function_executable).

Performance notices include unused indexes after the fresh reset, unindexed foreign keys and one pre-existing identical pair (`financial_entries_page`, `spending_directory`). No accounting inconsistency or acceptance failure was attributed to them. This release does not claim a production-scale performance audit or remove indexes solely from a fresh lab's usage statistics; the [duplicate-index advisory](https://supabase.com/docs/guides/database/database-linter?lint=0009_duplicate_index) remains a nonblocking maintenance item.

## Confirmed defects corrected

- A pending initial wallet query could overwrite post-transfer results; shared cancellation/invalidation now suppresses that stale response.
- Closed older transits lacked a client collection route; client receipts/refunds remain available while operating costs stay locked.
- Conflicting completion requests could appear successful without applying changed costs; stored revision/intent distinguishes exact retry from conflict.
- Gross transfer legs overstated principal; reporting counts one transferred amount and no business/equity/profit allocation.
- Refill custody/cancellation could lose original shell chronology; linked component layers and original-layer returns retain it.
- Backdated FIFO corrections could leave cancelled replacement claims/exchange reversals stale; source-linked dated reversals are resynchronized.
- Consolidation-only corrections could be discarded when the business amount was zero; both dimensions now remain authoritative.
- Received Stove returns could leave a phantom internal transport asset; performed delivery is expensed and eliminated correctly.
- Cancelled exchanges remained in weekly incoming-empty totals despite correct stock reversal; product history now shares the completed-sale boundary, with a regression reproduced before the fix.
- Removing the commission panel left the new Gas/Bottle editor unmounted; the product modal now renders and exercises both controls.

## Independent financial evidence

The retained lab is `9ae10ffa-e8b6-42ce-af9d-587d84c441f7`. Source inputs and original request IDs live in ignored `.temp/core-business/manifest.json`; credentials remain only in `.env.core-test`. `core-independent.mjs` imports no application costing/report logic. Its integer-money expectations verify exact LPG, Stove, Logistics and Combined cash, capital, revenue, expenses, liabilities, assets, internal elimination and transfer principal, alongside physical/FIFO quantities and values. Report balance alone is not the acceptance criterion.

Verified sequences include the 100 Gas/30 Bottle/70 owned-empty purchase, changed-price 2/1/1 exchange with optional fee and partial payment, package ownership transfer, original sale cancellation/refund, Stove receipt/return/refund and split sale, partial supplier/customer payments, bonus/salary, loan principal, shared expense/return, equipment/depreciation and service cost/advance/return/finalization.

Disposable PostgreSQL tests also verify historical replay/corrections, exact cancellation source restoration, consumed-return rejection, concurrent snapshot publication and full-journal equality. Historical replay fixtures remain at their original contract boundaries; current employee/authorization regressions use current contracts.

## Executed acceptance and exact closing sample

The final published browser matrix passed at 1440px and 375px in both light and dark themes, with no uncaught browser errors. It opened all 12 operator routes, main create forms, Finance tabs/drilldowns, all tabular reporting positions, product component editors/history, customer due filters, Settings sections and Logistics details. Actual mutating browser sequences and response-loss recovery are separate retained tests. This is broad acceptance coverage, not a claim that every possible UI input sequence or physical device has been exercised.

Current checks passed: 47 source tests, 10 deployment JavaScript tests, 44 deployment Python tests, lint and the deployed TypeScript/Vite build. Print (23) and attendance receiver (5) regressions, disposable current-contract SQL/concurrency/snapshot suites, employee/payroll/attendance regressions and isolated account-service Auth integration also passed during this overhaul. Live role/RLS probes and independent reconciliation passed again after the final reporting migration.

| Independent closing component | Tk |
| --- | ---: |
| Real wallets / canonical Cash | 970,296.00 |
| Accounts receivable | 9,550.00 |
| Consolidated Supplies | 215,111.25 |
| Equipment and vehicles | 509,900.00 |
| Loans | 2,500.00 |
| Other payables, including payroll | 126,300.00 |
| Capital | 1,584,001.00 |
| Revenue | 20,550.00 |
| Expenses, including signed exchange variance | 28,493.75 |
| Withdrawals | 0.00 |
| Equation difference | 0.00 |

Jamuna retains 96 filled plus one empty; Total Gas retains one empty. Actual Gas value is Tk 77,763.75 and Bottle value Tk 132,787.50. Internal stock value Tk 2,502.50 is eliminated from consolidation. Real-wallet transfer principal is Tk 8,200, counted once; it changes neither profit nor business ownership. Gas/Bottle, physical stock, each wallet ledger, canonical Cash, source liabilities and all four business positions independently agree. The final PDF was rendered and visually checked against these figures.

## Recovery and publication

The pre-reset full point `56e891c9dfb279771ddfc74c62ca74f0888207e271d5e4f34299a6e0e167f6f7` was physically restored before deleting three businesses/four business Auth users and two Storage objects. One original admin and the dedicated burner Auth login were preserved. The original admin's password was not typed into a browser; preservation is established by unchanged credential/authority fingerprints and isolated recovery.

The post-overhaul Admin-driven full point `0339820235dccb7fd8e69e6cc856c04896a21c14da96577a576cbaf7ae3626a9` passed actual Google Drive upload, physical restore, Auth/RLS/Storage, admin-identity and journal checks. Its temporary test admin was removed. The final baseline additionally contains the completed source lab, final schema and only the preserved original admin.

Final full snapshot: `2cb2b5fb0afff4f2cb1e959df8d9cf59230268cc304f88b38b8e99cbc51921f3`, job `4d8c2b06-b15a-489d-b7dd-4aab860d7750`. It completed at 2026-11-04 02:26:03 UTC after 1,161 seconds. Restored evidence: one business, three Auth users (original admin, retained burner and fresh lab owner), one Storage object, 78 balanced journals, 76 RLS tables and 106 migrations. The preserved original administrator is the only platform admin in the captured system and after temporary viewer cleanup. The browser process was fully restarted during this real job and recovered the same server-side status.

The engine processed 1,198,796,563 bytes, sampled 7,297,724 upload-network bytes and finalized 7,811,715 compressed new-data bytes. These are different counters, not an asserted equality. The final backup matches migration fingerprint `6ff8204adc6db087ae293b2081f8f08e` and backend source SHA256 `22f00310cd89cf2f7c28746c13f5f80bb3168c8317eaa05ecd6618ba7ca81e54`.

Final VPS/Cloudflare publication passed with no pending migrations or changed backend services. Worker version: `673a351d-1fd0-4f07-aa51-2370d8fdca7e`. No asset changes were introduced by the final publication; the published entrypoint matches the browser-verified bundle exactly. Backend health, matching recovery fingerprints, original admin count, active backup timer and independent financial reconciliation were verified again afterward.

The guarded baseline completed only after this proof; the original admin fingerprint still matched, the old pin was released and the original timer was restored. Next automatic capture is 2026-11-05 02:00 Asia/Dhaka, with the existing 30-day/12-month policy. The current-generation private recovery kit was exported to the owner-only Windows recovery folder and its archive/essential files verified. Obsolete local lab credentials/manifests were archived under ignored `.local-backups/pre-core-labs-20261104`; the current lab and burner login remain active. Temporary assembly scripts were removed. Azure remains untouched. Physical Android/PWA/device operation, attendance hardware, physical printing and bank/mobile-provider settlement remain external acceptance boundaries. Browser emulation and recorded external funds do not establish them.
