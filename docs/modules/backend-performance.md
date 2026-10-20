# Backend read performance

[Architecture](../architecture.md) · [Customers](../../customer%20module%20report.md) · [Purchases](purchases-and-logistics.md)

## Read boundaries

- Customer directory: the common unscoped name-sort path aggregates sales for displayed customers only. Quantity sorting and date/product/activity filters still aggregate the full matching scope before selecting a page. Lifetime totals remain derived from completed sales; no duplicate counters or sale-write triggers are introduced.
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

`supabase/tests/customers.sql` checks fast/full-path parity and history date/product quantities. `supabase/tests/reporting.sql` checks bounded purchase pages/details, complete summaries, search/filter/date/sort behavior, legacy detail parity and tenant/capability boundaries. Both roll back their fixtures and run in the existing disposable migration replay. Browser fixtures cover purchase save/lifecycle behavior, selection across pages, history links and responsive layouts. The migration was deployed on 2026-10-20 with all seven SQL suites passing on Azure PostgreSQL, unchanged business-data fingerprints, healthy services and matching published frontend assets. Authenticated published-browser checks covered purchase search/details and customer profile/history, including a phone-width dialog.

## Remaining growth work

- POS customer lookup still reads all candidates in batches and ranks them in the browser. Move ranking, paging and exact-phone detection together to the backend to preserve selection and duplicate-phone behavior.
- POS price reads still include historical price-book rows. A bounded active-price API must preserve effective-date windows and wholesale-to-retail fallback.
- Exact counts, deep offset pages and unindexed substring search still grow with matching data. Consider cursor pagination or compatible search indexes after measuring representative query plans and preserving current AND/OR and literal-search semantics.
- Persisted customer or daily summaries can help scoped reporting later, but require atomic maintenance, backfill/reconciliation and concurrency tests. Measure read and write workloads before adding that state.
