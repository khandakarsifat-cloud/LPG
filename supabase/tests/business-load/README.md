# Customer directory capacity test

`prepare.py` replays the current migrations into a **new** `lpg_load_*` database
inside the established development database container. It starts a separate
PostgREST container using the deployed image, ten pooled connections, a 192 MiB
memory limit and a new test-only signing key. Port 3300 binds to loopback only.
Existing database contents, roles, service configuration and credentials are not
changed. The future production VPS is outside this test's scope.

Use a private workspace created by `mktemp -d /tmp/lpg-business-load.XXXXXX` and
stage the repository's `supabase/migrations` and `supabase/tests` there. On the
development VPS, run with the existing Docker privileges:

```sh
python3 "$SOURCE/supabase/tests/business-load/prepare.py" init --state "$SOURCE" --source "$SOURCE"
python3 "$SOURCE/supabase/tests/business-load/prepare.py" seed --state "$SOURCE" --businesses 640
python3 "$SOURCE/supabase/tests/business-load/prepare.py" analyze --state "$SOURCE"
python3 "$SOURCE/supabase/tests/business-load/monitor.py" --state "$SOURCE" > "$SOURCE/metrics.jsonl"
```

Run the monitor separately. Copy `tokens.json` privately to the generator machine;
never print it or commit it. Start `node supabase/tests/business-load/tunnel.mjs`
in a separate local terminal. It creates eight independent private SSH forwards
on ports 53300–53307, all targeting the isolated VPS API on localhost port 3300.
This avoids the observed Windows single-tunnel connection limit. Generate traffic
**outside** the VPS, and pass the lightweight transport control first:

```sh
python -m pip install --target .temp/business-load/python aiohttp==3.13.3
# Set PYTHONPATH to the absolute .temp/business-load/python directory.
python supabase/tests/business-load/transport.py --tokens .temp/business-load/tokens.json --tunnels 8 --businesses 640 --output .temp/business-load/transport.json
python supabase/tests/business-load/run.py --tokens .temp/business-load/tokens.json --businesses 10 --tunnels 8 --warmup 20 --duration 90 --burst --output .temp/business-load/stage-10.json
```

Repeat the generator for 20, 40, 80, 160, 320 and 640 active businesses, with at
least 15 seconds between stages. Keep the fully seeded database unchanged during
the final series: this separates concurrency from changing total data size. Keep
generator version, dataset density, warmup and duration explicit in reports.
Seeding reserves at least 4 GiB of free
host disk space and stops rather than filling the disk. The user capped this run
at 640 businesses; the 1,280-business fixture would exceed available storage.

Each business has a separate Auth identity, active profile and OWNER permission
mapping, 2,000 customers, two products and normally 20,000 completed sales with one
line each. Each sale is partially paid in its header. IDs intentionally repeat
across tenants to exercise composite-key isolation. Bulk fixture construction
disables triggers only inside this newly created disposable database, then
restores normal behavior before requests. This is a **customer reporting**
fixture, not a reconciled stock/payment ledger and not a POS write benchmark.

The burst starts one Total Sold request per business concurrently. Sustained
traffic has one sequential user per business with 1.5–2.5 seconds of think time:
30% name pages, 15% phone search, 15% Total Sold, 15% Total Due, 10% Last Sale and
15% combined product/date/activity filters, including deep offsets and both sort
directions. Every successful response checks tenant identity, exact count/page
size, sold/due amounts, quantities, direction and deterministic tie order. Tokens
are preissued: Auth login throughput, the public gateway/CDN, browser rendering,
checkout/payment writes and long-duration stability are separate acceptance
boundaries. SSH transport and network latency are included in HTTP timings.

Results retain per-request status, error category and latency without response
bodies or credentials. Steady latency/error statistics use requests started in
the measurement window, including their drain. `success_rps_completed_within_window`
counts only successful measured requests completed before that window ends.
`success_rps` counts the admitted cohort divided by the scheduled window and can
overstate completion throughput during saturation; use the former for capacity.
Burst latency is reported separately. Compare CPU, memory, pool waits, disk,
temporary files and generator event-loop lag with the same time window.

After exporting non-secret results, stop the monitor with a `stop-monitor` file
in the exact workspace. Run `prepare.py cleanup --state "$SOURCE"`: it removes
only that manifest's container/database and private tokens/configuration. Remove
the copied tokens on the generator machine, close the SSH forwards (Ctrl+C or
create `.temp/business-load/stop-tunnels`), and verify
existing business fingerprints, service health and available disk space.
