import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { createClient } from '@supabase/supabase-js';

const url = process.env.VITE_SUPABASE_URL;
const key = process.env.VITE_SUPABASE_ANON_KEY || process.env.ANON_KEY;
assert(['http://127.0.0.1:54321', 'http://localhost:54321'].includes(url), 'Use the repository local gateway');
assert(key, 'Local public/anon key required');
const users = [];
const tenants = [];
const sql = query => execFileSync('docker', [
  'compose', 'exec', '-T', 'db', 'psql', '-U', 'supabase_admin', '-d', 'postgres',
  '-v', 'ON_ERROR_STOP=1', '-q', '-t',
], { input: query, encoding: 'utf8' });
const safeUuid = value => {
  assert.match(value, /^[0-9a-f-]{36}$/i);
  return `'${value}'::uuid`;
};
const checked = async request => {
  const result = await request;
  if (result.error) throw new Error(`${result.error.code}: ${result.error.message}`);
  return result.data;
};
const denied = async request => {
  const result = await request;
  assert(result.error && ['42501', 'PGRST202', 'PGRST106'].includes(result.error.code),
    `Expected privilege denial; received ${result.error?.code ?? 'success'}`);
};
const account = async label => {
  const client = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
  const email = `rls-${label}-${randomUUID()}@example.invalid`;
  const { data, error } = await client.auth.signUp({ email, password: randomUUID() + 'Aa1!' });
  if (error) throw new Error(`Fixture signup: ${error.message}`);
  assert(data.user && data.session, 'Local signup must establish a session');
  users.push(data.user.id);
  return { client, id: data.user.id, email };
};
try {
  const owner = await account('owner');
  const other = await account('other');
  const manager = await account('manager');
  const salesman = await account('salesman');
  for (const user of [owner, other]) {
    const result = await checked(user.client.rpc('setup_business', { p_business_name: 'Authorization API fixture', p_owner_name: 'Fixture owner' }));
    user.tenant = result.tenant_id;
    tenants.push(user.tenant);
  }
  // Staff admission is a trusted fixture operation; no staff-provisioning API exists.
  for (const [user, role] of [[manager, 'MANAGER'], [salesman, 'SALESMAN']]) {
    sql(`begin;
      insert into public.user_profiles(user_id,tenant_id,email)
      select id,${safeUuid(owner.tenant)},email from auth.users where id=${safeUuid(user.id)};
      insert into public.user_roles(tenant_id,user_id,role_id)
      select tenant_id,${safeUuid(user.id)},role_id from public.roles
      where tenant_id=${safeUuid(owner.tenant)} and name='${role}';
      commit;`);
  }
  const ownerPermissions = await checked(owner.client.rpc('get_my_permissions'));
  assert.deepEqual((await checked(manager.client.rpc('get_my_permissions'))).sort(), ownerPermissions.sort());
  assert.equal((await checked(salesman.client.rpc('get_my_permissions'))).length, 4);
  const brand = await checked(owner.client.rpc('create_lpg_brand', { p_brand_name: 'API brand', p_description: null }));
  const item = await checked(owner.client.from('items').insert({
    tenant_id: owner.tenant, brand_id: brand.brand_id, brand: 'API item', size_kg: 12,
  }).select().single());
  await checked(owner.client.rpc('create_inventory_movement', {
    p_item_id: item.item_id, p_movement_type: 'adjust_gain',
    p_filled_quantity_change: 10, p_empty_quantity_change: 10, p_notes: 'API fixture',
  }));
  // Exercise exactly the browser's PostgREST configuration upsert.
  const config = {
    tenant_id: owner.tenant,
    printer: { transport: 'windows_usb', queue_id: 'fixture', host_id: 'fixture', queue_name: 'fixture', port_name: 'USB001' },
    paper_width_mm: 80, printable_width_dots: 576, auto_cut: false,
  };
  await checked(owner.client.from('receipt_printers').upsert(config, { onConflict: 'tenant_id' }).select().single());
  config.paper_width_mm = 58;
  config.printable_width_dots = 384;
  await checked(manager.client.from('receipt_printers').upsert(config, { onConflict: 'tenant_id' }).select().single());
  assert.equal((await checked(salesman.client.from('receipt_printers').select().single())).paper_width_mm, 58);
  await denied(salesman.client.from('receipt_printers').upsert(config, { onConflict: 'tenant_id' }));
  await denied(owner.client.from('user_profiles').update({ tenant_id: other.tenant }).eq('user_id', owner.id));
  await denied(salesman.client.from('user_roles').insert({ tenant_id: owner.tenant, user_id: salesman.id, role_id: randomUUID() }));
  await denied(salesman.client.rpc('list_employees'));
  await denied(salesman.client.rpc('list_purchases'));
  await denied(salesman.client.rpc('list_gas_plants'));
  await denied(salesman.client.rpc('ensure_tenant_wallets', { p_tenant_id: other.tenant }));
  await denied(salesman.client.rpc('resolve_employee_type', { p_tenant_id: other.tenant, p_employee_type_name: 'Escalation' }));
  assert.deepEqual(await checked(other.client.from('items').select()), []);
  const profile = await checked(owner.client.from('user_profiles')
    .select('tenant_id, email, full_name, tenants(business_name)').eq('user_id', owner.id).single());
  assert.equal(profile.tenant_id, owner.tenant);
  const customer = await checked(salesman.client.from('customers').insert({
    tenant_id: owner.tenant, name: 'API customer', phone: '01700000000', tier: 'retail',
  }).select().single());
  const sale = await checked(salesman.client.rpc('create_pos_sale', {
    p_customer_phone: customer.phone, p_customer_name: null, p_customer_shop_name: null,
    p_customer_address: null, p_customer_tier: 'retail', p_discount_amount: 100,
    p_exchange_fee: 50, p_notes: 'API fixture', p_customer_id: customer.customer_id,
    p_items: [
      { item_id: item.item_id, type: 'refill', quantity: 1, unit_price: 1200 },
      { item_id: item.item_id, type: 'empty_return', quantity: 1, unit_price: 0 },
    ],
  }));
  const receipt = await checked(salesman.client.from('sales').select(`
    sale_id, created_at, subtotal, discount_amount, exchange_fee, total_amount, notes,
    customers(name, phone, tier),
    sale_items(quantity, unit_price, line_total, type, items(brand, size_kg, lpg_brands(brand_name)))
  `).eq('sale_id', sale.sale_id).single());
  assert.equal(receipt.sale_items.length, 2);
  assert.equal(receipt.total_amount, 1150);
  const history = await checked(owner.client.from('inventory_movements')
    .select('*, items(brand, lpg_brands(brand_name)), user_profiles(email)'));
  assert.equal(history.length, 3);
  assert(history.some(row => row.user_profiles.email === salesman.email));
  const balances = await checked(owner.client.from('items').select().eq('item_id', item.item_id).single());
  assert.equal(balances.filled_quantity, 9);
  assert.equal(balances.empty_quantity, 11);
  const stats = await checked(salesman.client.rpc('get_dashboard_stats', { p_since: '2000-01-01T00:00:00Z' }));
  assert.equal(stats.todayRevenue, 1150);
  assert.equal(stats.todayMovements, 3);
  assert.deepEqual(await checked(salesman.client.from('inventory_movements').select()), []);
  assert.deepEqual(await checked(salesman.client.from('wallets').select()), []);
  const metadataChange = await salesman.client.auth.updateUser({ data: { tenant_id: other.tenant, role: 'OWNER', is_active: true } });
  assert.equal(metadataChange.error, null);
  assert.equal((await checked(salesman.client.rpc('get_my_permissions'))).length, 4);
  assert.equal((await checked(salesman.client.from('items').select().single())).tenant_id, owner.tenant);
  const anon = createClient(url, key, { auth: { persistSession: false } });
  await denied(anon.from('items').select());
  await denied(anon.rpc('get_dashboard_stats', { p_since: '2000-01-01T00:00:00Z' }));
  console.log('PASS: real Auth signup/setup, OWNER/MANAGER/SALESMAN REST boundaries, printer upserts, receipt embeds, attribution, checkout stock, and metadata spoofing denial');
} catch (error) {
  console.error('REST assertion failure: ' + error.message);
  throw error;
} finally {
  // Delete only the freshly generated fixture tenants/accounts, in FK order.
  // No production rows or printer jobs are touched.
  if (tenants.length) {
    const tenantList = tenants.map(safeUuid).join(',');
    const tables = ['wallet_transactions','customer_transactions','sale_items','sales',
      'transits','purchase_items','purchases','inventory_movements','price_books','items',
      'area_officers','gas_plants','lpg_brands','customers','receipt_printers','wallets',
      'user_roles','role_permissions','roles','audit_logs','user_profiles','tenants'];
    sql('begin;\n' + tables.map(table => `delete from public.${table} where tenant_id in (${tenantList});`).join('\n') + '\ncommit;');
  }
  if (users.length) sql(`delete from auth.users where id in (${users.map(safeUuid).join(',')});`);
}
