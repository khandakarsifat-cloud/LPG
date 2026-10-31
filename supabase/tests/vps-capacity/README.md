# Mixed-workload VPS capacity testing

This suite targets the configured **primary development VPS only** through the
application's public HTTPS API. Load generation, Grafana and Prometheus run on
Windows. `sample.py` is a read-only five-second VPS sampler; it generates no load
requests. Azure is never contacted. Keep all private artifacts under the ignored
`.temp/vps-capacity/` directory.

Read the root README, AGENTS, and deployment guide
before a new run. Do not reuse earlier read-only disposable databases as a mixed-write
fixture: stock and payment history were deliberately incomplete.

## Preparation and execution

```powershell
powershell -File supabase/tests/vps-capacity/install-tools.ps1
node supabase/tests/vps-capacity/prepare.mjs init
node supabase/tests/vps-capacity/prepare.mjs accounts 5
node supabase/tests/vps-capacity/verify.mjs baseline
node supabase/tests/vps-capacity/start-monitor.mjs
node supabase/tests/vps-capacity/seed-parallel.mjs 3
node supabase/tests/vps-capacity/run-suite.mjs
```

An existing manifest refuses initialization. Retain it to recover or clean up an
interrupted run; do not delete it and create untracked replacement fixtures. Read
private errors locally and never paste credentials or raw SQL records into reports.
Scripts use the existing SSH host trust and private deployment configuration.
Set `LPG_CAPACITY_STATE` to an absolute ignored directory to keep another run's
manifest and raw evidence separate. Never share or overwrite manifests between
runs. Point its `tools`/`python` dependencies at the installed portable tools.
`metadata.mjs` checks target, applied migrations and deployed source checksums.
`prepare init` verifies the named burner's normal Auth and trusted membership;
the existing burner business remains read-only.

Account provisioning uses the existing Auth admin endpoint only during preparation
and reads its key on the VPS in memory. Each created account then logs in normally
from Windows and calls `setup_business`. k6 receives only actual user sessions and
the public anon key. Refreshes and fixture provisioning happen outside measured
windows. No JWT signing key, privileged key or shared tenant is used by k6.

Each business has 2,000 customers, six priced SKUs and 20,000 completed invoices
spread over 180 days. There are additionally 200 historical received and funded
purchase shipments, physical empty receipts, actual invoice charges, wallet
credits/debits, cash/bank payment attribution, subsequent collections and opening
capital/empty-stock evidence. Twenty percent of customers are wholesale. Carts
contain one or two cylinders; 80% exchange refills, 20% sell packages. One quarter
of historical invoices remain unpaid. Another quarter were paid half at checkout
and half through a later collection. All histories are synthetic fixtures.

The seed invokes existing purchase/dispatch/receive/payment and POS/collection
RPCs under each account's authenticated database role and claims. Constraints,
RBAC and posting triggers remain enabled. Short-lived private timestamp hooks
date **only registered fixture rows in explicitly marked seed sessions**; they
are removed before benchmarking. Opening capital is explicitly synthetic and
registered before the historical seeding. Original business records are never
backdated, altered or included in cleanup.

Histories use a deterministic shared statistical template: customers rotate
evenly, SKU/quantity/payment choices follow fixed cycles, and dates span the same
180-day pattern. Every tenant has distinct records and postings; stored ledgers
are not cloned. This makes runs repeatable but does not model heterogeneous
customer popularity, seasonality or debt concentration. Interpret capacity for
this standardized business shape; different distributions can change query
selectivity, cache locality and latency. Random UUIDs alone do not model that
variation. Creating the valid postings dominates preparation time.

`seed-parallel.mjs` runs at most four independent fixture tenants in parallel
for preparation only. If interrupted, inspect/remove its private
`lpg_capacity_fixture` schema and `zzz_lpg_capacity_date` hooks using the exact
registered run; do not measure with hooks left installed. `prepare seed` offers
a sequential fallback with timestamp hooks removed in each committed batch.
Seed batches reserve 768 MiB host memory and 15 GiB disk, use bounded lock/query
timeouts, and record counts after each committed batch. If the local process dies
after a commit but before saving its count, query the exact fixture's sale count
and reconcile its manifest before resuming; do not replay committed sale batches.

## Workload and interpretation

One k6 constant VU maps to exactly one independent business. A 20-action cycle
exercises Dashboard fan-out, bounded customer pages/search/monetary sorts and
combined filters, POS cash and split payments with receipt reload/stock refresh,
inventory/catalog/history, sales pages, Finance ledger/dues/transfers and complete
purchase dispatch/receipt/payment workflows. Page reads batch related requests;
identity/permission and POS cache refreshes follow 30-second intervals. Requests
use current application RPCs and RLS-scoped REST reads. Think time is 1.5–2.5
seconds between actions, plus 2–4 seconds reviewing a cart and 1.5–2.5 seconds
before a subsequent collection. Occasional exact checkout replays retain the
original request ID. There are no automatic HTTP retries.

This represents actively navigating users, with normal page fan-out and a
deliberately material reporting/write share. It does not measure browser rendering,
physical printing, provider settlement, bulk login storms or a different task mix.
Every VU is active but each individual user's requests remain sequential except
normal page fan-out. Closed-loop throughput falls when the server slows down.

Sequence: **1, 2, 5, 10, 15, 20, ...**, growing by five until the first failure.
Each stage has 60 seconds warmup and 300 measured seconds, bounded draining and
30 seconds cooldown. Seeding, vacuum/analyze, reconciliation and authentication
refreshes are excluded. After discovering a bracket, passing stages repeat with
the same fully stored population; integer tests narrow the threshold. The highest
passing concurrency receives 60 seconds warmup and a 30-minute endurance run.
`suite-progress.json` records progress; `suite-error.json` stops for investigation.

For the revised 80-first search, prepare 80 complete businesses first, then run
`node supabase/tests/vps-capacity/run-bracket.mjs 80` instead of `run-suite.mjs`.
It tests 80, falls to 40 on failure, moves to 60 if 40 passes, then narrows to an
integer bracket and performs 30-minute endurance. If the initial point passes,
it prepares the next doubled population before measuring that larger bracket.
After preparation, it first checks one lightweight public HTTPS health request
from each of 80 k6 VUs, separately from the business workload. This validates
transport and TLS connectivity; it cannot establish business-user capacity.
Environment/monitoring failures stop for investigation rather than lowering the
capacity bound. Inspect `bracket-progress.json` and preserve labels on recovery.
After an interrupted runner has fully exited, run `verify.mjs recovery` and use
`run-bracket.mjs 80 retry --verified recovery` to reuse that completed audit. This
requires a new label prefix, all checks and isolation probes passing, preservation
evidence, no date hooks, and an audit less than fifteen minutes old. It skips
repeating already completed history generation and maintenance.
`report.py --tuned --state PATH --output PATH` renders the tuned run's metrics;
review its interpretation and recovery evidence before delivery.

Acceptance thresholds are read p95 ≤1 s, write p95 ≤1.5 s, overall p99 ≤3 s,
unexpected errors <0.5%, and zero correctness/isolation failures. A comfortable
operating point additionally aims for read p95 ≤0.5 s, write p95 ≤0.75 s,
zero observed errors and p95 host CPU below 70%; confirm this from the report.
These are test criteria, not a universal service guarantee.

Automatic stops: host memory below 512 MiB immediately or below 768 MiB for
30 seconds; disk free below 15 GiB; swap above 512 MiB; any new host/container
OOM; CPU above 95% for 60 seconds; five blocked database sessions or a query over
25 seconds; stale monitoring for 30 seconds; Windows CPU above 90% or available
memory below 2 GiB. After startup grace, k6 also aborts if measured errors exceed
5% or p95 latency exceeds 8 seconds. A `stop-load` file stops the active stage
and prevents another stage. Stop means stop admission and drain; do not kill
database sessions or restart application services to conceal an overloaded run.
After each stage, an available Windows WLAN event log is checked for disconnects
inside that stage. Such a run is invalid for VPS capacity even when connectivity
recovered before the live stale-monitor guard fired. Only the event count is
exported, without SSIDs or interface identifiers.

`verify.mjs` checks financial and stock reconciliation, exact payment attribution,
running wallet balances, business counts, complete physical returns and absence
of timestamp hooks after every stage. Authenticated foreign-tenant probes verify
RLS/RPC boundaries. All original tenant tables are fingerprinted before/after.
Do not treat an unexpected API error or failed invariant as a passing capacity
measurement, even if aggregate latency meets the threshold.

## Monitoring, evidence and cleanup

Grafana: <http://127.0.0.1:13000/d/lpg-vps-capacity>.
Prometheus: <http://127.0.0.1:19090>. Both bind loopback only. Grafana provisions
a read-only anonymous dashboard; its generated administrator password stays in
ignored local configuration. k6 remote-writes to local Prometheus. The VPS sampler
streams `/proc`, cgroup memory/CPU/events and aggregate PostgreSQL statistics over
one SSH connection; HTTP load never uses an SSH tunnel. Raw samples and k6 JSON
remain local. The per-stage analyzer correlates only measured windows and reports
per-core busy/steal/I/O wait, disk throughput/await/utilization/queue, network,
container memory/CPU, database connections/waits/commits/temp data and Windows
generator resources. Database CPU percentages use 100% per core. Host CPU uses
all six cores. PostgreSQL statistics include background activity; no global
statistics are reset. Query fingerprints contain no SQL bodies or records.
The sampler calls `pg_stat_statements(false)` and reads counters for top-level,
result-producing authenticated/API-role queries. It does not materialize stored
SQL texts on every poll; large seed query texts otherwise spill from that observer
query itself. Endpoint labels are resolved separately outside measurement. Each
stage records the actual sampler source hash, which must match the local checked
source. Keep different collector revisions separate when selecting final results.
PostgreSQL documents this [counter-only monitoring interface](https://www.postgresql.org/docs/17/pgstatstatements.html#PGSTATSTATEMENTS-FUNCS).

After exporting sanitized reports and before claiming completion:

```powershell
node supabase/tests/vps-capacity/verify.mjs final
node supabase/tests/vps-capacity/cleanup.mjs --created-fixtures-only
node supabase/tests/vps-capacity/metadata.mjs
```

Cleanup guards exact manifest tenant IDs, generated names, Auth IDs and email
prefixes. It uses the repository's existing trusted fixture-deletion pattern;
there is no reset, volume removal, globally disabled trigger or deletion by broad name
matching. Keep the burner login. Stop the monitor and its exact remote sampler
PID after the recovery interval, remove the staged `/tmp/lpg-capacity-*` scripts
and private errors, and inspect service health/OOM/restarts and preservation.
Grafana/Prometheus may remain local for reviewing retained historical metrics;
their process IDs are recorded in the private state. No application migration,
optimization or frontend publication is required for this test-only tooling.

Interrupted setup can be investigated from the private error/progress files. After restoring a stable network and fresh monitoring, `node supabase/tests/vps-capacity/resume-confirmation.mjs` starts a new confirmation series without overwriting existing labels. Preserve earlier evidence when selecting new labels for another restart. Safety query age counts client backends, excluding normal replication streams. Normal stages have bounded graceful stop; safety aborts use the local k6 REST control API and retain summaries, with a bounded hard-stop fallback. The Windows monitor temporarily prevents system sleep and records ping latency and network-address changes.

Trusted fixture cleanup follows the existing purchase acceptance runner: only after exact tenant/name/membership guards, session-local session_replication_role=replica permits deleting immutable fixture history. Application triggers remain enabled globally and throughout preparation and measurement. No genuine tenant rows are selected for deletion.
