# Backend read performance

[Architecture](../architecture.md) · [Customers](customers.md) · [Purchases](purchases-and-logistics.md)

## Read boundaries

- Customer directory: unscoped name ordering aggregates only displayed customers. Monetary sold/due and Last Sale ordering, plus date/product/activity filters, aggregate the matching scope before selecting a page. Both paths reuse one relational metrics query: scoped sale headers, grouped selected-product quantities, then per-customer aggregation. Whole-sale amounts and current outstanding balances are counted once per sale; no duplicate counters or sale-write triggers are introduced. See [Customer rules](customers.md).
- Customer history: matching sale headers supply the exact count and page. Product quantities and descriptions are built only for that page; product-filtered quantities, saved sale tiers and Dhaka date boundaries retain their existing meaning.
- Purchases: `get_purchase_directory` returns an exact filtered count and at most 100 detailed orders; directory requests use fixed batches of 25. Customers and Purchases cache these batches independently of display pages, which show three desktop rows or ten phone cards. Navigation and column changes reuse cached batches; only missing ranges are fetched. Existing mutations invalidate batch caches and active reads retain their 30-second refresh. `get_purchase_overview` uses only headers for unfiltered business totals. `get_purchases_by_ids` bounds explicit selection to 100 IDs. Inventory history uses IDs from its current page instead of downloading all purchases.
- Purchase detail caching is independent of directory filters/pages. All purchase query families invalidate after mutations, and dirty forms keep their original revision checks. Existing `list_purchases` remains backward compatible, but the application no longer uses it.

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

`supabase/tests/customers.sql` checks the shared reporting scope, monetary sorts, dues and history date/product quantities. `supabase/tests/reporting.sql` checks bounded purchase pages/details, complete summaries, search/filter/date/sort behavior, legacy detail parity and tenant/capability boundaries. Both roll back their fixtures and run in the existing disposable migration replay. Browser fixtures cover purchase save/lifecycle behavior, selection across pages, history links and responsive layouts. The migration was deployed on 2026-10-20 with all seven SQL suites passing on Azure PostgreSQL, unchanged business-data fingerprints, healthy services and matching published frontend assets. Authenticated published-browser checks covered purchase search/details and customer profile/history, including a phone-width dialog.

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

## Current development-VPS capacity

The [2026-10-23 load report](../reports/2026-10-23-customer-load-test.md) holds 640 businesses, 1.28 million customers and 12.8 million sales/lines fixed while testing 10–640 active businesses, one sequential user each. With 1.5–2.5 seconds of think time, the 40-user stage had zero errors and a 439 ms successful-response p95. The 80-user stage had 32.74% timeouts; the 640-user stage had 92.05%. Simultaneous Total Sold bursts are reported separately: 40 requests had a 2.69-second p95. This is a short customer-reporting benchmark on the existing two-vCPU/4-GiB burstable VM with a 1-GiB database cap and ten pooled queries; it does not establish whole-application or long-duration production capacity.

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
