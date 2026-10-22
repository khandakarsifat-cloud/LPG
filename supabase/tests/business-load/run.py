"""HTTP load generator: one sequential active user per isolated fixture business.

Uses preissued test-only JWTs and real PostgREST/RBAC, not service-role requests.
Install aiohttp into a disposable Python path; never prints credentials or bodies.
"""
import argparse
import asyncio
from collections import Counter
import json
import random
import time
from urllib.parse import urlsplit
from pathlib import Path

import aiohttp

parser = argparse.ArgumentParser()
parser.add_argument('--url', default='http://127.0.0.1:53300')
parser.add_argument('--tunnels', type=int, default=8)
parser.add_argument('--tokens', type=Path, required=True)
parser.add_argument('--businesses', type=int, required=True)
parser.add_argument('--sales-per-business', type=int, default=20000)
parser.add_argument('--duration', type=int, default=90)
parser.add_argument('--warmup', type=int, default=20)
parser.add_argument('--think', type=float, default=2)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--burst', action='store_true')
args = parser.parse_args()
assert 1 <= args.businesses <= 1280
assert args.sales_per_business % 2000 == 0
assert 1 <= args.tunnels <= 16
base_url = urlsplit(args.url)
assert args.tunnels == 1 or (base_url.hostname == '127.0.0.1' and base_url.port)
tokens = json.loads(args.tokens.read_text())
records = []
lags = []
round_trips = args.sales_per_business // 2000


def percentile(values, fraction):
    ordered = sorted(values)
    if not ordered:
        return None
    position = (len(ordered) - 1) * fraction
    lo = int(position)
    hi = min(lo + 1, len(ordered) - 1)
    return round(ordered[lo] + (ordered[hi] - ordered[lo]) * (position - lo), 2)


def scenario(rng):
    n = rng.randrange(100)
    direction = rng.choice(['asc', 'desc'])
    offset = rng.choice([0, 25, 975, 1975])
    if n < 30:
        return 'name', {'sort': 'name_' + direction}, offset, 2000
    if n < 45:
        return 'search', {'search': '01900000876', 'sort': 'name_asc'}, 0, 1
    if n < 60:
        return 'sold', {'sort': 'sold_' + direction}, offset, 2000
    if n < 75:
        return 'due', {'sort': 'due_' + direction}, offset, 2000
    if n < 85:
        return 'last_sale', {'sort': 'last_sale_' + direction}, offset, 2000
    return 'combined', {'sort': 'due_' + direction, 'from': '2026-01-01', 'to': '2026-03-31',
        'item_ids': ['d0000000-0000-4000-8000-000000000001'],
        'transactions_min': str(round_trips), 'refill_min': str(round_trips), 'package_max': '0'}, 500, 1000


def validate(body, business, filters, offset, total):
    assert body['total'] == total, 'count'
    entries = body['entries']
    assert len(entries) == min(25, max(0, total - offset)), 'page size'
    metric = {'name': 'display_name', 'sold': 'total_sold_amount', 'due': 'total_due',
              'last_sale': 'last_transaction_at'}[filters['sort'].rsplit('_', 1)[0]]
    ascending = filters['sort'].endswith('_asc')
    previous = None
    for entry in entries:
        assert entry['name'].startswith(f'Business {business} Customer '), 'tenant name'
        assert entry['tenant_id'] == f'a0000000-0000-4000-8000-{business:012d}', 'tenant id'
        customer = int(entry['customer_id'].rsplit('-', 1)[1])
        assert entry['transactions'] == round_trips, 'transaction count'
        assert entry['total_sold_amount'] == (1000 + customer % 100) * round_trips, 'sold money'
        assert entry['total_due'] == (500 + customer % 100) * round_trips, 'outstanding money'
        assert entry['refill'] == (round_trips if customer % 2 == 0 else 0), 'refill quantity'
        assert entry['package'] == (round_trips if customer % 2 else 0), 'package quantity'
        if 'item_ids' in filters:
            assert customer % 2 == 0, 'selected product'
        value = entry[metric]
        if previous is not None:
            assert previous[0] <= value if ascending else previous[0] >= value, 'sort direction'
            if previous[0] == value:
                assert previous[1] < entry['customer_id'], 'tie order'
        previous = value, entry['customer_id']


async def main():
    wall_start = time.time()
    connector = aiohttp.TCPConnector(limit=0, limit_per_host=0)
    timeout = aiohttp.ClientTimeout(total=30)
    async with aiohttp.ClientSession(connector=connector, timeout=timeout) as session:
        async def request(business, phase, spec):
            label, filters, offset, total = spec
            started = time.perf_counter()
            status, error, size = 0, None, 0
            try:
                url = args.url if args.tunnels == 1 else f'http://127.0.0.1:{base_url.port + (business - 1) % args.tunnels}'
                async with session.post(url + '/rpc/get_customer_directory',
                    headers={'Authorization': 'Bearer ' + tokens[business - 1]},
                    json={'p_filters': filters, 'p_offset': offset, 'p_limit': 25}) as response:
                    status = response.status
                    raw = await response.read()
                    size = len(raw)
                    body = json.loads(raw)
                    if status != 200:
                        error = body.get('code', 'http_error')
                    else:
                        validate(body, business, filters, offset, total)
            except AssertionError as failure:
                error = 'correctness:' + str(failure)
            except Exception as failure:
                error = type(failure).__name__
            records.append({'business': business, 'phase': phase, 'scenario': label,
                'status': status, 'error': error, 'ms': (time.perf_counter() - started) * 1000,
                'bytes': size, 'started_at': started, 'completed_at': time.perf_counter()})

        # Verify identity, metrics and all query classes before applying load.
        for business in [1, args.businesses]:
            for n in range(6):
                filters = [({'sort': 'name_asc'}, 0, 2000),
                    ({'sort': 'sold_desc'}, 0, 2000), ({'sort': 'due_asc'}, 1975, 2000),
                    ({'sort': 'last_sale_desc'}, 25, 2000),
                    ({'search': '01900000876', 'sort': 'name_asc'}, 0, 1),
                    ({'sort': 'due_desc', 'from': '2026-01-01', 'to': '2026-03-31',
                      'item_ids': ['d0000000-0000-4000-8000-000000000001'],
                      'transactions_min': str(round_trips), 'package_max': '0'}, 500, 1000)][n]
                await request(business, 'preflight', ('preflight', *filters))
                assert records[-1]['error'] is None, records[-1]
        if args.burst:
            started = time.perf_counter()
            await asyncio.gather(*(request(n, 'burst', ('sold', {'sort': 'sold_desc'}, 0, 2000))
                                   for n in range(1, args.businesses + 1)))
            burst_seconds = time.perf_counter() - started
            print(json.dumps({'businesses': args.businesses, 'burst_seconds': round(burst_seconds, 2)}), flush=True)
            await asyncio.sleep(10)
        else:
            burst_seconds = None
        beginning = time.perf_counter()
        measured_start = beginning + args.warmup
        ending = measured_start + args.duration

        async def lag_monitor():
            while time.perf_counter() < ending:
                started = time.perf_counter()
                await asyncio.sleep(.1)
                lags.append(max(0, (time.perf_counter() - started - .1) * 1000))

        async def user(business):
            rng = random.Random(business * 10007 + args.businesses)
            await asyncio.sleep(rng.uniform(0, args.think))
            while time.perf_counter() < ending:
                phase = 'warmup' if time.perf_counter() < measured_start else 'steady'
                await request(business, phase, scenario(rng))
                await asyncio.sleep(rng.uniform(args.think * .75, args.think * 1.25))

        await asyncio.gather(lag_monitor(), *(user(n) for n in range(1, args.businesses + 1)))
        elapsed = time.perf_counter() - beginning
    def summary(rows, seconds):
        good = [r['ms'] for r in rows if r['error'] is None]
        return {'requests': len(rows), 'successes': len(good),
            'errors': dict(Counter(r['error'] for r in rows if r['error'])),
            'status': dict(Counter(str(r['status']) for r in rows)),
            'success_rps': round(len(good) / seconds, 2),
            'error_percent': round(100 * (len(rows) - len(good)) / len(rows), 2) if rows else None,
            'success_ms': {'p50': percentile(good, .5), 'p95': percentile(good, .95),
                           'p99': percentile(good, .99), 'max': round(max(good), 2) if good else None},
            'all_ms_p95': percentile([r['ms'] for r in rows], .95)}
    steady = [r for r in records if r['phase'] == 'steady']
    result = {'businesses': args.businesses, 'sales_per_business': args.sales_per_business,
        'started_unix': wall_start, 'finished_unix': time.time(),
        'ssh_tunnels': args.tunnels,
        'warmup_seconds': args.warmup, 'scheduled_measure_seconds': args.duration,
        'actual_elapsed_seconds_including_warmup_and_drain': round(elapsed, 2),
        'think_seconds': args.think, 'generator_event_loop_lag_ms_p99': percentile(lags, .99),
        'steady': summary(steady, args.duration),
        'scenarios': {label: summary([r for r in steady if r['scenario'] == label], args.duration)
                      for label in ['name', 'search', 'sold', 'due', 'last_sale', 'combined']},
        'burst': summary([r for r in records if r['phase'] == 'burst'], burst_seconds) if burst_seconds else None,
        'records': records}
    result['steady']['success_rps_completed_within_window'] = round(sum(
        r['error'] is None and r['completed_at'] <= ending for r in steady) / args.duration, 2)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2))
    print(json.dumps({k: v for k, v in result.items() if k not in ['records', 'scenarios']}, indent=2), flush=True)


asyncio.run(main())
