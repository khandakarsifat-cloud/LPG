import assert from 'node:assert/strict';
import test from 'node:test';
import { hasAnyPermission, routePermissions } from '../src/lib/authorization.ts';
import { permissionSelection } from '../src/lib/accessPermissions.ts';

const accessible = (permissions: string[]) =>
  Object.entries(routePermissions)
    .filter(([, required]) => hasAnyPermission(permissions, required))
    .map(([path]) => path);

test('Dashboard/POS capabilities do not expose management routes', () => {
  assert.deepEqual(accessible(['dashboard:view', 'pos:sell', 'sales:view', 'receipts:print']), ['/', '/pos', '/sales']);
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

test('personal settings access does not grant business administration', () => {
  assert.deepEqual(accessible(['preferences:manage']), ['/settings']);
  assert.equal(hasAnyPermission(['preferences:manage'], ['settings:manage']), false);
});

test('plant-only capabilities can reach their section in Settings', () => {
 assert.deepEqual(accessible(['gas_plants:view']), ['/settings']);
 assert.deepEqual(accessible(['gas_plants:manage']), ['/settings']);
 assert.equal(hasAnyPermission(['gas_plants:view'], ['settings:manage']), false);
});

test('permission controls add transitive prerequisites and remove their dependents', () => {
 const definition=(id:string,dependencies:string[]=[],owner_only=false)=>({id,dependencies,owner_only,module:'Test',label:id,description:null});
 const catalog=[definition('purchases:view'),definition('purchases:manage',['purchases:view']),definition('purchases:pay',['purchases:manage']),definition('users:manage',[],true)];
 assert.deepEqual(permissionSelection([],'purchases:pay',true,catalog),['purchases:manage','purchases:pay','purchases:view']);
 assert.deepEqual(permissionSelection(['purchases:view','purchases:manage','purchases:pay'],'purchases:view',false,catalog),[]);
 assert.deepEqual(permissionSelection([],'users:manage',true,catalog),[]);
});
