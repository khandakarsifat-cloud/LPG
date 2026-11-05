// Real published UI mutations. Persist request bodies before observing a response.
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { createClient } from '@supabase/supabase-js';
import { chromium } from 'playwright';
assert(process.argv.includes('--vps'));
const f = parseEnv(readFileSync('deploy/.env.frontend', 'utf8')), secret = parseEnv(readFileSync('.env.core-test', 'utf8'));
const api = 'https://api.lpg.144.79.249.4.sslip.io', base = 'https://floral-dew-443b.khandakarsifat.workers.dev'; assert.equal(f.VITE_SUPABASE_URL, api);
const file = '.temp/core-business/manifest.json', m = JSON.parse(readFileSync(file, 'utf8')); assert(m.verified_at);
const folder = '.temp/core-business/workflows'; mkdirSync(folder, { recursive: true });
const c = createClient(api, f.VITE_SUPABASE_ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const auth = await c.auth.signInWithPassword({ email: secret.LPG_TEST_EMAIL, password: secret.LPG_TEST_PASSWORD }); assert(!auth.error);
assert.equal((await c.from('user_profiles').select('tenant_id').eq('user_id', auth.data.user.id).single()).data.tenant_id, m.tenant_id);
const browser = await chromium.launch({ channel: 'chrome', headless: true });
const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, reducedMotion: 'reduce' });
await context.addInitScript(({ key, value }) => localStorage.setItem(key, value), { key: `sb-${new URL(api).host}-auth-token`, value: JSON.stringify(auth.data.session) });
const page = await context.newPage(); page.setDefaultTimeout(25000); const errors = []; page.on('pageerror', e => errors.push(e.message));
const persist = () => writeFileSync(file, JSON.stringify(m, null, 2));
const settled = async () => { await page.waitForLoadState('networkidle'); await page.waitForFunction(() => ![...document.querySelectorAll('.page-content,dialog[open]')].some(e => /\bLoading\b/.test(e.innerText))); };
const go = async route => { await page.goto(`${base}/?core-operator=${Date.now()}#/${route}`); await settled(); };
async function commit(key, name, action) {
  m.browser_requests ??= {};
  const prior = m.browser_requests[key]; if (prior?.completed) return prior.result;
  if (prior) { const r = await c.rpc(prior.name, prior.args); assert(!r.error, r.error?.message); prior.completed = true; prior.result = r.data; persist(); return r.data; }
  const req = page.waitForRequest(r => r.method() === 'POST' && r.url().endsWith('/rpc/' + name)).catch(() => null);
  const res = page.waitForResponse(r => r.request().method() === 'POST' && r.url().endsWith('/rpc/' + name)).catch(() => null);
  await action(); const original = await req; assert(original, 'Expected operation request'); m.browser_requests[key] = { name, args: original.postDataJSON() }; persist();
  const response = await res; assert(response, 'Expected operation response'); const result = await response.json(); assert(response.ok(), JSON.stringify(result));
  Object.assign(m.browser_requests[key], { completed: true, result }); persist(); await settled(); return result;
}
try {
  await go('finance');
  await commit('capital', 'move_wallet_money', async () => {
    await page.getByRole('button', { name: 'Adjust balance', exact: true }).click(); const d = page.getByRole('dialog').last();
    await d.getByLabel('Purpose', { exact: true }).selectOption('capital'); await d.getByLabel('Wallet', { exact: true }).selectOption(m.cash);
    await d.getByLabel('Amount (Tk)', { exact: true }).fill('1'); await d.getByLabel('Reason / reference', { exact: true }).fill('Browser verified capital contribution');
    await d.getByRole('button', { name: 'Record adjustment', exact: true }).click();
  });
  await go('finance'); const catalog = await c.rpc('get_financial_catalog'); const definition = catalog.data.types.find(t => t.name === 'Shared shop electricity'); assert(definition);
  await commit('expense', 'record_financial_entry', async () => {
    await page.getByRole('button', { name: 'Financial entry', exact: true }).click(); const d = page.getByRole('dialog').last();
    await d.getByLabel('Type', { exact: true }).click(); await d.getByRole('option', { name: /Shared shop electricity/ }).click(); await d.getByLabel('Paid from wallet', { exact: true }).selectOption(m.bank);
    await d.getByLabel('Amount (Tk)', { exact: true }).fill('5'); await d.getByLabel('Description / asset name', { exact: true }).fill('Browser shared operating cost');
    await d.getByRole('button', { name: 'Review entry', exact: true }).click(); await page.getByRole('dialog').last().getByRole('button', { name: 'Record entry', exact: true }).click();
  });
  await go('pos');
  await commit('package', 'create_pos_sale', async () => {
    await page.getByRole('button', { name: 'New Package for Jamuna 12kg', exact: true }).click();
    await page.getByPlaceholder('Phone, name, shop, address...').fill('01799000402'); await page.getByText('Karim retail store', { exact: true }).click();
    await page.getByRole('button', { name: 'Complete Checkout', exact: true }).click(); await page.getByRole('dialog').last().getByRole('button', { name: 'Confirm', exact: true }).click();
  });
  await go('purchases');
  const purchase = await commit('purchase', 'create_purchase', async () => {
    await page.getByRole('button', { name: 'New Purchase', exact: true }).click();
    const gas = page.getByRole('button', { name: 'LPG purchase', exact: true }); if (await gas.count()) await gas.click();
    const d = page.getByRole('dialog').last();
    await d.getByLabel('Destination plant', { exact: true }).selectOption(m.plant);
    await d.getByLabel('Vehicle (optional until dispatch)', { exact: true }).selectOption(m.truck);
    await d.getByRole('button', { name: 'Add product', exact: true }).click();
    await d.getByLabel('Product 1', { exact: true }).selectOption(m.jamuna);
    await d.getByLabel('Gas quantity', { exact: true }).fill('2');
    await d.getByLabel('Additional Bottle quantity', { exact: true }).fill('2');
    await d.getByLabel('Gas unit price (Tk)', { exact: true }).fill('900');
    await d.getByLabel('Bottle unit price (Tk)', { exact: true }).fill('1800');
    await d.getByRole('button', { name: 'Create purchase', exact: true }).click();
    await page.getByRole('dialog').last().getByRole('button', { name: 'Create purchase', exact: true }).click();
  });
  for (const [key, name, label] of [['dispatch', 'dispatch_purchase', 'Dispatch vehicle'], ['receive', 'receive_purchase', 'Receive shipment']]) {
    if (m.browser_requests[key]?.completed) continue;
    await go('purchases'); await page.locator(`[data-purchase-id="${purchase.purchase_id}"]`).click();
    await commit(key, name, async () => {
      await page.getByRole('dialog').last().getByRole('button', { name: label, exact: true }).click();
      await page.getByRole('dialog').last().getByRole('button', { name: label, exact: true }).click();
    });
  }
  for (const [kind, label, price] of [['gas', 'Refill (Gas)', '950'], ['bottle', 'Empty (Bottle)', '1900']]) {
    await go('inventory');
    await commit('reference-' + kind, 'set_product_buying_price', async () => {
      await page.locator('.inv-tile').filter({ hasText: 'Jamuna' }).click();
      await page.locator('.product-buying').filter({ hasText: label }).getByRole('button', { name: 'Edit component price', exact: true }).click();
      const d = page.getByRole('dialog').last();
      await d.getByLabel('Approximate price (Tk)', { exact: true }).fill(price);
      await d.getByLabel('Reason for change', { exact: true }).fill('Owner updated current reference; original FIFO remains unchanged');
      await d.getByRole('button', { name: 'Save approximate price', exact: true }).click();
    });
  }
  assert.deepEqual(errors, []); m.browser_writes_verified_at = new Date().toISOString(); persist();
  await go('finance'); await page.screenshot({ path: `${folder}/finance-after-writes.png` });
  console.log('PASS published browser capital, expense, package POS checkout, Gas/Bottle purchase lifecycle and both current component-price edits; original request IDs retained');
} catch (error) {
  if (!page.url().includes('/login')) await page.screenshot({ path: `${folder}/failure.png` });
  console.error(String(error.stack).replaceAll(secret.LPG_TEST_PASSWORD, '[redacted]')); process.exitCode = 1;
} finally { await browser.close(); await c.auth.signOut({ scope: 'local' }); }
