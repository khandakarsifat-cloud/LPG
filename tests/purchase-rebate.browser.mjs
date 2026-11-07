// Actual published UI writes; only the response-loss scenario intercepts transport.
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { chromium } from 'playwright';
import { createClient } from '@supabase/supabase-js';
assert(process.argv.includes('--vps'));
const folder = '.temp/purchase-rebate-live', file = `${folder}/manifest.json`;
const m = JSON.parse(readFileSync(file, 'utf8')), secret = JSON.parse(readFileSync(`${folder}/credentials.json`, 'utf8'));
const f = parseEnv(readFileSync('deploy/.env.frontend', 'utf8'));
const api = 'https://api.lpg.144.79.249.4.sslip.io', url = 'https://floral-dew-443b.khandakarsifat.workers.dev'; assert.equal(f.VITE_SUPABASE_URL, api); assert(m.setup_at && !m.cleaned_at);
const c = createClient(api, f.VITE_SUPABASE_ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const checked = async p => { const { data, error } = await p; if (error) throw Error(error.message); return data; };
await checked(c.auth.signInWithPassword(secret)); assert.equal((await checked(c.rpc('get_access_context'))).tenant_id, m.tenant_id);
const browser = await chromium.launch({ channel: 'chrome', headless: true });
const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, serviceWorkers: 'block' });
const page = await context.newPage(); page.setDefaultTimeout(25000); const errors = []; page.on('pageerror', e => errors.push(e.message));
m.browser ??= {}; const persist = () => writeFileSync(file, JSON.stringify(m, null, 2));
const rpcURL = name => `${api}/rest/v1/rpc/${name}`;
const settled = async () => { await page.waitForLoadState('networkidle'); };
const fits = async label => assert(await page.evaluate(() => [document.documentElement, ...document.querySelectorAll('dialog[open]')].every(e => e.scrollWidth <= e.clientWidth + 2)), label + ' horizontal overflow');
const go = async () => { await page.goto(`${url}/?rebate-check=${Date.now()}#/purchases`); await page.locator('.purchases-page').waitFor(); await settled(); };
const open = async id => { await go(); await page.locator(`[data-purchase-id="${id}"]`).click(); await page.getByRole('dialog').last().waitFor(); await settled(); };
const commit = async (key, name, action) => {
  if (m.browser[key]?.result) return m.browser[key].result;
  if (m.browser[key]?.args) { const result = await checked(c.rpc(name, m.browser[key].args)); m.browser[key].result = result; persist(); return result; }
  const capture = request => { if (request.url() === rpcURL(name)) { m.browser[key] = { args: request.postDataJSON() }; persist(); } };
  page.on('request', capture);
  try {
    const response = page.waitForResponse(r => r.url() === rpcURL(name), { timeout: 90000 }); void response.catch(() => {}); await action();
    const r = await response, result = await r.json(); assert(r.ok(), result.message ?? 'UI operation failed');
    m.browser[key].result = result; persist(); await settled(); await page.waitForFunction(() => document.querySelectorAll('dialog[open]').length <= 1); return result;
  } finally { page.off('request', capture); }
};
try {
  await page.goto(`${url}/#/login`); await page.getByLabel('Email Address', { exact: true }).fill(secret.email); await page.getByLabel('Password', { exact: true }).fill(secret.password); await page.getByRole('button', { name: 'Sign In', exact: true }).click(); await page.waitForURL(u => !u.hash.includes('/login')); await settled();
  const before = await checked(c.rpc('get_product_inventory', { p_item_id: m.item }));
  if (!m.browser.recovered) {
    const current = (await checked(c.rpc('get_purchases_by_ids', { p_ids: [m.purchase] })))[0];
    if (current.rebate_amount === 5000) delete m.browser.lower;
    await open(m.purchase);
    await commit('lower', 'set_purchase_rebate', async () => { await page.getByLabel('Commission rebate used (Tk)', { exact: true }).fill('4000'); await page.getByRole('button', { name: 'Save rebate', exact: true }).click(); });
    assert.equal((await checked(c.rpc('get_purchase_settlement', { p_purchase_id: m.purchase }))).due, 2000);
    await fits('Desktop rebate editor'); await page.screenshot({ path: `${folder}/desktop-rebate-correction.png` });
    // Start the separate response-loss action from the freshly saved revision.
    // A network response alone does not await the prior mutation's cache updates.
    await open(m.purchase);
    await page.route(rpcURL('set_purchase_rebate'), async route => {
      m.browser.restore_request = route.request().postDataJSON(); persist();
      const response = await route.fetch(); assert.equal(response.status(), 200); await route.abort('failed');
    }, { times: 1 });
    await page.getByLabel('Commission rebate used (Tk)', { exact: true }).fill('5000'); await page.getByRole('button', { name: 'Save rebate', exact: true }).click();
    await page.getByRole('button', { name: 'Recover transaction', exact: true }).waitFor(); await page.reload();
    await page.locator(`[data-purchase-id="${m.purchase}"]`).click(); await page.getByRole('button', { name: 'Recover transaction', exact: true }).waitFor();
    const recovery = page.waitForResponse(r => r.url() === rpcURL('set_purchase_rebate'));
    await page.getByRole('button', { name: 'Recover transaction', exact: true }).click();
    const recovered = await recovery; assert(recovered.ok()); assert.deepEqual(recovered.request().postDataJSON(), m.browser.restore_request);
    await settled(); assert.equal((await checked(c.rpc('get_purchase_settlement', { p_purchase_id: m.purchase }))).due, 1000);
    m.browser.recovered = true; persist();
  }
  await open(m.purchase);
  await commit('final-setup-payment', 'record_purchase_payment', async () => {
    await page.getByRole('button', { name: 'Record payment', exact: true }).click(); const d = page.getByRole('dialog').last();
    await d.getByRole('button', { name: /^Pay remaining/ }).click(); await d.getByLabel('Payment 1 wallet', { exact: true }).selectOption(m.cash);
    await d.getByRole('button', { name: 'Record payment', exact: true }).click();
  });
  assert.equal(await page.getByRole('button', { name: 'Save rebate', exact: true }).count(), 0);
  const completed = (await checked(c.rpc('get_purchases_by_ids', { p_ids: [m.purchase] })))[0];
  const deniedCompleted = await c.rpc('set_purchase_rebate', { p_purchase_id: m.purchase, p_payload: { amount: 4000, revision: completed.revision }, p_request_id: crypto.randomUUID() });
  assert.match(deniedCompleted.error?.message ?? '', /Completed purchase commission rebate is locked/);
  const after = await checked(c.rpc('get_product_inventory', { p_item_id: m.item }));
  assert.deepEqual(after.buying_prices, before.buying_prices); assert.deepEqual(after.valuation, before.valuation);
  await page.setViewportSize({ width: 390, height: 844 }); await page.evaluate(() => document.documentElement.setAttribute('data-theme', 'dark'));
  const created = await commit('created', 'create_purchase', async () => {
    await go(); await page.getByRole('button', { name: 'New Purchase', exact: true }).click(); await page.getByRole('button', { name: 'LPG purchase', exact: true }).click();
    const d = page.getByRole('dialog').last(); await d.getByLabel('Destination plant', { exact: true }).selectOption(m.plant); await d.getByLabel('Vehicle (optional until dispatch)', { exact: true }).selectOption(m.truck);
    await d.getByRole('button', { name: 'Add product', exact: true }).click(); await d.getByLabel('Product 1', { exact: true }).selectOption(m.item);
    await d.getByLabel('Gas quantity', { exact: true }).fill('2'); await d.getByLabel('Additional Bottle quantity', { exact: true }).fill('2'); await d.getByLabel('Gas unit price (Tk)', { exact: true }).fill('1000'); await d.getByLabel('Bottle unit price (Tk)', { exact: true }).fill('2000');
    await d.getByLabel('Commission rebate used (Tk)', { exact: true }).fill('1000'); await fits('Phone purchase rebate field'); await page.screenshot({ path: `${folder}/phone-create-rebate.png` });
    await d.getByRole('button', { name: 'Create purchase', exact: true }).click(); await page.getByRole('dialog').last().getByRole('button', { name: 'Create purchase', exact: true }).click();
  });
  for (const [key, name, label] of [['dispatched', 'dispatch_purchase', 'Dispatch vehicle'], ['received', 'receive_purchase', 'Receive shipment']]) {
    if (m.browser[key]?.result) continue; await open(created.purchase_id);
    await commit(key, name, async () => { await page.getByRole('dialog').last().getByRole('button', { name: label, exact: true }).click(); await page.getByRole('dialog').last().getByRole('button', { name: label, exact: true }).click(); });
  }
  await open(created.purchase_id);
  await commit('paid', 'record_purchase_payment', async () => {
    await page.getByRole('button', { name: 'Record payment', exact: true }).click(); const d = page.getByRole('dialog').last();
    await d.getByRole('button', { name: /^Pay remaining/ }).click();
    await d.getByLabel('Payment 1 wallet', { exact: true }).selectOption(m.cash);
    assert.equal(Number(await d.getByLabel('Payment 1 amount', { exact: true }).inputValue()), 5000, 'Wallet payment defaults to gross payable less rebate');
    await fits('Phone rebate-adjusted payment'); await page.screenshot({ path: `${folder}/phone-net-payment.png` });
    await d.getByRole('button', { name: 'Record payment', exact: true }).click();
  });
  const p = (await checked(c.rpc('get_purchases_by_ids', { p_ids: [created.purchase_id] })))[0]; assert.equal(p.paid_amount, 5000); assert.equal(p.rebate_amount, 1000); assert.equal(p.total_cost, 6000); assert.equal(p.payment_status, 'paid');
  await open(created.purchase_id); await fits('Phone settled rebate summary'); await page.screenshot({ path: `${folder}/phone-settled-rebate.png` });
  for (const [width, theme] of [[1440, 'light'], [390, 'dark']]) {
    await page.setViewportSize({ width, height: width === 390 ? 844 : 1000 });
    await page.goto(`${url}/?rebate-finance=${Date.now()}#/finance`); await page.getByRole('heading', { name: 'Income performance', exact: true }).waitFor();
    await page.locator('.accounting-analysis[aria-busy=false]').waitFor(); await page.evaluate(t => document.documentElement.setAttribute('data-theme', t), theme);
    for (const position of ['Opening', 'Period movement', 'Closing']) {
      await page.getByRole('group', { name: 'Tabular reporting position' }).getByRole('button', { name: position, exact: true }).click();
      const differences = await page.locator('.business-tabular tbody tr td:last-child').allTextContents(); assert.equal(differences.length, 4); assert(differences.every(v => /^(Tk\s*)?0(?:\.00)?$/.test(v.trim())));
    }
    await page.getByRole('button', { name: /^Period revenue/ }).click();
    const entries = page.locator('.accounting-entry-card').filter({ hasText: 'Company rebate' }); await entries.first().waitFor();
    const amounts = await entries.locator('.accounting-entry-amount > strong').allTextContents();
    const rebateTotal = amounts.reduce((sum, value) => sum + Number(value.replace(/[^0-9.-]/g, '')), 0);
    assert.equal(rebateTotal, m.events['stove-next-pay']?.completed ? 6300 : 6000, 'Finance shows confirmed rebate income exactly once');
    await fits('Rebate revenue drilldown'); await page.screenshot({ path: `${folder}/finance-rebate-${width}-${theme}.png` });
    await entries.first().getByRole('button', { name: 'View activity', exact: true }).click();
    await page.locator('.accounting-entry-card').filter({ hasText: 'Company rebate' }).first().getByRole('button', { name: 'View source record', exact: true }).click();
    await page.getByRole('heading', { name: /^(Completed purchase|Purchase details)$/ }).waitFor(); await fits('Rebate source purchase');
  }
  assert.deepEqual(errors, []); m.browser_verified_at = new Date().toISOString(); persist();
  console.log('PASS published desktop/phone rebate correction, original-ID recovery after an actual commit and lost response, unchanged buying prices/FIFO, component purchase/dispatch/receipt and net cash payment');
} catch (error) {
  if (!page.url().includes('/login') && !await page.locator('input[type=password]').count()) await page.screenshot({ path: `${folder}/failure.png` });
  throw error;
} finally { await browser.close(); await c.auth.signOut({ scope: 'local' }); }
