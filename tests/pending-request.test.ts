import test from 'node:test';
import assert from 'node:assert/strict';
import { finishRequest, hasPendingRequest, isDefiniteRejection, prepareRequest, readPendingRequest } from '../src/lib/pendingRequest.ts';

test('uncertain writes retain the original request across retries and remounts, scoped by actor and tenant', () => {
  const values = new Map<string, string>();
  Object.defineProperty(globalThis, 'sessionStorage', { configurable: true, value: {
    getItem: (key: string) => values.get(key) ?? null,
    setItem: (key: string, value: string) => values.set(key, value),
    removeItem: (key: string) => values.delete(key),
  } });
  const body = { p_items: [{ quantity: 2, unit_price: 1200 }], p_discount_amount: 50 };
  const first = prepareRequest('tenant-a:user-a', body);
  assert.deepEqual(prepareRequest('tenant-a:user-a', body), first);
  assert.deepEqual(prepareRequest('tenant-a:user-a'), first);
  assert.deepEqual(readPendingRequest('tenant-a:user-a')?.body, body);
  assert.throws(() => prepareRequest('tenant-a:user-a', { ...body, p_discount_amount: 100 }), /awaiting confirmation/);
  assert.notEqual(prepareRequest('tenant-b:user-a', body).id, first.id);
  assert.notEqual(prepareRequest('tenant-a:user-b', body).id, first.id);
  finishRequest('tenant-a:user-a', 'different request');
  assert.equal(readPendingRequest('tenant-a:user-a')?.id, first.id);
  finishRequest('tenant-a:user-a', first.id);
  assert.equal(readPendingRequest('tenant-a:user-a'), null);
  assert.notEqual(prepareRequest('tenant-a:user-a', body).id, first.id, 'the next intentional identical sale gets a new ID');
});

test('input rejections release a write; auth, gateway, lock timeouts and network failures retain an earlier uncertain commit', () => {
  for (const code of ['P0001', '23505', '23514', '22P02']) assert.equal(isDefiniteRejection(code), true);
  for (const code of ['', undefined, 'Failed to fetch', 'AbortError', '42501', '40001', '40P01', '57014', 'PGRST202', 'PGRST301', 'PGRST003']) assert.equal(isDefiniteRejection(code), false);
});

test('damaged or unwritable browser storage fails before any new request is sent', () => {
  Object.defineProperty(globalThis, 'sessionStorage', { configurable: true, value: {
    getItem: () => 'broken JSON', setItem: () => {}, removeItem: () => {},
  } });
  assert.equal(hasPendingRequest('damaged'), true);
  assert.throws(() => prepareRequest('damaged', {}), /could not be read/);
  Object.defineProperty(globalThis, 'sessionStorage', { configurable: true, value: {
    getItem: () => null, setItem: () => { throw new Error('Storage full'); }, removeItem: () => {},
  } });
  assert.throws(() => prepareRequest('full', {}), /Storage full/);
});
