// Actual Auth/RLS probes; only the explicitly created disposable tenant is removed.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { execFileSync } from 'node:child_process';
import { createClient } from '@supabase/supabase-js';
import { provisionTestBusiness } from './trusted-test-provisioning.mjs';
assert(process.argv.includes('--vps'));
const f = parseEnv(readFileSync('deploy/.env.frontend', 'utf8')), b = parseEnv(readFileSync('deploy/.env.backend', 'utf8'));
const secret = parseEnv(readFileSync('.env.core-test', 'utf8')), m = JSON.parse(readFileSync('.temp/core-business/manifest.json', 'utf8'));
assert.equal(f.VITE_SUPABASE_URL, 'https://api.lpg.144.79.249.4.sslip.io'); assert.equal(b.VPS_HOST, '144.79.249.4');
const make = () => createClient(f.VITE_SUPABASE_URL, f.VITE_SUPABASE_ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const owner = make(), other = make(), anon = make();
const checked = async p => { const { data, error } = await p; if (error) throw Error(error.message); return data; };
const deny = async p => assert((await p).error, 'Unauthorized mutation unexpectedly succeeded');
const ssh = [...(b.VPS_SSH_KEY ? ['-i', b.VPS_SSH_KEY] : []), '-p', b.VPS_PORT, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', `${b.VPS_USER}@${b.VPS_HOST}`];
const sql = input => execFileSync('ssh', [...ssh, 'sudo -n docker exec -i lpg-db-1 psql -X -U supabase_admin -d postgres -qAt -v ON_ERROR_STOP=1'], { input, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] }).trim();
const uid = v => { assert.match(v, /^[a-f0-9-]{36}$/); return `'${v}'::uuid`; };
let tenant, user;
const before = sql(`select md5(coalesce(json_agg(to_jsonb(i) order by item_id)::text,'')) from public.items i where tenant_id=${uid(m.tenant_id)};`);
try {
  await checked(owner.auth.signInWithPassword({ email: secret.LPG_TEST_EMAIL, password: secret.LPG_TEST_PASSWORD }));
  const access = await checked(owner.rpc('get_access_context'));
  assert.equal(access.tenant_id, m.tenant_id); assert.equal(access.is_superadmin, false);
  const { data: session } = await owner.auth.getSession();
  for (const path of ['status', 'full']) {
    const response = await fetch(`${f.VITE_SUPABASE_URL}/backups/v1/${path}`, { method: 'POST', headers: { Authorization: `Bearer ${session.session.access_token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(path === 'full' ? { request_id: randomUUID() } : {}) });
    assert.equal(response.status, 403, 'An active business owner cannot view or start platform backups');
  }

  const fixture = await provisionTestBusiness(other, { email: `core-security-${randomUUID()}@example.invalid`, password: randomUUID() + 'Aa9!', businessName: 'Core security disposable counterparty ' + randomUUID() });
  tenant = fixture.tenant_id; user = fixture.user.id;
  writeFileSync('.temp/core-business/security-fixture.json', JSON.stringify({ tenant_id: tenant, user_id: user }));
  assert.deepEqual(await checked(other.from('items').select('item_id').eq('item_id', m.jamuna)), []);
  if (m.storage_path) await deny(other.storage.from('product-images').download(m.storage_path));
  await deny(other.rpc('get_product_inventory', { p_item_id: m.jamuna }));
  await deny(other.rpc('receive_purchase', { p_purchase_id: m.purchase, p_revision: 1 }));
  await deny(other.rpc('set_product_buying_price', { p_payload: { item_id: m.jamuna, price_type: 'bottle', price: 1, is_manual: true, expected: null, reason: 'Cross tenant denial' }, p_request_id: randomUUID() }));
  await deny(other.rpc('move_wallet_money', { p_payload: { action: 'transfer', wallet_id: m.cash, destination_id: m.bank, amount: 1, reason: 'Cross tenant denial' }, p_request_id: randomUUID() }));
  await deny(anon.rpc('get_finance_analysis', { p_filters: {} }));
  await deny(owner.from('accounting_lines').insert({ tenant_id: m.tenant_id, journal_id: randomUUID(), line_no: 1, account: 'cash', amount: 1 }));
  // Fixture setup changes only this disposable identity's role; enforcement uses a fresh actual Auth session.
  sql(`begin;delete from public.user_roles where tenant_id=${uid(tenant)} and user_id=${uid(user)};insert into public.user_roles(tenant_id,user_id,role_id) select ${uid(tenant)},${uid(user)},role_id from public.roles where tenant_id=${uid(tenant)} and name='SALESMAN';commit;`);
  await deny(other.rpc('move_wallet_money', { p_payload: { action: 'adjustment', wallet_id: randomUUID(), amount: 1, classification: 'capital', reason: 'Salesman denial' }, p_request_id: randomUUID() }));
  await deny(other.rpc('get_finance_analysis', { p_filters: {} }));
  await deny(other.rpc('create_purchase', { p_payload: { request_id: randomUUID() } }));
  assert.equal(sql(`select md5(coalesce(json_agg(to_jsonb(i) order by item_id)::text,'')) from public.items i where tenant_id=${uid(m.tenant_id)};`), before);
  console.log('PASS actual Auth/PostgREST cross-tenant reads/writes, normal role restrictions, anonymous denial, immutable journal boundary and retained-stock preservation');
} finally {
  await other.auth.signOut({ scope: 'global' }).catch(() => {});
  if (tenant) {
    const tables = sql("select c.table_schema||'.'||c.table_name from information_schema.columns c join information_schema.tables t using(table_catalog,table_schema,table_name) where c.table_schema in ('public','app_private') and c.column_name='tenant_id' and t.table_type='BASE TABLE' order by 1;").split('\n');
    assert(tables.every(t => /^(public|app_private)\.[a-z_]+$/.test(t)));
    sql(`begin;do $$begin if not exists(select 1 from public.tenants t join public.user_profiles p using(tenant_id) where t.tenant_id=${uid(tenant)} and p.user_id=${uid(user)} and business_name like 'Core security disposable counterparty %') then raise exception 'Non-fixture cleanup refused';end if;end$$;set local session_replication_role=replica;${tables.map(t => `delete from ${t} where tenant_id=${uid(tenant)};`).join('\n')}commit;`);
  }
  if (user) sql(`delete from auth.users where id=${uid(user)};`);
  await owner.auth.signOut({ scope: 'local' });
}
