// Inject only response loss: the real authenticated server transaction commits first.
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { execFileSync } from 'node:child_process';
import { createClient } from '@supabase/supabase-js';
import { chromium } from 'playwright';
assert(process.argv.includes('--vps'));
const f = parseEnv(readFileSync('deploy/.env.frontend', 'utf8')), b = parseEnv(readFileSync('deploy/.env.backend', 'utf8')), s = parseEnv(readFileSync('.env.core-test', 'utf8'));
assert.equal(b.VPS_HOST, '144.79.249.4'); assert.equal(f.VITE_SUPABASE_URL, 'https://api.lpg.144.79.249.4.sslip.io');
const file = '.temp/core-business/manifest.json', m = JSON.parse(readFileSync(file, 'utf8'));
const c = createClient(f.VITE_SUPABASE_URL, f.VITE_SUPABASE_ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const auth = await c.auth.signInWithPassword({ email: s.LPG_TEST_EMAIL, password: s.LPG_TEST_PASSWORD }); assert(!auth.error);
const browser = await chromium.launch({ channel: 'chrome', headless: true });
const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
await context.addInitScript(({ key, value }) => localStorage.setItem(key, value), { key: `sb-${new URL(f.VITE_SUPABASE_URL).host}-auth-token`, value: JSON.stringify(auth.data.session) });
const page = await context.newPage(); page.setDefaultTimeout(25000);
try {
  if (m.recovery_transfer && !m.recovery_transfer.ui_recovered) { const prior = await c.rpc('move_wallet_money', m.recovery_transfer.args); assert(!prior.error, prior.error?.message); (m.recovery_attempts ??= []).push({ ...m.recovery_transfer, safely_confirmed_by_api: true }); delete m.recovery_transfer; writeFileSync(file, JSON.stringify(m, null, 2)); }
  if (!m.recovery_transfer) {
    let lost = false;
    await page.route(f.VITE_SUPABASE_URL + '/rest/v1/rpc/move_wallet_money', async route => {
      if (lost) return route.continue();
      const response = await route.fetch(); assert(response.ok(), 'Actual transfer must commit before fault injection');
      m.recovery_transfer = { args: route.request().postDataJSON(), result: await response.json(), response_lost: true }; writeFileSync(file, JSON.stringify(m, null, 2)); lost = true;
      await route.abort('failed');
    });
    await page.goto('https://floral-dew-443b.khandakarsifat.workers.dev/#/finance');
    await page.getByRole('button', { name: 'Transfer', exact: true }).click(); const d = page.getByRole('dialog').last();
    await d.getByLabel('From wallet', { exact: true }).selectOption(m.cash); await d.getByLabel('To wallet', { exact: true }).selectOption(m.bank);
    await d.getByLabel('Amount (Tk)', { exact: true }).fill('100'); await d.getByLabel('Reason / reference', { exact: true }).fill('Real transfer; response-loss recovery acceptance');
    await d.getByRole('button', { name: 'Record transfer', exact: true }).click(); await page.getByRole('button', { name: 'Recover transaction', exact: true }).first().waitFor();
    await page.reload(); await page.getByRole('button', { name: 'Transfer', exact: true }).click();
    await page.getByRole('dialog').last().getByRole('button', { name: 'Recover transaction', exact: true }).click();
    await page.getByText('Previous transaction confirmed', { exact: true }).waitFor();
    assert(lost); m.recovery_transfer.ui_recovered = true; writeFileSync(file, JSON.stringify(m, null, 2));
  } else if (!m.recovery_transfer.ui_recovered) {
    const r = await c.rpc('move_wallet_money', m.recovery_transfer.args); assert(!r.error, r.error?.message);
    throw Error('Original transfer safely recovered by API after interrupted acceptance; fresh UI fault test still required');
  }
  const id = m.recovery_transfer.args.p_request_id; assert.match(id, /^[0-9a-f-]{36}$/);
  const ssh = [...(b.VPS_SSH_KEY ? ['-i', b.VPS_SSH_KEY] : []), '-p', b.VPS_PORT, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', `${b.VPS_USER}@${b.VPS_HOST}`];
  const query = `select json_build_object('legs',count(*),'net',sum(amount),'principal',sum(abs(amount))/2) from public.wallet_transactions where operation_id='${id}';`;
  const result = JSON.parse(execFileSync('ssh', [...ssh, 'sudo -n docker exec -i lpg-db-1 psql -X -U supabase_admin -d postgres -qAt -v ON_ERROR_STOP=1'], { input: query, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] }));
  assert.deepEqual(result, { legs: 2, net: 0, principal: 100 });
  await page.screenshot({ path: '.temp/core-business/workflows/recovered-transfer-phone.png' });
  console.log('PASS actual committed transfer with lost HTTP response, browser reload and original-ID UI recovery: exactly two principal legs, no duplicate money');
} finally { await browser.close(); await c.auth.signOut({ scope: 'local' }); }
