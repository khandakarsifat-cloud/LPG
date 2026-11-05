// Integer-money expectations from the recorded original operations; no app valuation imports.
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { execFileSync } from 'node:child_process';
import { createClient } from '@supabase/supabase-js';
assert(process.argv.includes('--vps'));
const m = JSON.parse(readFileSync('.temp/core-business/manifest.json', 'utf8'));
const f = parseEnv(readFileSync('deploy/.env.frontend', 'utf8')), b = parseEnv(readFileSync('deploy/.env.backend', 'utf8')), secret = parseEnv(readFileSync('.env.core-test', 'utf8'));
assert.equal(b.VPS_HOST, '144.79.249.4'); assert.equal(f.VITE_SUPABASE_URL, 'https://api.lpg.144.79.249.4.sslip.io');
const c = createClient(f.VITE_SUPABASE_URL, f.VITE_SUPABASE_ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
assert(!(await c.auth.signInWithPassword({ email: secret.LPG_TEST_EMAIL, password: secret.LPG_TEST_PASSWORD })).error);
const cents = n => Math.round(Number(n) * 100), eq = (actual, expected, label) => assert.equal(cents(actual), cents(expected), label);
const ui = m.browser_requests ?? {}, capital = ui.capital?.completed ? 1 : 0, expense = ui.expense?.completed ? 5 : 0, issued = ui.package?.completed ? 4 : 3, acquired = ui.receive?.completed ? 2 : 0;
// 70 existing shells @1200 + 100 gas @800 +30 bottles @1600 +1300 external labour.
// Gas takes 80,000/128,000 of labour: 812.50/100 = 8.125 per gas.
const exchangeUnits = m.exchange_acceptance?.completed ? 2 : 0, incomingBottles = exchangeUnits ? 3900 : 0;
// Net consumed asset value includes separately acquired incoming exchange bottles.
const externalOpeningFilled = 213300, originalIssue = Math.round((issued + exchangeUnits) * (1200 + 800 + 8.125) * 100) / 100 - incomingBottles;
const lpgSupplies = externalOpeningFilled - originalIssue + acquired * (900 + 1800);
const stoveReceipt = m.stove_acceptance?.received ? 7600 : 0, stoveSale = m.stove_acceptance?.sold ? 1 : 0;
const serviceCost = m.assets_logistics?.verified ? 500 : 0, depreciation = m.assets_logistics?.verified ? 100 : 0;
const expected = {
  cash: 964800 + capital - expense + (issued === 4 ? 3000 : 0) + stoveSale * 2000 + (exchangeUnits ? 1000 : 0) - serviceCost,
  supplies: lpgSupplies + stoveReceipt - stoveSale * 3040,
  equipment: 510000 - depreciation, receivables: 5000 + stoveSale * 3000 + (exchangeUnits ? 1550 : 0), loan: 2500,
  payable: 99300 + acquired * 2700 + 14000 + stoveReceipt,
  capital: 1584000 + capital,
  revenue: issued * 3000 + 1000 + stoveSale * 5000 + (exchangeUnits ? 2550 : 0),
  expenses: originalIssue + 100 + 100 + 500 + expense + 16000 + stoveSale * 3040 + serviceCost + depreciation,
};
// Retained source expectations must not drift with later automatic payroll periods.
const asOf = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Dhaka' }).format(new Date(m.verified_at));
const reports = {};
try {
  for (const category of ['lpg', 'stove', 'logistics', 'all']) {
    const { data, error } = await c.rpc('get_finance_analysis', { p_filters: { from: asOf, to: asOf, grain: 'day', category } }); assert(!error, error?.message); reports[category] = data;
    for (const position of [data.opening, data.closing]) eq(position.assets, position.liabilities + position.equity, `${category} equation`);
  }
  for (const item of [m.jamuna, m.total]) {
    const { data, error } = await c.rpc('get_product_inventory', { p_item_id: item });
    assert(!error, error?.message);
    for (const week of data.weeks) assert.equal(Number(week.empty_return), exchangeUnits && week.start_date <= asOf && week.end_date >= asOf ? 1 : 0, 'Weekly empty receipts exclude the cancelled 2/1/1 sale');
  }
  const p = reports.all.closing;
  const transferPrincipal = 8000 + [...(m.recovery_attempts ?? []), ...(m.recovery_transfer ? [m.recovery_transfer] : [])].reduce((total, event) => total + Number(event.args.p_payload.amount), 0);
  eq(reports.all.totals.transfers, transferPrincipal, 'Independent transfer principal, counted once per original request');
  for (const category of ['lpg', 'stove', 'logistics']) eq(reports[category].totals.transfers, 0, 'Physical wallet transfer has no business allocation');
  eq(p.cash, expected.cash, 'Independent actual cash'); eq(p.capital, expected.capital, 'Independent capital');
  eq(p.revenue, expected.revenue, 'Independent invoice revenue'); eq(p.expenses, expected.expenses, 'Independent all external expenses');
  eq(p.assets, expected.cash + expected.supplies + expected.equipment + expected.receivables, 'Independent owned asset position');
  eq(p.liabilities, expected.loan + expected.payable, 'Independent source obligations');
  const internalIssued = (issued + exchangeUnits) * 16.25; // Value allocation: 2,600 ×80,000/128,000 ÷100 gas.
  const business = {
    lpg: { cash: 964700 + capital - expense * .6 + (issued === 4 ? 3000 : 0) + (exchangeUnits ? 1000 : 0), capital: 1084000 + capital, other_equity: 2600, revenue: issued * 3000 + (exchangeUnits ? 2550 : 0), expenses: originalIssue + internalIssued + 300 + expense * .6 + 16000 + depreciation * .7, liabilities: 99300 + acquired * 2700 + 14000 },
    stove: { cash: -600 - expense * .2 + stoveSale * 2000, capital: 0, other_equity: 200, revenue: stoveSale * 5000, expenses: 300 + expense * .2 + stoveSale * 3040 + depreciation * .3, liabilities: 2500 + stoveReceipt },
    logistics: { cash: 700 - expense * .2 - serviceCost, capital: 500000, other_equity: -2800, revenue: 3800, expenses: 300 + expense * .2 + serviceCost, liabilities: 0 },
  };
  for (const [category, fields] of Object.entries(business)) for (const [field, value] of Object.entries(fields)) eq(reports[category].closing[field], value, `Independent ${category}/${field}`);
  eq(reports.lpg.closing.assets, business.lpg.cash + lpgSupplies + 2600 - internalIssued + 7000 - depreciation * .7 + 5000 + (exchangeUnits ? 1550 : 0), 'Independent LPG assets including internal overhead');
  eq(reports.stove.closing.assets, business.stove.cash + 3000 - depreciation * .3 + stoveReceipt - stoveSale * 3040 + stoveSale * 3000, 'Independent Stove assets and negative pooled Cash');
  eq(reports.logistics.closing.assets, business.logistics.cash + 500000, 'Independent Logistics assets');
  const ssh = [...(b.VPS_SSH_KEY ? ['-i', b.VPS_SSH_KEY] : []), '-p', b.VPS_PORT, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', `${b.VPS_USER}@${b.VPS_HOST}`];
  assert.match(m.tenant_id, /^[0-9a-f-]{36}$/); assert.match(m.jamuna, /^[0-9a-f-]{36}$/);
  const query = `select json_build_object('quantity',(select filled_quantity from public.items where item_id='${m.jamuna}'),'value',(select filled_value from public.inventory_costs where item_id='${m.jamuna}'),'wallet',(select sum(balance) from public.wallets where tenant_id='${m.tenant_id}'),'wallets',(select json_agg(json_build_object('id',w.wallet_id,'balance',w.balance,'ledger',w.opening_balance+coalesce((select sum(x.amount) from public.wallet_transactions x where x.tenant_id=w.tenant_id and x.wallet_id=w.wallet_id),0))) from public.wallets w where w.tenant_id='${m.tenant_id}'),'journal',(select sum(amount) from public.accounting_lines where tenant_id='${m.tenant_id}' and account='cash'),'imbalances',(select count(*) from(select journal_id from public.accounting_lines where tenant_id='${m.tenant_id}' group by journal_id having sum(amount)<>0 or sum(consolidated_amount)<>0)x),'gas_value',(select sum(remaining_value-remaining_shell_value) from app_private.fifo_layers where tenant_id='${m.tenant_id}' and item_id='${m.jamuna}' and component='filled'),'bottle_value',(select sum(case when component='filled' then remaining_shell_value else remaining_value end) from app_private.fifo_layers where tenant_id='${m.tenant_id}' and item_id in('${m.jamuna}','${m.total}')),'internal_value',(select sum(remaining_internal_value) from app_private.fifo_layers where tenant_id='${m.tenant_id}' and item_id in('${m.jamuna}','${m.total}')),'inventory_mismatches',(select count(*) from public.inventory_costs p join public.items i using(tenant_id,item_id) where p.tenant_id='${m.tenant_id}' and (p.filled_quantity<>i.filled_quantity or p.empty_quantity<>i.empty_quantity)));`;
  const raw = JSON.parse(execFileSync('ssh', [...ssh, 'sudo -n docker exec -i lpg-db-1 psql -X -U supabase_admin -d postgres -qAt -v ON_ERROR_STOP=1'], { input: query, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] }));
  assert.equal(raw.quantity, 100 - issued - exchangeUnits + acquired); eq(raw.value, lpgSupplies - incomingBottles, 'Actual LPG filled FIFO assets'); eq(raw.wallet, expected.cash, 'Actual wallets'); eq(raw.journal, expected.cash, 'Canonical Cash'); for (const w of raw.wallets) { eq(w.balance, w.ledger, 'Every real wallet matches its ledger'); const originalTransfers = transferPrincipal - 8000; const expectedWallet = w.id === m.cash ? 963300 + capital + (issued === 4 ? 3000 : 0) + stoveSale * 1000 + (exchangeUnits ? 1000 : 0) - serviceCost - originalTransfers : w.id === m.bank ? 1500 - expense + stoveSale * 1000 + originalTransfers : 0; eq(w.balance, expectedWallet, 'Independent original-operation wallet balance'); }
  assert.equal(raw.imbalances, 0); assert.equal(raw.inventory_mismatches, 0);
  eq(raw.gas_value, 80812.50 + acquired * 900 - Math.round((issued + exchangeUnits) * 808.125 * 100) / 100, 'Independent historical Gas component');
  eq(raw.bottle_value, 84000 + 48487.50 + acquired * 1800 - (issued + exchangeUnits) * 1200 + incomingBottles, 'Independent historical and exchanged Bottle components');
  eq(raw.internal_value, 2600 - internalIssued, 'Independent internal carrying value eliminated on consolidation');
  writeFileSync('.temp/core-business/independent.json', JSON.stringify({ at: new Date().toISOString(), expected, business, raw, reports }, null, 2));
  console.log('PASS independent source-operation expectations: physical cylinders, historical FIFO assets, actual wallets, canonical Cash, full external revenue/expense, source liabilities/capital and all four report equations');
} finally { await c.auth.signOut({ scope: 'local' }); }
