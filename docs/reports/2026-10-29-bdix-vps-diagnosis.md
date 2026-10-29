# BDIX VPS benchmark failure diagnosis — 29 October 2026

The saved tests demonstrate a database read-I/O bottleneck under the higher mixed workloads. They do **not** establish 12 users as the VPS's maximum sustainable capacity. The automated 12/13 boundary mixed business-rule rejections with resource failures, and the 15-user run had substantial network interference.

This is retrospective analysis of saved measurements, workload/SQL source, and existing server logs. No new load, fixture creation, application change, or runtime tuning was performed for this diagnosis. The user's instruction to stop testing remains in force.

## Scope and interpretation

- Target: primary BDIX VPS, 6 vCPUs, approximately 5.65 GiB usable RAM and 100 GiB storage. Azure was not accessed.
- Population during these stages: 80 independent fixture businesses, each with 2,000 customers and 20,000 historical invoices plus related native financial and inventory history. One active user per business.
- Tuned PostgreSQL memory cap: 2.5 GiB; shared buffers: 640 MiB. PostgREST pool: 10 connections; PostgreSQL connection limit: 80.
- Workload: authenticated public HTTPS reads and writes, mixed POS, customers, inventory, purchases, finance and dashboard operations, with interaction delays. A 60-second warmup preceded measurement.
- Numerical thresholds: read p95 <1 second; write p95 <1.5 seconds; overall p99 <3 seconds; request errors <0.5%; no detected correctness failures.
- Only `tuned-final-*` stages below use the corrected low-overhead collector. Earlier runs with collector or harness problems are excluded.
- Aggregate read/write percentiles combine different operations. They do not guarantee each endpoint meets the same latency target.

## Saved stage measurements

| Users | Measured time | Requests | Read p95 | Write p95 | Overall p99 | Errors | Diagnosis |
|---:|---:|---:|---:|---:|---:|---:|---|
| 10 | 300 s | 2,591 | 710 ms | 353 ms | 1,405 ms | 0.193% | Five purchase dispatch rejections; no clean all-workflow pass |
| 12 | 300 s | 3,067 | 689 ms | 155 ms | 2,217 ms | 0.359% | Eleven purchase dispatch rejections |
| 13 | 300 s | 3,392 | 579 ms | 131 ms | 1,338 ms | 0.501% | Seventeen purchase dispatch rejections alone crossed the global error threshold |
| 15 | 300 s | 3,243 | 2,879 ms | 1,953 ms | 6,283 ms | 0.740% | Network instability, 23 dispatch rejections and one transport timeout |
| 20 | 32.03 s | 255 | 8,471 ms | 3,962 ms | 10,152 ms | 7.451% | Severe database I/O waits and query timeouts; automatic early stop |
| 40 | 32.04 s | 331 | 10,100 ms | 10,050 ms | 13,945 ms | 10.876% | Database read waits, pool acquisition failures and query timeouts; automatic early stop |
| 80 | 32.05 s | 392 | 12,131 ms | 10,104 ms | 15,001 ms | 46.429% | Database read waits and extensive pool acquisition failures; automatic early stop |
| 12, endurance | 1,800 s | 18,826 | 523 ms | 133 ms | 1,374 ms | 0.351% | Numerical aggregate pass, but 66 purchase dispatch rejections |

The table is ordered for comparison, not execution chronology. The high-load stages stopped after roughly 92 seconds including warmup; their measured windows were approximately 32 seconds, not completed five-minute stages. These show overload onset, not stable throughput capacity.

## What actually failed

### Database I/O and connection queues at higher loads

At 20 users, average host CPU execution was 24.08%, while CPU I/O wait was 69.37%. Physical reads averaged 43.92 MB/s, disk queue depth averaged 10.24, and disk utilization averaged 66.66%. Ten database queries were active, with snapshots showing eight to ten waiting on `IO:DataFileRead`. Forty and 80 users showed similar behavior: approximately 71% I/O wait, 45 MB/s reads, and nine to ten data-file read waits.

This supports the following causal chain:

1. Concurrent reporting/history work needs database pages that are not immediately available in PostgreSQL's buffers or the accessible filesystem cache.
2. Database requests spend substantial time waiting for reads rather than executing on the six CPUs.
3. The ten PostgREST database slots remain occupied by slow operations.
4. Additional requests queue, then hit pool acquisition or statement/client timeouts.

The measured 20-user window contained 18 SQLSTATE `57014` errors and one transport timeout. Existing database logs covering that stage, including warmup and a five-second margin, contained 48 occurrences of `canceling statement due to statement timeout`. At 80 users, the measured window contained 157 `PGRST003` pool acquisition failures, 16 `57014` errors, eight transport timeouts and one `P0001` rejection.

There was no detected OOM, blocked-session chain or CPU saturation in those stages. Host available memory remained about 3.18 GiB. PostgreSQL was constrained by its own 2.5 GiB cgroup, so host available memory does not establish that the database could freely use all RAM. Increasing cgroup memory-limit events indicate allocation/reclaim pressure; they are not OOM counts or exact cache-eviction counts.

This is evidence for database read-I/O/cache pressure and resulting connection queues. It does not prove a particular missing index, the physical storage device's absolute bandwidth limit, or that raising the connection pool would help. A larger pool could increase competing reads.

### The 13-user failure was a business-rule rejection

All 17 errors in the measured 13-user window were `P0001` from `dispatch_purchase`. Existing logs confirm `Select an idle truck before dispatch`; the broader log window contained 20 such messages. Read and write latency remained within the aggregate thresholds, CPU averaged 22.29%, and I/O wait averaged 1.90%. This stage therefore does not demonstrate a resource-capacity failure.

The workload uses one fixed truck per fixture business. After creating and dispatching a purchase, it returns early if an intermediate request fails. It does not resume the unfinished purchase or ensure the truck is idle before creating the next one. If a dispatch succeeds but receipt fails or the run stops before receipt, the truck can remain assigned to an active shipment. Subsequent dispatch attempts are correctly rejected by the application's guard.

That explanation is strongly supported by source and logs, but the exact originating purchase state was not captured before fixture deletion. It remains an inference, not a reconstructed per-business incident timeline. The database guard itself is enforcing the intended business rule.

Relevant source:

- `supabase/tests/vps-capacity/workload.js`, purchase workflow around lines 155–178: fixed truck and early returns.
- `supabase/migrations/20261021184107_purchase_wallet_lifecycle.sql`, `dispatch_purchase`: rejects trucks whose status is not idle.
- `supabase/migrations/20261015172537_purchase_transit_workflow.sql`, `receive_purchase`: completes transit and releases the truck when appropriate.
- `src/components/purchases/PurchaseForm.tsx`: the UI filters for idle trucks.

The 12-user endurance run had 66 measured rejections out of 392 dispatch attempts: **16.84% of dispatches**, despite only 0.351% of all HTTP requests. The broader log window contained 68 idle-truck errors. A global error rate hid an important operation-specific failure. Early returns also skipped subsequent requests, so removing these errors mathematically would not recreate the intended workload.

The runner's stored `confirmed: 12, first_failing: 13` is an automatic threshold classification, not a defensible hardware capacity conclusion. Neither 12 nor 13 is established as a fully successful mixed-workflow capacity point by these runs.

### The 15-user result was confounded by network instability

Successful ping observations averaged 312 ms, with p95 1,582 ms and a maximum of 1,890 ms. Comparable 13-user and endurance averages were about 47 ms. Failed ping observations were present as well. The success fraction of sampled observations was 83.93%; because five-second monitoring samples retain the latest slower probe, this is not an exact packet-loss percentage.

API latency spikes coincided with the network spikes. Average server CPU was 21.95%, I/O wait 4.67%, and physical reads 12.61 MB/s, substantially below the I/O congestion seen at 20 users. No recorded Wi-Fi disconnect does not rule out a degraded network path. The evidence cannot identify the PC's Wi-Fi, ISP, or another network segment as the cause.

Consequently, 15 is not a clean sustainable-VPS failure bound.

## Which operations were expensive first?

The sales directory was already a slow individual operation at 12 users: API p95 1,561 ms over 394 calls, versus an aggregate read p95 of 523 ms. Its captured SQL mean was approximately 1,223 ms per call. It represented about 2.1% of HTTP requests but 28.2% of captured query elapsed time. Customer-directory fingerprints represented another 31.4% of that captured elapsed time. These shares are elapsed-time shares among captured counter deltas, not shares of all database CPU.

Sales-directory SQL wrote approximately 6.22 MiB of temporary blocks per call, or 2.39 GiB over the captured endurance interval. This remained after the collector correction, so it was not the collector's earlier temporary-file artifact.

The canonical `get_sales_directory` implementation in `20261026070000_canonical_development_model.sql` builds materialized sale headers and related bottle/search data before final pagination. This makes historical-data processing a concrete profiling candidate. Customer metric sorts and inventory/report aggregation are other candidates. No execution plan for these business queries was captured on the full dataset before cleanup, so a specific plan defect or index fix is not established.

PostgreSQL shared-block reads may be satisfied by the OS cache; they must not be reported as physical disk bytes. The host disk counters and `DataFileRead` waits provide the separate physical-I/O evidence above.

## Corrections and next decisions

The interpretation needs correction: the lower boundary mixed valid business rejections with infrastructure failures. It also treated a stage with a degraded network path as if it were a clean server measurement. The genuine high-load I/O failure is independently supported, but the exact sustainable user cap remains **undetermined**.

If testing is authorized again, first fix unfinished-workflow recovery and idle-truck selection; classify business rejections separately while still treating unexpected workflow failures as failures; enforce per-operation latency/error criteria; and gate measurements on network quality. Then profile the expensive reporting queries before deciding on query changes, cache allocation, a larger pool or different hardware. Preserve full-data filtering, tenancy and accounting semantics when considering query changes.

The older Azure benchmark exercised reporting reads with simpler bulk-loaded fixtures and shorter stages. Its 40-user healthy result and 80-user failure are workload-specific; they cannot establish a hardware capacity ratio against this mixed, fully related dataset. The earlier untuned BDIX report also used a smaller stored population and is not a controlled tuning A/B comparison.

All fixture businesses/accounts were removed in the prior authorized cleanup. Saved reconciliation checks found no financial, stock or tenant-isolation violations, and the cleanup checks preserved genuine-business fingerprints. That verifies the checks performed; it does not make every interrupted business workflow successful. No new correctness test was run for this diagnosis.

## Evidence and definitions

Local retained evidence is under `.temp/vps-capacity-tuned/`: `tuned-final-*-analysis.json`, raw request/host/Windows samples, `diagnosis-log-evidence.json`, `diagnosis-stage-log-evidence.json`, workload/monitor correction records, reconciliation results and cleanup/health results. Raw automatic stage classifications remain unchanged.

Official definitions: [PostgREST error codes](https://docs.postgrest.org/en/v14/references/errors.html), [PostgreSQL wait events and monitoring](https://www.postgresql.org/docs/17/monitoring-stats.html), [PostgreSQL SQLSTATE codes](https://www.postgresql.org/docs/17/errcodes-appendix.html).
