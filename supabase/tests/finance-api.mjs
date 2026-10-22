// Real Auth/PostgREST acceptance against the explicitly configured target.
// Creates and removes only newly generated fixture businesses/accounts.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { execFileSync } from 'node:child_process';
import { createClient } from '@supabase/supabase-js';

const azure = process.argv.includes('--azure');
const frontend = azure ? parseEnv(readFileSync('deploy/.env.frontend', 'utf8')) : process.env;
const url = frontend.VITE_SUPABASE_URL, key = frontend.VITE_SUPABASE_ANON_KEY || frontend.ANON_KEY;
assert(azure ? url === 'https://api.lpg.20.40.48.3.sslip.io' : ['http://127.0.0.1:54321', 'http://localhost:54321'].includes(url), 'Explicit established API target required');
const config = azure ? parseEnv(readFileSync('deploy/.env.backend', 'utf8')) : null;
const sql = query => azure ? execFileSync('ssh', ['-i', config.AZURE_SSH_KEY, '-p', config.AZURE_PORT, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', `${config.AZURE_USER}@${config.AZURE_HOST}`, 'cd /opt/lpg && sudo docker compose -p lpg -f compose.yml -f compose.azure.yml exec -T db psql -X -U supabase_admin -d postgres -qAt -v ON_ERROR_STOP=1'], { input: query, encoding: 'utf8' }).trim() : execFileSync('docker', ['compose', 'exec', '-T', 'db', 'psql', '-X', '-U', 'supabase_admin', '-d', 'postgres', '-qAt', '-v', 'ON_ERROR_STOP=1'], { input: query, encoding: 'utf8' }).trim();
const uuid = value => { assert.match(value, /^[0-9a-f-]{36}$/i); return `'${value}'::uuid`; };
const users = [], tenants = [];
const checked = async request => { const { data, error } = await request; if (error) throw Error(`${error.code}: ${error.message}`); return data; };
const rejected = async request => { const result = await request; assert(result.error, 'Expected request rejection'); };
async function account(label) {
  const client = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
  const data = await checked(client.auth.signUp({ email: `finance-${label}-${randomUUID()}@example.invalid`, password: randomUUID() + 'Aa1!' }));
  assert(data.user && data.session, 'Fixture signup must establish a session'); users.push(data.user.id);
  const result = await checked(client.rpc('setup_business', { p_business_name: 'Finance API fixture ' + label, p_owner_name: 'Finance fixture owner' }));
  tenants.push(result.tenant_id); return { client, id: data.user.id, tenant: result.tenant_id };
}
try {
  const owner = await account('owner'), other = await account('other');
  const wallets = await checked(owner.client.from('wallets').select('*'));
  assert.equal(wallets.length, 5); const cash = wallets.find(w => w.type === 'cash'), bank = wallets.find(w => w.type === 'dealership'), bkash = wallets.find(w => w.type === 'bkash');
  assert.equal((await checked(owner.client.rpc('get_payment_wallets'))).length, 4);
  const item = randomUUID();
  sql(`insert into public.items(tenant_id,item_id,brand,size_kg,filled_quantity,empty_quantity) values(${uuid(owner.tenant)},${uuid(item)},'Finance test gas',12,20,20);insert into public.price_books(tenant_id,item_id,customer_tier,price_type,price,effective_from)values(${uuid(owner.tenant)},${uuid(item)},'retail','package',2300,now()-interval '1 day');`);
  const customer = await checked(owner.client.from('customers').insert({ tenant_id: owner.tenant, name: 'Finance fixture customer', phone: '01700000000', tier: 'retail' }).select().single());
  const args = { p_customer_phone: customer.phone, p_customer_name: null, p_customer_shop_name: null, p_customer_address: null, p_customer_tier: 'retail', p_discount_amount: 0, p_exchange_fee: 0, p_notes: 'Finance fixture', p_customer_id: customer.customer_id, p_items: [{ item_id: item, type: 'package', quantity: 1, unit_price: 2300 }] };
  const cashSale = await checked(owner.client.rpc('create_pos_sale', { ...args, p_request_id: randomUUID() })); assert.equal(cashSale.paid_amount, 2300);
  const request = randomUUID(), payments = [{ wallet_id: cash.wallet_id, amount: 500 }, { wallet_id: bkash.wallet_id, amount: 700, reference: 'API-BK-123' }];
  const split = await Promise.all(Array.from({ length: 3 }, () => checked(owner.client.rpc('create_pos_sale', { ...args, p_request_id: request, p_payments: payments }))));
  assert(split.every(s => s.sale_id === split[0].sale_id && s.due === 1100));
  const sid = split[0].sale_id;
  assert.equal(await checked(owner.client.rpc('get_customer_balance', { p_customer_id: customer.customer_id })), 1100);
  const collectionArgs = { p_sale_id: sid, p_payments: [{ wallet_id: bank.wallet_id, amount: 1100, reference: 'BANK-COLLECT' }], p_request_id: randomUUID() };
  const receipts = await Promise.all(Array.from({ length: 3 }, () => checked(owner.client.rpc('collect_sale_payment', collectionArgs)))); assert(receipts.every(p => p.due === 0));
  const settlement = await checked(owner.client.rpc('get_sale_settlement', { p_sale_id: sid })); assert.equal(settlement.payment_count, 3); assert.equal(settlement.paid, 2300);
  assert.equal(settlement.receipt_payments.filter(p => p.phase === 'collection')[0].wallet_name, 'Primary Bank Account');
  const balances = await checked(owner.client.from('wallets').select('*'));
  assert.equal(balances.find(w => w.type === 'cash').balance, 2800); assert.equal(balances.find(w => w.type === 'bkash').balance, 700); assert.equal(balances.find(w => w.type === 'dealership').balance, 1100);
  const custom = await checked(owner.client.rpc('save_finance_wallet', { p_payload: { name: 'Fixture bank', kind: 'bank', details: 'Fixture only' } }));
  const move = { p_payload: { action: 'transfer', wallet_id: bank.wallet_id, destination_id: custom, amount: 100, reason: 'Fixture transfer' }, p_request_id: randomUUID() };
  await Promise.all([checked(owner.client.rpc('move_wallet_money', move)), checked(owner.client.rpc('move_wallet_money', move))]);
  const ledger = await checked(owner.client.rpc('get_wallet_ledger', { p_filters: { search: 'API-BK-123', wallet: bkash.wallet_id }, p_limit: 1 })); assert.equal(ledger.total, 1); assert.equal(ledger.entries[0].amount, 700);
  const unpaid = await checked(owner.client.rpc('create_pos_sale', { ...args, p_request_id: randomUUID(), p_payments: [] })); assert.equal(unpaid.due, 2300);
  await rejected(owner.client.rpc('collect_sale_payment', { ...collectionArgs, p_sale_id: unpaid.sale_id, p_request_id: randomUUID(), p_payments: [{ wallet_id: cash.wallet_id, amount: 2301 }] }));
  await rejected(other.client.rpc('get_sale_settlement', { p_sale_id: sid }));
  await rejected(other.client.rpc('collect_sale_payment', { ...collectionArgs, p_request_id: randomUUID() }));
  await rejected(other.client.rpc('move_wallet_money', { ...move, p_request_id: randomUUID() }));
  const anon = createClient(url, key, { auth: { persistSession: false } }); await rejected(anon.rpc('get_wallet_ledger', {}));
  assert.equal((await checked(owner.client.rpc('get_finance_dues'))).due, 2300);
  assert.equal(sql(`select count(*) from public.wallets w where tenant_id=${uuid(owner.tenant)} and balance<>opening_balance+coalesce((select sum(amount) from public.wallet_transactions x where x.tenant_id=w.tenant_id and x.wallet_id=w.wallet_id),0)`), '0');
  console.log('PASS: real Auth/PostgREST business initialization, cash/split/zero checkout, concurrent retries, bank collection, customer balance, custom wallet/transfer, indexed ledger search, overpayment and cross-tenant denial');
} finally {
  if (tenants.length) {
    const ids = tenants.map(uuid).join(',');
    const tables = ['finance_requests','wallet_transactions','customer_transactions','sale_payments','sale_items','sales','inventory_movements','price_books','items','customers','receipt_printers','wallets','user_roles','role_permissions','roles','audit_logs','user_profiles','tenants'];
    sql(`begin;do $$begin if exists(select 1 from public.tenants where tenant_id in (${ids}) and business_name not like 'Finance API fixture%') then raise exception 'Not a finance fixture';end if;end$$;create temporary table finance_fixture_cleanup(id integer);create function pg_temp.finance_fixture_cleanup() returns trigger language plpgsql as $$begin ${tables.map(table => `delete from public.${table} where tenant_id in (${ids});`).join('\n')} return new;end$$;create trigger cleanup after insert on finance_fixture_cleanup for each row execute function pg_temp.finance_fixture_cleanup();insert into finance_fixture_cleanup values(1);commit;`);
  }
  if (users.length) sql(`delete from auth.users where id in (${users.map(uuid).join(',')});`);
  console.log('Removed only finance fixture businesses/accounts.');
}
