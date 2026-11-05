import assert from 'node:assert/strict';
import test from 'node:test';
import { QueryClient, QueryObserver } from '@tanstack/react-query';
import { invalidateFreshQueries } from '../src/lib/invalidateFreshQueries.ts';

test('a pending initial ledger response cannot replace post-transfer data', async () => {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false, gcTime: 0 } } });
  let releaseOld: (value: number) => void = () => {};
  let reads = 0;
  const observer = new QueryObserver(client, {
    queryKey: ['finance', 'ledger'],
    queryFn: () => ++reads === 1 ? new Promise<number>(resolve => { releaseOld = resolve; }) : Promise.resolve(200),
  });
  const stop = observer.subscribe(() => {});
  assert.equal(reads, 1);
  await invalidateFreshQueries(client, { queryKey: ['finance'] });
  assert.equal(client.getQueryData(['finance', 'ledger']), 200);
  releaseOld(100);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(client.getQueryData(['finance', 'ledger']), 200);
  assert.equal(reads, 2);
  stop(); client.clear();
});
