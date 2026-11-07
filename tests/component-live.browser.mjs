// Published frontend uses normal authenticated API calls, with original requests retained for recovery.
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { createClient } from '@supabase/supabase-js';
import { chromium } from 'playwright';
import { execFileSync } from 'node:child_process';

assert(process.argv.includes('--vps'));
const folder = '.temp/component-acceptance', file = `${folder}/manifest.json`;
const m = JSON.parse(readFileSync(file, 'utf8')), secret = JSON.parse(readFileSync(`${folder}/credentials.json`, 'utf8'));
assert(m.setup_at && !m.cleaned_at);
const f = parseEnv(readFileSync('deploy/.env.frontend', 'utf8')), b = parseEnv(readFileSync('deploy/.env.backend', 'utf8'));
const api = 'https://api.lpg.144.79.249.4.sslip.io', base = 'https://floral-dew-443b.khandakarsifat.workers.dev';
assert.equal(f.VITE_SUPABASE_URL, api); assert.equal(b.VPS_HOST, '144.79.249.4');
const c = createClient(api, f.VITE_SUPABASE_ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const checked = async promise => { const { data, error } = await promise; if (error) throw Error(error.message); return data; };
const auth = await checked(c.auth.signInWithPassword(secret));
assert.equal((await checked(c.rpc('get_access_context'))).tenant_id, m.tenant_id);
const browser = await chromium.launch({ channel: 'chrome', headless: true });
const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, serviceWorkers: 'block', reducedMotion: 'reduce' });
await context.addInitScript(({ key, value }) => localStorage.setItem(key, value), { key: `sb-${new URL(api).host}-auth-token`, value: JSON.stringify(auth.session) });
const page = await context.newPage(); page.setDefaultTimeout(25000);
const errors = []; page.on('pageerror', error => errors.push(error.message));
const persist = () => writeFileSync(file, JSON.stringify(m, null, 2)); m.browser_requests ??= {};
const settled = async () => { await page.waitForLoadState('networkidle'); };
const go = async route => { await page.goto(`${base}/?component-acceptance=${Date.now()}#/${route}`); await settled(); };
const fits = async () => assert(await page.evaluate(() => [document.documentElement, ...document.querySelectorAll('dialog[open],.page-content')].every(e => e.scrollWidth <= e.clientWidth + 2)), 'No page/dialog horizontal overflow');
const commit = async (key, name, action) => {
  if (m.browser_requests[key]?.completed) return m.browser_requests[key].result;
  if (m.browser_requests[key]?.args) {
    const result = await checked(c.rpc(name, m.browser_requests[key].args));
    Object.assign(m.browser_requests[key], { completed: true, result }); persist(); return result;
  }
  const rpcURL = `${api}/rest/v1/rpc/${name}`;
  const capture = request => { if (request.url() === rpcURL && request.method() === 'POST') { m.browser_requests[key] = { name, args: request.postDataJSON() }; persist(); } };
  page.on('request', capture);
  try {
    const response = page.waitForResponse(r => r.url() === rpcURL && r.request().method() === 'POST'); void response.catch(() => {});
    await action(); const r = await response, result = await r.json(); assert(r.ok(), result.message ?? 'UI operation failed');
    Object.assign(m.browser_requests[key], { completed: true, result }); persist(); await settled(); return result;
  } finally { page.off('request', capture); }
};
const ssh = [...(b.VPS_SSH_KEY ? ['-i', b.VPS_SSH_KEY] : []), '-p', b.VPS_PORT, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', `${b.VPS_USER}@${b.VPS_HOST}`];
const evidence = () => JSON.parse(execFileSync('ssh', [...ssh, 'sudo -n docker exec -i lpg-db-1 psql -X -U supabase_admin -d postgres -qAt -v ON_ERROR_STOP=1'], {
  input: `select json_build_object('layers',(select jsonb_agg(to_jsonb(l) order by layer_id) from app_private.fifo_layers l where tenant_id='${m.tenant_id}'::uuid),
   'cost_events',(select count(*) from public.inventory_cost_entries where tenant_id='${m.tenant_id}'::uuid),'journals',(select count(*) from public.accounting_journals where tenant_id='${m.tenant_id}'::uuid));`, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'],
}));
try {
  await go('purchases');
  const purchase = await commit('purchase', 'create_purchase', async () => {
    await page.getByRole('button', { name: 'New Purchase', exact: true }).click();
    const choose = page.getByRole('button', { name: 'LPG purchase', exact: true }); if (await choose.count()) await choose.click();
    const d = page.getByRole('dialog').last();
    await d.getByLabel('Destination plant', { exact: true }).selectOption(m.plant);
    await d.getByLabel('Vehicle (optional until dispatch)', { exact: true }).selectOption(m.truck);
    await d.getByRole('button', { name: 'Add product', exact: true }).click();
    await d.getByLabel('Product 1', { exact: true }).selectOption(m.item);
    await d.getByLabel('Gas quantity', { exact: true }).fill('5');
    await d.getByLabel('Additional Bottle quantity', { exact: true }).fill('1');
    await d.getByLabel('Gas unit price (Tk)', { exact: true }).fill('700');
    await d.getByLabel('Bottle unit price (Tk)', { exact: true }).fill('150');
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
    if (key === 'dispatch') {
      assert.deepEqual(evidence(), m.before_browser, 'Published dispatch changes no layer, cost event or finance journal');
      const stock = await checked(c.from('items').select('gas_quantity,bottle_quantity').eq('item_id', m.item).single());
      assert.deepEqual(stock, { gas_quantity: 0, bottle_quantity: 3 });
    }
  }
  await go('inventory');
  assert.equal(await page.locator('[title="Total filled Component Gas cylinders: 5"]').count(), 1);
  assert.equal(await page.locator('[title="Total empty Component Gas cylinders: 3"]').count(), 1);
  await fits();
  await go('pos');
  await commit('package-sale', 'create_pos_sale', async () => {
    await page.getByRole('button', { name: 'New Package for Component Gas 12kg', exact: true }).click();
    await page.getByPlaceholder('Phone, name, shop, address...').fill('01799000732');
    await page.getByText('Component browser buyer', { exact: true }).click();
    await page.getByRole('button', { name: 'Complete Checkout', exact: true }).click();
    await page.getByRole('dialog').last().getByRole('button', { name: 'Confirm', exact: true }).click();
  });
  assert(m.browser_requests['package-sale'].args.p_items.every(line => ['package', 'refill'].includes(line.type)));
  for (const width of [1440, 390]) {
    await page.setViewportSize({ width, height: width === 390 ? 844 : 1000 });
    await go('finance');
    await page.getByRole('button', { name: 'Product performance & FIFO', exact: true }).click(); await settled();
    await page.locator('.product-choice').filter({ hasText: /^Component Gas/ }).click(); await settled();
    const panel = page.getByRole('region', { name: 'FIFO stock costs and margins' });
    for (const component of ['Gas', 'Bottle']) {
      await page.getByRole('group', { name: 'FIFO component' }).getByRole('button', { name: component, exact: true }).click(); await settled();
      assert((await panel.locator('tbody tr').allTextContents()).every(row => row.includes(component)));
      assert.equal(await panel.getByRole('alert').count(), 0); await fits();
    }
    await page.screenshot({ path: `${folder}/fifo-${width}.png` });
    await go('inventory');
    await page.getByRole('button', { name: 'Adjustment', exact: true }).click();
    const d = page.getByRole('dialog').last();
    assert.equal(await d.getByLabel('Gas quantity', { exact: true }).count(), 1);
    assert.equal(await d.getByLabel('Bottle quantity', { exact: true }).count(), 1);
    await fits();
  }
  assert.deepEqual(errors, []);
  m.browser_verified_at = new Date().toISOString(); persist();
  console.log('PASS published purchase dispatch/receipt and POS write paths, derived Filled/Empty display, canonical adjustment form, independent FIFO filters at desktop/phone widths');
} catch (error) {
  if (!page.url().includes('/login')) await page.screenshot({ path: `${folder}/failure.png` });
  throw error;
} finally { await browser.close(); await c.auth.signOut({ scope: 'local' }); }
