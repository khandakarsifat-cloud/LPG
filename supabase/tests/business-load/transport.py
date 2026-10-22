"""Check generator/SSH/JWT transport with OPTIONS requests that do not query sales."""
import argparse
import asyncio
from collections import Counter
import json
import time
from pathlib import Path
import aiohttp

parser = argparse.ArgumentParser()
parser.add_argument('--tokens', type=Path, required=True)
parser.add_argument('--tunnels', type=int, default=8)
parser.add_argument('--businesses', type=int, default=640)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
assert 1 <= args.tunnels <= 16 and 1 <= args.businesses <= 1280
tokens = json.loads(args.tokens.read_text())


async def main():
    rows = []
    async with aiohttp.ClientSession(connector=aiohttp.TCPConnector(limit=0),
                                    timeout=aiohttp.ClientTimeout(total=15)) as session:
        async def request(number):
            started = time.perf_counter()
            record = {'business': number + 1}
            try:
                async with session.options(f'http://127.0.0.1:{53300 + number % args.tunnels}/rpc/get_customer_directory',
                    headers={'Authorization': 'Bearer ' + tokens[number]}) as response:
                    await response.read()
                    record['status'] = response.status
            except Exception as failure:
                record['error'] = type(failure).__name__
                record['errno'] = getattr(getattr(failure, 'os_error', None), 'errno', None)
                record['winerror'] = getattr(getattr(failure, 'os_error', None), 'winerror', None)
            record['ms'] = (time.perf_counter() - started) * 1000
            rows.append(record)
        await asyncio.gather(*(request(n) for n in range(args.businesses)))
    good = sorted(row['ms'] for row in rows if row.get('status') == 200)
    result = {'tunnels': args.tunnels, 'requests': len(rows), 'successes': len(good),
        'status': dict(Counter(str(row.get('status', row.get('error'))) for row in rows)),
        'p95_ms': round(good[int(.95 * (len(good) - 1))], 2) if good else None, 'records': rows}
    args.output.write_text(json.dumps(result, indent=2))
    print(json.dumps({key: value for key, value in result.items() if key != 'records'}), flush=True)
    if len(good) != args.businesses:
        raise SystemExit('Transport control failed; do not attribute its errors to database capacity')


asyncio.run(main())
