import assert from 'node:assert/strict';
import test from 'node:test';
import { hasAnyPermission, routePermissions } from '../src/lib/authorization.ts';

const accessible = (permissions: string[]) =>
  Object.entries(routePermissions)
    .filter(([, required]) => hasAnyPermission(permissions, required))
    .map(([path]) => path);

test('Dashboard/POS capabilities do not expose management routes', () => {
  assert.deepEqual(accessible(['dashboard:view', 'pos:sell', 'sales:view', 'receipts:print']), ['/', '/pos']);
});

test('every current tenant route is available with the complete capability set', () => {
  const permissions = [...new Set(Object.values(routePermissions).flat())];
  assert.deepEqual(accessible(permissions), Object.keys(routePermissions));
});

test('changing effective permissions changes access without role-name rules', () => {
  assert.equal(hasAnyPermission(['inventory:view'], routePermissions['/inventory']), true);
  assert.equal(hasAnyPermission(['inventory:manage'], routePermissions['/inventory']), true);
  assert.equal(hasAnyPermission(['pos:sell'], routePermissions['/inventory']), false);
  assert.deepEqual(accessible([]), []);
  assert.deepEqual(accessible(['OWNER', 'MANAGER', 'SALESMAN']), []);
});
