# Finance validation

## Current verification boundary

The current core contract starts at `20261103175450_core_component_inventory_and_shared_treasury.sql`, with archive removal, weekly receipt correction and manual purchase-rebate settlement in subsequent forward migrations. Earlier FIFO/commission and wallet-portion labs describe superseded development contracts; their source and results remain in Git history and the protected pre-reset recovery generation.

`node supabase/tests/run-unified-accounting.mjs --vps` validates the actual current migration in an owned disposable PostgreSQL clone. It checks:

- Gas/Bottle purchases, owned empties in custody, exact overhead and component references.
- Historical FIFO, original-layer returns, backdated replay and cancellation reversals.
- Weekly product receipts exclude cancelled sales, matching the completed-sale boundary.
- Two Jamuna refills with one Jamuna and one Total Gas return, immutable incoming price snapshots and signed exchange variance.
- Manual rebate recognition, unchanged product prices/references/FIFO/COGS, cash-only refunds, released credit reuse and concurrent single-use company credit.
- Partial supplier/customer settlement, Stove returns, payroll, loans and real-wallet transfers.
- LPG, Stove, Logistics and Combined positions, internal transport eliminations and transfer principal.
- Normal authenticated/anonymous SQL roles, tenant RLS and private helper permissions.
- Concurrent stock issues, empty dispatch, loan settlement, treasury retry, conflicting completion and snapshot publication.
- Savepoint-backed positions against full canonical journal recomputation, including consolidated-only corrections.

Fixtures roll back or live only in the owned clone; they do not prove published Auth/browser integration.

## Published acceptance

`npm run accounting:api:test` runs the complete retained lab sequence. `node supabase/tests/core-business.mjs --vps` creates a clearly named retained fresh business and generated account, records source inputs/request IDs in ignored `.temp/core-business/manifest.json`, and uses real Auth/PostgREST for business operations. Its integer expectations for physical stock, Gas/Bottle FIFO, exchange valuation, loan principal, real cash, transfer legs and journals are independent of report arithmetic. Credentials live only in ignored `.env.core-test`.

`core-stove.mjs` verifies direct Stove receipt and split partial sale. `core-exchange.mjs` retains the 2/1/1 exchange after changing current references, including an optional fee and partial payment. `core-assets-logistics.mjs` covers service advances/returns/finalization and allocated equipment depreciation. `core-independent.mjs` independently verifies exact money for every business, consolidation, transferred principal and physical stock from the original inputs. `core-workflows.browser.mjs` commits actual published owner investment, expense, package checkout, component purchase lifecycle and Gas/Bottle reference edits. `core-recovery.browser.mjs` commits a real wallet transfer, discards its HTTP response and verifies reload/original-ID UI recovery with exactly two ledger legs. Network fault injection is explicitly separate from normal live flows.

The retained lab is **LPG Component Development Lab 2026-11-04**, tenant `9ae10ffa-e8b6-42ce-af9d-587d84c441f7`. Keep its manifest and credentials out of ordinary fixture cleanup. The earlier labs are no longer current acceptance targets.

`node tests/manual-backup-live.mjs --vps` exercises the published Admin action, ordinary-user denial, exact retry, overlap rejection, browser reload/restart recovery, measured upload counters, phone layout and actual Google Drive full backup with an isolated physical restore. Server-side completion requires file hashes, Auth/Storage checks, journal integrity and original admin credential/authority fingerprints. It does not test the original administrator's password interactively.

Desktop/Android-sized browser acceptance, current source-operation reconciliation and backup recovery evidence must be reported separately from disposable SQL tests. Physical attendance devices, physical printing, installed Android behavior and bank/mobile-provider settlement require their respective external acceptance; browser emulation does not prove them.

## Safety and reconciliation

Business deletion is available only through the explicit guarded development-baseline workflow after a maintenance-time full cloud backup and matching isolated restore. Admin credentials/authority and system configuration are preserved. Recovery generations prevent silently restoring obsolete business data. The pre-reset point stays pinned until the new full baseline verifies; automatic retention and scheduling then resume.

Never repair an unexplained difference with invented payments, stock or balancing journals. A balanced equation is necessary but must also match the physical movement, FIFO sources, obligations, wallet ledger and original business operation.

## Manual purchase rebate acceptance

`npm run rebate:api:test` creates a new clearly labelled disposable business and normal owner, then runs published desktop/phone writes, real response-loss recovery, authenticated API cancellation/refund/credit reuse and source-based independent reconciliation. It verifies owner/manager/foreign-tenant/anonymous boundaries and cleans only that verified fixture. Ignored `.temp/purchase-rebate-live/` retains evidence; completed runs are archived under `.temp/purchase-rebate-history/` on the next setup. Credentials are discarded after cleanup. `purchase-rebate.sql` and the current concurrency suite test unchanged product prices/FIFO/COGS, exact cents, company isolation and competing credit consumption in an owned clone.

The retained core lab now contains additional operator purchases/sales beyond its original manifest. Its original fixed expected totals can therefore fail. Preserve the original evidence and additional activity; do not force those totals with balancing entries, delete operator activity or silently rebuild expectations from reports. Use a fresh scoped fixture for new acceptance and read-only source/ledger consistency checks for preservation. The original core verifier remains a strict original-operation check, not certification of unreviewed additions.

The [manual rebate acceptance record](../audits/purchase-rebate-2026-11-04.md) contains executed cases, exact source-derived sample balances, preservation checks and scope limits.

## Finance visibility and product performance acceptance

Run `npm run accounting:db:test` for the isolated current-engine lifecycle/concurrency suite, including `finance-visibility-performance.sql`. Its independent source fixture checks 100 Gas / 30 Bottle ⇒ 70 Refill / 30 Package received quantities, original bottle chronology, component carrying-value reconciliation, transport allocation, projected margins, missing prices, POS wholesale fallback, tenant/role boundaries, hidden-wallet postings and atomic transfer denial. It also checks individual Balance scope without Finance workspace access.

`npm run finance:visibility:api:test` creates a uniquely named disposable business with generated OWNER/MANAGER identities. The published-browser stage saves permissions through the real access editor, records an expense through a hidden-balance wallet, checks desktop/393px layouts, denied tabs/direct API reads, own-entry isolation, POS-only balance access and polling-driven revocation with an unchanged permission list. No report responses are intercepted. Final API/SQL checks compare real quantities, FIFO carrying assets, wallet ledger totals and journal Cash; cleanup is restricted to its verified tenant and generated identities. Evidence is ignored under `.temp/finance-visibility-live/`; passwords are discarded after verified cleanup. This command never uses the retained core lab or changes genuine memberships.
