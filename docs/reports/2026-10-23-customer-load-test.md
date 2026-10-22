# Customer reporting load test — 23 October 2026

The existing Azure development VPS passed the **40-active-user sustained stage** under the interpretation below; the first failing requested stage was **80 active users**. At 640 active users, **92.05%** of sustained requests failed. This server is not ready for 640 simultaneously active businesses using this reporting profile.

Each active business had one user, 2,000 customers and 20,000 completed sales. **All 640 businesses remained stored throughout every final stage.** The 1,280-business stage was cancelled at the user's request.

## Environment and data

- Azure development target `20.40.48.3`, `/opt/lpg`: `Standard_B2als_v2`, Central India, two vCPUs, 4 GiB RAM. The separate future production VPS was not used.
- Existing PostgreSQL 17.6 container: **1 GiB memory limit**, 256 MiB shared buffers, 4 MiB work memory, 80 maximum connections. Other existing Supabase services remained running.
- Separate loopback-only PostgREST 14.17 container, using the deployed image: 192 MiB limit, **10 pooled database connections**, 10-second pool-acquisition timeout. Requests used normal authenticated permissions and actual migration RBAC/RLS. Only the disposable DB used a miniature Auth schema and fresh signing key; GoTrue login capacity was not measured.
- Exact SQL counts: **640 businesses, 640 identities, 1,280,000 customers, 12,800,000 sales and 12,800,000 sale lines**. Size including indexes: **9.01 GiB**. Two products per business; January–March 2026 sales have known partially paid headers. IDs repeat across tenants to check composite-key isolation.
- This read fixture has one line per sale and no reconciled historical stock/payment ledger. Multi-line carts can require more work. Real checkout and subsequent-payment correctness were checked separately. Triggers were disabled only while constructing this new disposable database, then restored before requests.

Final sequence: **01:04:59–01:22:27 Asia/Dhaka**. Exact counts, completed background vacuum work and a checkpoint preceded it; seeding was excluded from the measurements.

## Method and interpretation

Each stage starts one concurrent **Total Sold** request per business, waits 10 seconds, then runs 20 seconds of warmup and **90 seconds of measured request admission**. Each business has one sequential user with **1.5–2.5 seconds of think time after a response**. No client retries; HTTP timeout 30 seconds; admitted requests drain before at least 15 seconds of cooldown.

Mix: 30% name pages, 15% exact-phone search, 15% Sold, 15% Due, 10% Last Sale, 15% combined product/date/activity filters. Directions vary; 25-row pages include deep offsets. Every successful response checks every returned tenant/customer, exact count/page size, money, quantities, direction and deterministic ties.

The generator ran on Windows outside the VPS, through **eight independent SSH forwards** to the same isolated API. The pre-final transport control passed **640/640 lightweight requests, p95 273 ms**. The exploratory single-tunnel 320-user results had connection errors and are excluded. Final figures use corrected transport and a fixed database.

For interpretation, a sustained stage passes with **successful-response p95 ≤1 second and observed errors <1%**. This is a report criterion, not an agreed SLA. The exact threshold between 40 and 80 users was not measured.

## Sustained results

Times are seconds and describe successful requests admitted during the measured window, including drain. Errors are separate. OK/s counts successful measured requests completed inside the 90-second window, excluding late completions.

| Active businesses/users | Attempts | OK/s | p50 | p95 | p99 | Errors |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 10 | 424 | 4.71 | 0.11 | 0.20 | 0.32 | 0.00% |
| 20 | 850 | 9.43 | 0.11 | 0.23 | 0.37 | 0.00% |
| 40 | 1,638 | 18.18 | 0.13 | 0.44 | 0.71 | 0.00% |
| 80 | 901 | 6.24 | 3.60 | 10.82 | 13.02 | 32.74% |
| 160 | 1,973 | 15.50 | 2.86 | 9.72 | 11.95 | 26.36% |
| 320 | 2,547 | 3.97 | 5.37 | 12.91 | 13.90 | 83.78% |
| 640 | 4,921 | 3.62 | 5.41 | 13.66 | 14.78 | 92.05% |

Total: **13,254 measured requests**, **5,775 successful responses checked**, **zero response-correctness failures**. Errors: `{"PGRST003": 7479}`. These are single short stages; overloaded results can vary with cache state and scheduling. Closed-loop users self-limit their request rate while awaiting responses, so error rates need not rise monotonically. Do not treat peak throughput as guaranteed capacity.

## All businesses request Total Sold together

One heavy request per business starts concurrently, without think time. This is separate from sustained usage and does not include a complete page's multiple requests. Caches were not globally flushed.

| Concurrent businesses/requests | Successful | Success p95 (s) | Errors |
| ---: | ---: | ---: | ---: |
| 10 | 10/10 | 0.86 | 0.00% |
| 20 | 20/20 | 1.28 | 0.00% |
| 40 | 40/40 | 2.69 | 0.00% |
| 80 | 80/80 | 6.03 | 0.00% |
| 160 | 35/160 | 11.53 | 78.12% |
| 320 | 33/320 | 12.02 | 89.69% |
| 640 | 35/640 | 13.00 | 94.53% |

Use these burst figures when interpreting “at the same time”; staggered use has a different latency limit.

## Request breakdown

Cells: **successful p95 seconds / error percentage**. Cheap reads share the pool with broad reports and can queue behind them.

| Request | 40 active | 80 active | 640 active |
| --- | ---: | ---: | ---: |
| name | 0.17 / 0.0% | 9.40 / 33.8% | 10.55 / 91.2% |
| search | 0.16 / 0.0% | 9.75 / 28.9% | 10.24 / 92.8% |
| sold | 0.54 / 0.0% | 12.00 / 33.3% | 14.49 / 90.7% |
| due | 0.53 / 0.0% | 11.88 / 27.5% | 13.98 / 93.6% |
| last_sale | 0.63 / 0.0% | 12.09 / 32.0% | 12.82 / 92.8% |
| combined | 0.45 / 0.0% | 10.77 / 38.9% | 14.49 / 92.2% |

## Resource evidence

Five-second samples. DB CPU uses **100% = one core**; host busy covers both vCPUs. Buffer-block reads can include OS-cache hits and are not physical-disk bytes.

| Active users | Median DB CPU | Median host busy | Max active queries | Observed buffer-block reads |
| ---: | ---: | ---: | ---: | ---: |
| 10 | 20% | 17% | 2 | 85 |
| 20 | 45% | 31% | 4 | 548 |
| 40 | 103% | 61% | 10 | 208,416 |
| 80 | 142% | 100% | 10 | 187,391 |
| 160 | 146% | 87% | 10 | 682,708 |
| 320 | 132% | 100% | 10 | 177,557 |
| 640 | 126% | 100% | 10 | 167,728 |

The database reached its 1 GiB memory ceiling, including shared memory/file cache. Higher load occupied all ten working query slots. Samples showed CPU work and data-file reads, with no observed deadlocks, out-of-memory kills or temporary-file spills. `PGRST003` / HTTP 504 means a request timed out acquiring a pooled connection; it does not mean PostgreSQL exhausted its 80-connection limit. [PostgREST's explanation](https://docs.postgrest.org/en/v14/references/connection_pool.html).

A sampled expanded product/date plan used existing customer, tenant/date and tenant/product/sale indexes, processing 20,000 scoped sale headers and 10,000 selected-product lines. It did not scan all tenants' transactions. Broad reporting still aggregates each qualifying business's sales; businesses compete for CPU, cache and pool slots. Increasing the pool alone is not a demonstrated fix.

This is a burstable B-series VM. Azure can throttle it after CPU credits run out. **Credit balances were not collected**; these short stages do not establish hours-long capacity. [Azure Basv2 documentation](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/general-purpose/basv2-series).

## Earlier busy-VPS cause and fix

Before testing, five old PostgREST requests continually raised custom `40001` errors for stale purchase/brand-order edits. PostgREST 14 treated them as transient failures and retried. Migration `20261022181704_nonretryable_stale_edit_errors.sql` preserves the guards/messages and changes the code to `P0001`. All five old backends ended and database CPU returned near idle. Real authenticated acceptance verified a stale order returned one HTTP 400 / `P0001` response. [Supabase's retry-loop explanation](https://supabase.com/kb/troubleshooting/high-cpu-and-infinite-transaction-retries-when-using-custom-error-codes-in-rpc-functions).

The older busy-VPS query timings included this abnormal background workload and are not idle-capacity figures. Load during the stages above was deliberately generated test traffic.

## Verification and recovery

- The complete 30-migration replay passed all nine correctness suites in both PGlite and native PostgreSQL 17.6. Native races passed for duplicate checkout, final stock, purchase creation/payment/receipt/cancellation/refunds, collections and transfers, including stale-edit rejection.
- Real public Auth/PostgREST acceptance used disposable businesses and normal permissions. It passed date/product scopes, whole-sale money, subsequent collections, all sort directions, pagination, anonymous/foreign-tenant/capability denial and the HTTP 400/P0001 stale-edit regression. Those fixtures were removed; the burner business remained read-only.
- Build, lint, nine focused unit tests, eight deployment Node tests and twelve deployment Python tests passed. The production frontend dry-run passed; the published index, entry assets and Customers JS/CSS matched the production build byte-for-byte. No frontend code changed in this test.
- Migration `20261022181704` was applied through the established backup/deployment workflow before testing. The final deployment check reported **no pending migrations**, no changed services, ten healthy services and successful public HTTPS checks.
- Load queries drained to zero. The exact disposable load database/container and native replay database were removed; private tokens/configuration and all eight SSH forwards were removed/stopped. Original stock, customers, sales, wallets, ledger and purchase fingerprints matched their pre-test values. The old five retry backends and custom 40001 validation functions were absent.
- Post-cleanup database CPU was **0.12%**, container memory about **325 MiB**, and free disk returned to **18 GB**. No test load remains running.

A separate post-fix, single-session fixture used **5,000 customers, 30,000 sales and 90,000 lines per business** across two businesses. Five-run engine medians were Name 60 ms, Sold 488 ms, Due 570 ms, Last Sale 469 ms and combined deep filtering 448 ms. Its expanded plan used 220 temporary blocks read/written. These larger/multi-line fixture results are separate from the main 640-business HTTP profile, which showed no sampled temporary-file spills.


## Practical limits

These HTTP timings include network/SSH but bypass public Envoy/Caddy/TLS. Browser rendering/cache behavior, Auth login throughput, complete page fan-out, checkout/payment write throughput, external settlement and long soak stability are outside this profile. Data/UUID distribution, product/date scope, think time, cart size and hardware can change results. This is **customer-reporting capacity**, not whole-application certification.

Use the 40-user result as an observed operating point for this profile. Before targeting hundreds of active reporting businesses, measure the intended server's CPU, database cache allocation and I/O, investigate broad aggregation cost, and repeat with a longer soak and Azure credit metrics. No additional Azure infrastructure was purchased or changed.

## Evidence and reproduction

- [Final statistics and resource summaries](data/2026-10-23-customer-load.json).
- [Fixture, generator, transport control and cleanup](../../supabase/tests/business-load/README.md).
- [Performance architecture](../modules/backend-performance.md) and [customer scope rules](../modules/customers.md).

Ignored `.temp/business-load/` retains raw request/resource evidence without response bodies. Private test tokens/configuration are removed during cleanup. Unrelated working-tree edits were preserved.
