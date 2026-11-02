# Unified financial architecture validation — 1 November 2026


## Current dimensional architecture

The public catalog has exactly **Withdrawal, Expense, Capital, Revenue and Equipment**. There are **67 system types and 36 internal journal accounts**. The complete discovered operation/effect matrix and exact catalogs are in [financial-type-matrix.md](financial-type-matrix.md). Every journal component carries its type, fixed account, LPG/Stove/Logistics business and source; every journal balances for each business and for consolidation. The existing journal, FIFO, source locks and savepoint foundation remains canonical.

Wallets retain three signed portions whose exact sum equals the total. Shared costs use saved percentages and cent-exact allocations; same-wallet and cross-wallet business transfers reallocate equity without income, expense or inter-business debts. Settings custom types retain revision/category/allocation snapshots with each entry. Returned funds restore original allocations even after editing/deactivation. One equipment asset retains shared ownership through acquisition, improvements, depreciation and disposal.

Internal LPG and optional Stove delivery settles once at dispatch from the buyer business into Logistics Cash Register. It capitalizes onto the original FIFO acquisition/consumption links. Organization reporting eliminates internal revenue, unsold overhead and subsequent internal COGS. Receipt/completion never charges again. Unreceived cancellation restores the original money; performed Stove transport remains earned if received goods return, with its original overhead becoming a buyer return cost and zero consolidated cost.

Analysis, period values, source-linked Historical Activity, Wallet Ledger, filters, charts and PDF use this foundation. Components aggregate account/type/business; activity retains individual sources. Approximate buying prices remain operational references. Empty standalone supplier-commission tables, spending categories/entry contracts and hardcoded ledger classifications were removed after inspecting dependencies and evidence. Applied migrations were not edited.

Existing legitimate stock, prices, payments and source identities were preserved through migration assertions. Obsolete shared metadata was normalized from source/employee business ownership; these reconstructed development allocations do not establish originally documented segment ownership. No arbitrary cash/stock adjustment was used to balance the accounting equation.

## Dimensional source-operation lab

**LPG Unified Financial Development Lab 2026-11-01**, tenant `63907560-fbbd-4ac2-b22b-04bb08f0b123`, is retained separately from the original FIFO lab. Credentials are only in ignored `.env.financial-test`; original operations/recovery IDs are in ignored `.temp/financial-business/manifest.json`. Its **55 original source events** span August–November: explicit opening investments/vehicle, seven LPG/Stove purchases, seven sales, earned monthly rebates and later deductions, internal delivery for both buyer businesses, partial/split payments, collections, shared electricity/equipment/depreciation, Home withdrawals, external income, loan principal, credit-funded improvement, same-wallet reallocation, a negative Logistics bank portion and a browser-created expense/actual return. No genuine business was repurposed or reset.

`financial-independent.mjs` imports no application accounting code and reads no journals, cost pools or reports for expectations. Integer-money source calculations match **16 closing organization/business cutoffs and 16 monthly period reports**, including every period activity field and all wallet portions. Actual checkout/collection dates remain separate from backdated invoice recognition.

| Closing scope, 2026-11-01 | Assets (Tk) | Liabilities (Tk) | Equity (Tk) | Accumulated profit (Tk) |
| --- | ---: | ---: | ---: | ---: |
| Consolidated organization | 909,400 | 102,700 | 806,700 | 21,700 |
| LPG | 473,000 | 81,400 | 391,600 | 6,600 |
| Stove | 143,000 | 21,300 | 121,700 | 1,700 |
| Logistics | 305,400 | 10,000 | 295,400 | 15,400 |

Business profits total Tk 23,700; Tk 2,000 internal profit remains in unsold stock, giving consolidated profit Tk 21,700. Negative cash portions are presented consistently within business positions. Consolidated cash is Tk 530,100; every wallet equals its three business portions. Across all businesses, external FIFO value Tk 13,311,713.40 equals consolidated inventory; internal FIFO Tk 2,000 explains business inventory Tk 13,313,713.40.

Live global checks found **zero** business/consolidated journal imbalances, missing/invalid type-business lines, wallet sum discrepancies and unresolved/error reconciliation findings. Typed savepoints match full journal recomputation for both business and consolidated amounts at eight cutoffs across the two retained labs. The original 641-event FIFO lab plus its reviewed source addendum matches independent six-period and all-time expectations below. The addendum records a genuine later Tk 4,500 principal repayment from its original finance request; no fixture inputs, wallet money or loan balances were adjusted to conceal it.

## Delivery and architecture

The development VPS at `144.79.249.4` and its existing Cloudflare Worker use canonical FIFO and monthly LPG commissions. Finance navigation is Analysis, Wallet Ledger and Loans. Duplicate activity, spending-history, customer-dues and capital interfaces are removed. Adjust Balance retains opening cash, capital investments, corrections, fixed assets and recorded obligations. Loans contains only loan operations. Customers has a shorter search and current money-only, bottle-only, both and neither filters, evaluated before server pagination.

Monthly commission is one effective product/month record with separate Package and Refill amounts. Received quantities and actual Bangladesh-local receipt dates determine the earned month. A later deduction defaults to the preceding calendar month. Missing rates are inferred using received quantity × invoice unit price after accounting for confirmed manual entitlement. Inferences are provisional lower bounds, never a claim that a partial deduction settled the whole month's earnings. A custom save replaces the active pair and adds immutable history; future inference leaves the custom pair intact. Rates and deductions retain revisions, actors, calculation evidence and immutable histories; owner corrections preserve payments and recovery keys. Stoves and unrelated products are excluded.

Private acquisition layers retain original quantity, value, shell allocation and chronological sequence. Consumption links retain partial issues and original-layer restoration. Normal writes update layers incrementally. Historical commissions revalue affected gas acquisitions and consumed costs; backdated physical movements replay connected stock history under ordered SKU locks. Original carrying entries and journals remain, with dated correction deltas. Historical reports use journals and valid month-end savepoints, with no report-duration-dependent valuation or repeated purchase reconstruction.

Filled packages include their shell. Package sales do not also consume a spare empty shell. Refill shell value moves from empty stock through transit, then the filled package and customer bottle receivable, returning to empty stock on physical receipt. Later commission deductions settle earned supplier receivables and reduce cash payable; they never discount the new shipment or create duplicate income. Internal purchase transport is eliminated; actual external costs remain recognized separately.

The accounting equation and cumulative income remain intact. Source writes invalidate affected monthly savepoints atomically. Existing bounded reconciliation workers now check FIFO conservation and monthly commission consistency; no additional service or redundant counter was introduced. Approximate buying-price suggestions and deliberate manual overrides remain operational references.

## Retained isolated business

- Business: **LPG FIFO Development Lab 2026-11-01**.
- Tenant: `a35af806-e5c5-42e6-b600-f57212e1cfc7`.
- Separate owner account: `bbf05338-6ae6-46fd-b974-d88b2479945d`.
- Login credentials remain only in ignored `.env.fifo-test`; no password or session token is included here.
- Original input operations, request IDs and fixture identities: ignored `.temp/fifo-business/manifest.json`. The reviewed `.temp/fifo-business/source-addendum.json` retains the later owner repayment input separately. Preserve both files; expectations use source requests rather than journal/report differences.
- 641 original fixture events plus one later owner-entered loan repayment verified from its original request, 289 sales, 17 purchases, 24 customers, 12 products, 3 employees and 2 vehicles.
- Products comprise 8 LPG brand/capacity/mouth-size variants and 4 stove/supply variants, with retail/wholesale price books and acquisition evidence. No product images were added.
- 24 monthly rates, 8 received commission deductions, 563 stock movements, 249 FIFO acquisition layers and 1,384 financial journals at the final count.

The original burner business remains present. A separate, strictly identified security-fixture account/business was created and cleaned through the established cleanup path; the populated lab was retained. Migration preservation assertions compare existing source identities, invoice prices, payments, filled stock and wallets. The only original stock normalization restored exactly 105 duplicate spare-shell deductions from obsolete package sales, with each original movement archived in `inventory_normalization_audit`. No arbitrary opening balance or invented payment was used.

## Exercised operations

Historical activity spans August–November, with changing acquisition prices and monthly rates. Normal Auth/PostgREST calls exercised mixed package/refill/stove purchases, dispatch and actual dated receipt, partial/multi-wallet payments, later deductions, provisional inference, manual historical overrides and corrections, retail/wholesale sales, partial customer collections, cross-brand bottle returns, outstanding bottles, stock losses, contractual salaries, future-month salary payment, named bonus, loans/principal/interest, spending, withdrawals, investments and wallet transfers.

Additional retained operations cover an external delivery with split client and operating payments, driver/helper settlements, returned/completed transit, service advance and source-backed return, depreciation, vehicle disposal, a backdated repair obligation and partial settlement, sale reversal and staged refund, and received stove purchase cancellation/refund. A genuine pending LPG transit remains available for future tests, including its shell asset and pending commission clearing amount.

Published browser workflows committed an owner investment, spending entry, stove checkout and protected historical monthly-rate confirmation. Retries retain the original request payloads/IDs. The subsequent independent reconciliation includes these writes.

## Independent financial reconciliation

`supabase/tests/fifo-independent.mjs` calculates integer-money FIFO queues, original-layer returns, commissions, cash, receivables, liabilities, capital, revenue and expenses from the original operation manifest. It does not read accounting journals, SQL cost pools, snapshots or report values as its expectations. `fifo-business.mjs --vps` compares both positions, all significant account components, every current wallet/product and current customer dues to those independent expectations. It also checks every trend bucket and the original all-time opening position.

Final closing values at **2026-11-01**, in Tk:

| Component | Independent expectation = application |
| --- | ---: |
| Cash and wallets | 1,065,479.00 |
| Customer receivables | 616,900.00 |
| FIFO inventory and supplies | 3,438,332.25 |
| Cylinder shells with customers | 120,000.00 |
| Inventory in transit | 8,700.00 |
| Earned supplier commission / credits | 31,584.02 |
| Vehicles | 800,000.00 |
| Equipment | 74,000.00 |
| Supplier payables | 973,331.00 |
| Loan principal | 95,500.00 |
| Unpaid employee earnings | 83,800.00 |
| Operating obligations | 30,000.00 |
| Other unpaid obligations | 4,000.00 |
| Pending commission clearing liability | 75.00 |
| Capital | 4,986,751.00 |
| Cumulative revenue | 1,164,945.00 |
| Cumulative expenses | 1,138,406.73 |
| Owner withdrawals | 45,000.00 |
| Total assets | 6,154,995.27 |
| Total liabilities | 1,186,706.00 |
| Owner’s equity | 4,968,289.27 |
| Accumulated income | 26,538.27 |

All compared figures matched to the cent. Independent original opening: assets Tk 4,986,750.00, liabilities Tk 50,000.00, net opening capital/equity Tk 4,936,750.00, accumulated income zero.

| Interval | Independently calculated period profit/loss (Tk) |
| --- | ---: |
| 2026-08-01–2026-08-31 | 17,280.00 |
| 2026-09-01–2026-09-30 | 41,750.00 |
| 2026-10-01–2026-10-31 | 9,308.27 |
| 2026-08-15–2026-10-20 | 79,168.65 |
| 2026-01-01–2026-11-01 | 26,538.27 |
| 2026-08-01–2026-11-01 | 26,538.27 |
The separately requested all-time report also matches. The dimensional lab's exported report also matches independently calculated profit, assets/liabilities/equity, stock acquisitions and shared equipment acquisitions; its three pages were rendered and inspected. Monthly chart buckets are checked independently, including November's Tk −41,800.00 period loss. The exported three-page all-time PDF contains the same positions, components, period income and trend values; first/last pages were rendered and visually inspected.

Live savepoint-backed balances matched a full journal aggregation at six arbitrary/month-end cutoffs for both retained businesses (12 comparisons). All current FIFO pools equal their unconsumed layers. Wallet reconciliation differences, unbalanced journals, invalid published snapshots and unresolved/error reconciliation findings were zero. Five scheduled jobs remain active; recent minutely maintenance/snapshot executions succeeded. Daily, weekly and month-end schedules were inspected, rather than claiming that a future scheduled firing was observed.

## Defects and inconsistencies corrected

- Package sales consumed both their filled package and an unrelated empty shell; audited normalization removes the duplicate consumption.
- Weighted-average inventory mixed distinct acquisition batches; FIFO now retains and consumes their individual costs and restores original layers on reversal.
- Purchase commission deductions discounted the new acquisition; monthly earned-batch revaluation and supplier-receivable settlement now separate entitlement from payment.
- Static refill/package commission estimates had no monthly entitlement or partial-deduction model; monthly history, protected manual rates and provisional inference replace that path.
- Direct stove receipts could acquire stock locks after beginning recognition; receipts now lock the complete ordered SKU set first.
- Approximate buying-price refresh used the entry/current month instead of the latest invoice's actual received month; historical monthly rates now refresh the correct automatic reference while preserving manual overrides.
- Customer directory dues omitted opening receivables (observed Tk 12,450 versus Tk 19,450); unscoped dues/sorts now use the current ledger, consistently with the filter.
- Per-customer bottle-history traversal made the dues filter expensive; set-based predicates replace it.
- Removed obsolete commission editor/history branches, independent commission creation/apply actions and redundant Finance activity UI. Historical source records remain readable through audited accounting evidence.
- Test infrastructure corrections include Bangladesh-month boundaries, scoped private benchmark expectations and explicit platform Storage fixtures for empty replay. No browser grants were weakened to make tests pass.

No permission bypass or cross-tenant mutation succeeded in the performed probes. This is evidence for the tested boundaries, not proof against every possible vulnerability. Supabase advisories still list intentional deny-all RPC-managed/private tables and authenticated SECURITY DEFINER entry points: 80 informational no-policy notices and 128 function-grant warnings at review. The functions derive tenant/actor and check permissions internally; real role/RLS probes pass. See [advisory guidance](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy).

## Automated, database and browser verification

Passed:

- TypeScript/Vite build, ESLint and whitespace/diff checks.
- 57 application tests, 5 attendance-receiver tests, 16 print-bridge tests, 10 deployment Node tests and 20 deployment Python tests.
- Disposable native PostgreSQL suites: system dimensions, Stove internal delivery, custom types/returns, shared payroll/advances/reassignment, FIFO/commissions, authorization, opening-transit continuation and accounting overview/savepoints.
- Concurrent monthly edits, shared expenses/partial return ceilings, exactly-once internal dispatch and eight matching retries; loan repayment across wallets; duplicate repayment; depreciation ceiling; cancellation versus checkout; snapshot building versus backdated writes; coherent report reads during concurrent changes.
- Comprehensive resumed reconciliation of the restored operational database, with zero findings.
- Attendance/employee SQL, effective-link history, corrections, appearance, tenant isolation and eight-session raw-event deduplication.
- All **88** migrations replayed from empty in disposable PGlite PostgreSQL 18.6 with minimal Auth/Storage platform relations, followed by system dimensions, Stove delivery, custom types, shared payroll, Package/Refill invoice-price allocation, Financial Entries/ledger filters, FIFO, authorization and overview suites. This complements native PostgreSQL 17.6 restored-database migration/concurrency tests; PGlite does not verify platform services or simultaneous sessions.
- Real Auth/PostgREST isolation probes: foreign reads/writes/report scope and custom type mutation/recognition, catalog isolation, direct financial/type/rate write denial, anonymous denial, stale monthly edits and retired contract removal (17 probes). Counterparty fixture cleanup was verified.
- HTTPS/Auth/Storage health, CORS allowed/hostile origins, blocked private routes, invalid API key rejection, public-only JWKS, trusted ES256 Auth and a disposable Realtime WebSocket round trip.
- Intercepted responsive Finance/PDF/inventory/stove-POS checks at 1440, 768, 390 and 320 px.
- Published correction acceptance at 1440, 375 and 320 px in light/dark themes: actual wallet rows (including payroll), exactly five category options, removed organization selector, financial-entry directory/filter/detail, compact breakdowns, a real Package/Refill modal save with one added history revision in a zero-receipt test month, LPG photo/value-block removal and independent Stove pricing/activity/source links. REST failures and page errors were both asserted absent. An early harness failure clicked a loading skeleton; the test now waits for actual product buttons.
- Published dimensional entry/actual return, original source links, all four report scopes, custom allocation validation, negative wallet portions, same-wallet transfer forms and optional Stove delivery forms at desktop and Pixel 7 Android emulation in both themes. Wallet child containment/overlap assertions supplement screenshots; the obsolete fixed wallet-card height was corrected. A separate burner run passed 102 read-only page/modal checks.
- Published login and ten major modules at desktop 1440 px and touch/mobile 375 px, light/dark themes: 40 page configurations, primary forms, all visible Overview breakdowns, Finance navigation, current dues filters, mobile position switching and saved-record/nested buying-price, commission and payroll dialogs. All nine Settings sections, device registration, vehicle overview/transit/assignment/service tabs, saved transit/service records and the transit directory were also checked at all four theme/viewport combinations. No uncaught page errors or measured workspace/dialog horizontal overflow.

The optional legacy-data replay mode also passed earlier historical module/preservation suites, but stops at the already-applied historical reconstruction migration when an intentionally obsolete synthetic stock movement has no accounting source/value. That fixture-combination mode is not claimed passing. Empty installation replay and migration rehearsal against the actual retained business history pass; applied migration files were not edited to accommodate obsolete fixtures.

## Performance

On the existing VPS, using a disposable copy and constrained writes:

| Measurement | Result |
| --- | ---: |
| 5,000-customer dues sort | 40.66 ms median |
| 5,000-customer sales sort | 42.27 ms median |
| Current money/bottle dues filter | 52.52 ms median (552.19 ms before set-based correction) |
| Finance over 30,000 historical journals | 119.08 ms median (249.58 ms full-history baseline) |
| Two-line journal write with invalidation | 1.212 ms/journal (1.190 ms baseline) |
| Additional 20,000 journals / 40,000 lines report | 809–838 ms round trip, exact reconciliation |
| Retained-business six interval Auth/API reports | 91–115 ms in the dimensional acceptance run |

Customer and Finance responses remained approximately 12 KiB and 5 KiB. These single-session measurements do not establish sustainable concurrent-user capacity. Rare historical stock replay/rate revaluation is more expensive than incremental normal writes; larger correction workloads were not load-tested to saturation.

## Deployment and remaining boundaries

Ten financial forward migrations were applied through the backup-protected workflow: `20261101061928`, `20261101062408`, `20261101062508`, `20261101063202`, `20261101063916`, `20261101070832`, `20261101072446`, `20261101091400`, `20261101121900`, `20261101123000`. The deployed schema contains **88 migrations**. Eleven backend services, public HTTPS health and the existing Cloudflare Worker publication passed; Azure remained untouched. Recovery backups include `/opt/lpg/backups/deployment-20261101T070432937828Z`, `/opt/lpg/backups/deployment-20261101T073615255019Z` and `/opt/lpg/backups/deployment-20261101T091457301178Z`. The final migration check showed no pending versions. The current publication is verified through the existing Worker URL; deployment evidence is retained in ignored `.temp/financial-business/corrections-deployment.log`.

Physical Android/PWA installation, actual ZKTeco hardware, physical printer output and external bank/mobile-provider settlement were not verified. Browser emulation and software rendering do not establish those hardware/provider outcomes. The Dashboard stock-exception panel remains the documented placeholder. The current project has no separate multi-warehouse transfer workflow; purchase transit and cross-product bottle receipt flows were tested. This audit does not claim every arbitrary input sequence, exhaustive security proof or a new concurrent-capacity limit.

Re-run dimensional source/period verification with `npm run finance:dimensions:api:test`, published dimensional forms with `node tests/financial-dimensions.browser.mjs --vps`, source reconciliation with `node supabase/tests/fifo-business.mjs --vps`, API/security/site acceptance with `npm run accounting:api:test`, current native/concurrency/performance tests with `node supabase/tests/run-unified-accounting.mjs --vps --performance`, and empty migration replay with `node supabase/tests/run-purchases.mjs --replay-module <PGlite package directory> --schema-only`. Preserve the lab login and original-operation manifest; remove only explicitly created disposable fixtures.
