# Backend read performance

## Current Finance and maintained-balance audit

The November 2026 Overview uses cumulative month-end savepoints plus indexed subsequent journals. Financial-position trends scan the selected activity once and apply per-account/entity running windows, including liability/advance sign changes. Historical action and component responses have separate bounded 20-row pages; actual journal lines remain independently paged. No browser history download supplies a balance.

Financial writes now collect equivalent effects and post once per action/date, preserving detailed source/FIFO evidence. The [current storage/posting audit](../audits/summarized-accounting-2026-11-05.md) records physical compaction, before/after row/tuple measurements and unchanged financial reports. The older synthetic benchmarks below are historical measurements, not a fresh throughput result for the collector. Run `npm run accounting:db:test` for the current isolated upgrade, source/reconciliation/concurrency and small/large action-storage fixtures.

| Workload reviewed | Current decision |
| --- | --- |
| Inventory/catalog/product | Reuse `items` quantities and FIFO `inventory_costs` and private cost layers; cost/movement history is server-paged. Do not add duplicate quantity/value counters. |
| Customer directories/profile/lifetime | Atomically maintained private `customer_metrics` for ledger balance, lifetime invoice/quantity/dues totals and last sale. Unfiltered sorting uses these rows; date/product scopes keep canonical indexed aggregation. |
| Sales/purchases/dues | Retain stored invoice/payment totals and bounded directories/details. Add a tenant/date partial index on completed unpaid sale headers. Filtered exact counts still scale with the matching scope. |
| Wallets/ledger | Reuse the canonical wallet posting trigger and stored balance; retain indexed, server-paged ledger/search. Reconciliation compares both immutable wallet ledger and accounting cash. |
| Employees/payroll | Keep effective-dated salary rules and paged payment/activity histories. A tenant/month accounting sync marker removes repeated historical accrual traversal; new terms invalidate it under the existing payroll lock. |
| Logistics/vehicles/transits | Retain journal-backed earned/incurred totals and bounded directory, activity and wallet-audit reads. Reconcile transit recognition and cost events; no extra profit counters. |
| Loans/assets/obligations/company rebate credit | Reuse existing transactional outstanding, depreciation, settlement and immutable rebate events; derive company credit from those events and compare with canonical journals. |
| Dashboard | Retain selective indexed current-day aggregates and existing inventory/wallet values. Day boundaries now consistently use Asia/Dhaka. Avoid unnecessary lifetime counters for daily workload. |
| Finance | Shared savepoint-backed cumulative positions, paged breakdowns and one-pass trends; no separate monthly/yearly valuation or estimated-price costing. |

Native disposable PostgreSQL 17.6 measurements on the primary VPS, five warm runs on identical **5,000-customer / 30,000-sale / 60,000-sale-line / 30,000-historical-journal** fixtures:

| Read | Before median | After median |
| --- | ---: | ---: |
| Customer Total Sold page | 183.33 ms | 43.09 ms |
| Customer Total Due page | 181.73 ms | 45.05 ms |
| Current-month Finance report | 293.44 ms | 58.93 ms |

Customer results were identical, returning 25 rows / 12,203 bytes. Finance positions were identical; the new response also includes expanded equity and position-trend fields (5,236 bytes versus 5,218). A 500-journal write batch, including existing source and deferred balancing constraints, took 269.25 ms before and 303.46 ms after: **0.538 → 0.607 ms per journal**. Avoiding repeated dirty-state updates and a redundant per-journal reconciliation queue kept measured projection overhead to about 0.069 ms per journal. Individual immutable journals retain transaction-time constraints and weekly verification.

These are single-session synthetic database measurements, not end-user latency, concurrency capacity or a sustainable VPS user cap. The additional 20,000-current-journal report retained exact reconciliation, with approximately 720–800 ms whole SSH/psql round trips. Initial savepoint construction, very broad date/product filters, exact counts and searches still depend on matching history; do not infer constant time for arbitrary workloads. Reconciliation uses bounded batches, persisted sweep cursors and scheduled timeouts rather than large nightly rebuilds.

The current `npm run accounting:db:test` restores a read-only VPS capture into a uniquely named disposable database, rehearses pending upgrades without changing original evidence, then runs source/snapshot correctness, action-storage and concurrency fixtures in that clone. It does not modify application business records. Legacy customer benchmark suites remain at their historical migration replay boundary; the older median timings are not regenerated by the current action-storage fixture.

[Architecture](../architecture.md) · [Customers](customers.md) · [Purchases](purchases-and-logistics.md)

## Read boundaries

- Customer directory: unscoped name ordering aggregates only displayed customers. Monetary sold/due and Last Sale ordering, plus date/product/activity filters, aggregate the matching scope before selecting a page. Both paths reuse one relational metrics query: scoped sale headers, grouped selected-product quantities, then per-customer aggregation. Whole-sale amounts and current outstanding balances are counted once per sale; no duplicate counters or sale-write triggers are introduced. See [Customer rules](customers.md).
- Customer history: matching sale headers supply the exact count and page. Product quantities and descriptions are built only for that page; product-filtered quantities, saved sale tiers and Dhaka date boundaries retain their existing meaning.
- Purchases: `get_purchase_directory` returns an exact filtered count and at most 100 detailed orders; directory requests use fixed batches of 25. Customers and Purchases cache these batches independently of display pages, which show three desktop rows or ten phone cards. Navigation and column changes reuse cached batches; only missing ranges are fetched. Existing mutations invalidate batch caches and active reads retain their 30-second refresh. `get_purchase_overview` uses only headers for unfiltered business totals. `get_purchases_by_ids` bounds explicit selection to 100 IDs. Inventory history uses IDs from its current page instead of downloading all purchases.
- Purchase detail caching is independent of directory filters/pages. All purchase query families invalidate after mutations, and dirty forms keep their original revision checks. The obsolete `list_purchases` API is removed; bounded directory and by-ID reads are authoritative.

The additive migration is `20261020025616_scalable_reporting_reads.sql`. New public RPCs derive the tenant from active membership and require purchase read/manage capability. Private query helpers have no authenticated execution grant. Existing stock, ledger, sale and purchase mutation routines are unchanged.

## Measurements and verification

The 2026-10-20 production inspection verified PostgreSQL 17.6 on the existing Azure API through its loopback MCP gateway. At inspection the database had 13 sales, eight customers and nine purchases. Accumulated PostgREST query statistics showed customer profile/history means of approximately 6–7 ms, so they do not establish that the reported 400–500 ms modal delay is database execution time.

A disposable PostgreSQL 17.5/PGlite benchmark added 30,000 sales, 60,000 sale lines and 5,000 purchases to isolated fixtures. Median of five warm runs on the same engine:

| Read | Previous | Optimized |
| --- | ---: | ---: |
| Six-customer directory | 76 ms | 7 ms |
| Four-transaction history | 72 ms | 3 ms |
| Six-purchase page | 230 ms / 5.8 MB | 4 ms / 7 KB |

Purchase comparison includes the old application's full-list response versus the new page response. These are synthetic engine/serialization measurements, not browser or production latency guarantees. Existing indexes support the tenant/customer/sale/item joins; no speculative indexes are added from small-table advisor recommendations.

`supabase/tests/customers.sql` checks the shared reporting scope, monetary sorts, dues and history date/product quantities. `supabase/tests/reporting.sql` checks bounded purchase pages/details, complete summaries, search/filter/date/sort behavior, directory/by-ID detail parity and tenant/capability boundaries. Both roll back their fixtures and run in the existing disposable migration replay. Browser fixtures cover purchase save/lifecycle behavior, selection across pages, history links and responsive layouts. The migration was deployed on 2026-10-20 with all seven SQL suites passing on Azure PostgreSQL, unchanged business-data fingerprints, healthy services and matching published frontend assets. Authenticated published-browser checks covered purchase search/details and customer profile/history, including a phone-width dialog.

## Customer filtering verification

`20261022165522_unified_customer_filtering.sql` unifies customer monetary totals, dues, Last Sale and activity thresholds. The optional `customer-performance.sql` suite exercises 10,000 customers, 60,000 sales and 180,000 lines across two tenants, reports five-run median timings and bounded response sizes, and prints `EXPLAIN (ANALYZE, BUFFERS)` for the metrics query. Fixtures run in a disposable engine and roll back; results do not establish production browser latency.

Final five-run medians with the same two-tenant fixture (25 records, about 12 KB per response):

| Read | Disposable PostgreSQL 17.5/PGlite | VPS PostgreSQL 17.6, before retry-loop fix |
| --- | ---: | ---: |
| Unfiltered name page | 7 ms | 359 ms |
| Total Sold | 93 ms | 3,303 ms |
| Total Due | 92 ms | 3,201 ms |
| Last Sale | 92 ms | 3,531 ms |
| Product/date/ranges, offset 2,400 | 77 ms | 2,580 ms |

The VPS column was collected before diagnosing five PostgREST requests repeatedly retrying permanent stale-revision errors (observed host load about 8 and database container CPU about 342%). Those historical timings include that abnormal background workload and do not establish idle capacity. Migration `20261022181704_nonretryable_stale_edit_errors.sql` replaces custom `40001` validation errors with `P0001`; all five old requests ended and database CPU returned near idle. [Supabase documents this PostgREST 14 retry behavior](https://supabase.com/kb/troubleshooting/high-cpu-and-infinite-transaction-retries-when-using-custom-error-codes-in-rpc-functions). Exact aggregation/counts still grow with matching sales; capacity must be measured with representative tenant data and concurrency.

The expanded scope plan uses hash joins and existing tenant/date and tenant/item/sale indexes. Keeping candidates relational reduced the disposable-engine scope plan from about 121,000 buffer hits to 3,500. Repeated scope changes also exposed an expensive generic cached plan on native PostgreSQL; `20261022173140_customer_directory_custom_plans.sql` sets function-local `plan_cache_mode=force_custom_plan`. This keeps plan choice specific to the actual scope without introducing reporting counters or changing settings for other RPCs. All correctness suites, real Auth/PostgREST, published browser acceptance and preservation fingerprints passed; the disposable database was removed after measurement.

## Historical Azure reporting capacity

Historical load testing held 640 businesses, 1.28 million customers and 12.8 million sales/lines fixed while testing 10–640 active businesses, one sequential user each. With 1.5–2.5 seconds of think time, the 40-user stage had zero errors and a 439 ms successful-response p95. The 80-user stage had 32.74% timeouts; the 640-user stage had 92.05%. Simultaneous Total Sold bursts are reported separately: 40 requests had a 2.69-second p95. This is a short customer-reporting benchmark on the existing two-vCPU/4-GiB burstable VM with a 1-GiB database cap and ten pooled queries; it does not establish whole-application or long-duration production capacity.

A separate post-fix PostgreSQL 17.6 replay repeated the earlier two-tenant fixture (5,000 customers, 30,000 sales and 90,000 lines per tenant), with five-run single-session medians:

| Read | Post-fix native median |
| --- | ---: |
| Unfiltered name page | 60 ms |
| Total Sold | 488 ms |
| Total Due | 570 ms |
| Last Sale | 469 ms |
| Product/date/ranges, deep page | 448 ms |

These are engine timings, separate from HTTP load-test latency. The expanded scope plan took 319 ms and used 220 temporary blocks read/written at the configured 4-MiB work memory. The primary 20,000-sale/one-line-per-sale load fixture showed no temporary-file spills. Retain that distinction when sizing memory for larger or multi-line histories. All nine native correctness suites and checkout, stock, purchase, collection/refund and transfer races passed; only disposable databases were removed.

## Remaining growth work

- POS customer lookup still reads all candidates in batches and ranks them in the browser. Move ranking, paging and exact-phone detection together to the backend to preserve selection and duplicate-phone behavior.
- POS price reads still include historical price-book rows. A bounded active-price API must preserve effective-date windows and wholesale-to-retail fallback.
- Exact counts, deep offset pages and unindexed substring search still grow with matching data. Consider cursor pagination or compatible search indexes after measuring representative query plans and preserving current AND/OR and literal-search semantics.
- Persisted customer or daily summaries can help scoped reporting later, but require atomic maintenance, backfill/reconciliation and concurrency tests. Measure read and write workloads before adding that state.

## Primary VPS mixed-workload capacity

The 29 October BDIX benchmark confirmed 11 independent active businesses for 30 measured minutes, with 10 the comfortable tested point and 12 failing the read p95 target. Fixtures contain 2,000 customers and 20,000 historical invoices per tenant, reconciled stock/payment/ledger evidence, and real Auth/public HTTPS reads and writes. That baseline used a 1 GiB PostgreSQL cap with ten PostgREST pooled connections. The VPS now has a 2.5 GiB database budget; tuned capacity is being measured separately. Host RAM remained available; cache/read pressure and broad reporting calls are the leading constraint. This is a defined busy workload, not a universal user limit or a directly comparable Azure result. Reusable tooling is under `supabase/tests/vps-capacity/`; no application optimization or deployment configuration change was made.

## FIFO and current dues verification

The November 1 disposable VPS benchmark retained all journal constraints. With 5,000 customers, 30,000 sales, 60,000 lines and 30,000 journals, median reads were 40.66 ms for current money dues, 42.27 ms for sales sorting, 52.52 ms for the combined current dues filter, and 93.67 ms for Finance versus 307.57 ms for full historical aggregation. Set-based bottle predicates replaced per-customer traversal (552.19 ms before). Responses remained about 12 KiB / 5 KiB. Five hundred two-line journals averaged 0.698 ms each with savepoint invalidation, versus 0.614 ms without that projection trigger. A separate 20,000-journal / 40,000-line report reconciled exactly in 584–650 ms round trips. These are bounded single-session development measurements, not concurrent-user capacity claims.

FIFO reads use maintained layers/current cost pools; reports use dated journals and valid monthly savepoints. Normal writes maintain layers incrementally. Rare historical stock changes replay connected tenant stock chronologically; historical monthly rate changes rebuild affected products. These corrective writes cost more than normal receipt/sale writes and should be measured separately at larger historical volumes.
