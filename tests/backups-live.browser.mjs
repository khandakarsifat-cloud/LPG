// New superadmin fixture + burner denial; real deployed Auth/controller, local candidate UI.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { resolve, extname } from 'node:path';
import { parseEnv } from 'node:util';
import { chromium } from 'playwright';
import { createClient } from '@supabase/supabase-js';
import { provisionTestIdentity } from '../supabase/tests/trusted-test-provisioning.mjs';

assert(process.argv.includes('--vps'), 'Use --vps explicitly');
const config = parseEnv(readFileSync('deploy/.env.frontend', 'utf8'));
const backend = parseEnv(readFileSync('deploy/.env.backend', 'utf8'));
const burnerEnv = { ...parseEnv(readFileSync('.env.live-test', 'utf8')), ...process.env };
const api = 'https://api.lpg.144.79.249.4.sslip.io', worker = 'https://floral-dew-443b.khandakarsifat.workers.dev';
assert.equal(config.VITE_SUPABASE_URL, api); assert.equal(backend.VPS_HOST, '144.79.249.4');
const client = () => createClient(api, config.VITE_SUPABASE_ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const burner = client(), admin = client();
const ssh = ['-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', `${backend.VPS_USER}@${backend.VPS_HOST}`];
const sql = input => execFileSync('ssh', [...ssh, 'sudo docker exec -i lpg-db-1 psql -X -U supabase_admin -d postgres -qAt -v ON_ERROR_STOP=1'], { input, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] }).trim();
async function call(c, path, body = {}) {
  const { data } = await c.auth.getSession();
  const response = await fetch(api + '/backups/v1/' + path, { method: 'POST', headers: { Authorization: 'Bearer ' + data.session.access_token, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  return { status: response.status, data: await response.json() };
}
const folder = '.temp/backups-live'; mkdirSync(folder, { recursive: true });
let fixture, browser;
const email = `backup-admin-${randomUUID().slice(0, 8)}@example.invalid`, password = randomUUID() + 'Aa9';
try {
  const signed = await burner.auth.signInWithPassword({ email: burnerEnv.LPG_TEST_EMAIL, password: burnerEnv.LPG_TEST_PASSWORD });
  assert(!signed.error); const access = await burner.rpc('get_access_context');
  assert.equal(access.data.role, 'OWNER'); assert(!access.data.is_superadmin);
  for (const path of ['status', 'queue', 'settings', 'connect', 'disconnect']) assert.equal((await call(burner, path)).status, 403, 'OWNER must be denied: ' + path);
  fixture = await provisionTestIdentity({ email, password, platform: true });
  writeFileSync(folder + '/manifest.json', JSON.stringify({ user_id: fixture.user_id, email, purpose: 'Disposable backup acceptance administrator' }));
  assert(!(await admin.auth.signInWithPassword({ email, password })).error);
  let state = await call(admin, 'status'); assert.equal(state.status, 200); assert(state.data.credentials_installed);
  assert(!JSON.stringify(state.data).includes('refresh_token'));
  browser = await chromium.launch({ channel: 'chrome', headless: true });
  for (const [label, width, height, theme] of [['desktop', 1440, 1000, 'light'], ['phone', 390, 844, 'light'], ['phone-dark', 390, 844, 'dark']]) {
    const context = await browser.newContext({ viewport: { width, height }, serviceWorkers: 'block' });
    if (!process.argv.includes('--published')) {
      await context.route(worker + '/**', route => {
        const path = new URL(route.request().url()).pathname;
        const file = resolve('dist', path === '/' ? 'index.html' : path.slice(1));
        assert(file.startsWith(resolve('dist')));
        const mime = { '.html': 'text/html', '.js': 'application/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png', '.webmanifest': 'application/manifest+json' }[extname(file)];
        try { return route.fulfill({ body: readFileSync(file), contentType: mime ?? 'application/octet-stream' }); } catch { return route.abort(); }
      });
    }
    const page = await context.newPage(); page.setDefaultTimeout(30_000);
    await page.goto(worker + '/?backup-acceptance=' + randomUUID() + '#/login');
    await page.getByLabel('Email Address', { exact: true }).fill(email); await page.getByLabel('Password', { exact: true }).fill(password);
    await page.getByRole('button', { name: 'Sign In', exact: true }).click();
    await page.getByRole('heading', { name: 'Platform overview', exact: true }).waitFor();
    await page.getByRole('button', { name: 'Backups', exact: true }).click();
    await page.getByRole('heading', { name: 'Google Drive', exact: true }).waitFor();
    if (theme === 'dark') await page.evaluate(() => document.documentElement.dataset.theme = 'dark');
    assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), 'Horizontal page overflow');
    await page.screenshot({ path: `${folder}/${label}.png`, fullPage: true });
    if (process.argv.includes('--visual-history')) {
      const live = (await call(admin, 'status')).data;
      const captured = '2026-11-02T20:00:00Z';
      const history = [
        { label: 'visual-incremental', snapshot_id: 'visual-only-1', captured_at: captured, type: 'incr', monthly: false, status: 'verified', available: true, backup_bytes: 237983, cloud_bytes_added: 1161238 },
        { label: 'visual-full', snapshot_id: 'visual-only-2', captured_at: '2026-11-01T20:00:00Z', type: 'full', monthly: true, status: 'verified', available: true, backup_bytes: 1201738231, cloud_bytes_added: 1205972697 },
        { label: 'visual-failed', snapshot_id: 'visual-only-3', captured_at: '2026-10-31T20:00:00Z', type: 'incr', monthly: false, status: 'failed', available: false, backup_bytes: 237983, cloud_bytes_added: 0, error: 'Visual fixture: verification could not finish. The sealed capture is preserved for retry.' },
      ];
      await page.route(api + '/backups/v1/status', route => route.fulfill({ json: { ...live, history } }));
      await page.getByRole('button', { name: 'Refresh status', exact: true }).click();
      await page.getByText('Verification failed', { exact: true }).waitFor();
      assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
      await page.screenshot({ path: `${folder}/${label}-history-visual-fixture.png`, fullPage: true });
      await page.unroute(api + '/backups/v1/status');
    }
    await page.getByRole('button', { name: 'Manage', exact: true }).click();
    await page.getByRole('dialog').waitFor();
    await page.screenshot({ path: `${folder}/${label}-schedule.png`, fullPage: true });
    await page.getByRole('button', { name: 'Cancel', exact: true }).click();
    await page.getByRole('button', { name: 'Recovery information', exact: true }).click();
    await page.getByRole('heading', { name: 'Disaster recovery', exact: true }).waitFor();
    await page.getByRole('button', { name: 'Close', exact: true }).click();
    if (label === 'desktop' && process.argv.includes('--controls')) {
      await page.getByRole('button', { name: 'Manage', exact: true }).click();
      await page.getByRole('button', { name: 'Pause schedule', exact: true }).click();
      await page.getByRole('dialog').waitFor({ state: 'detached' });
      assert.equal((await call(admin, 'status')).data.settings.enabled, false);
      await page.getByRole('button', { name: 'Manage', exact: true }).click();
      await page.getByRole('button', { name: 'Resume schedule', exact: true }).click();
      await page.getByRole('dialog').waitFor({ state: 'detached' });
      assert.equal((await call(admin, 'status')).data.settings.enabled, true);
      if (!(await call(admin, 'status')).data.queued) {
        await page.getByRole('button', { name: 'Request backup', exact: true }).click();
        await page.getByRole('button', { name: 'Queue backup', exact: true }).click();
        await page.getByRole('dialog').waitFor({ state: 'detached' });
      }
      assert.equal((await call(admin, 'status')).data.queued, true);
      console.log('PASS real superadmin pause/resume and queued manual backup UI actions.');
    }
    await context.close();
  }
  console.log('PASS desktop, phone, dark UI and dialogs; real superadmin access and OWNER denial; status contains no tokens.');
  if (process.argv.includes('--authorize')) {
    if (process.argv.includes('--disconnect-first')) {
      assert.equal((await call(admin, 'disconnect')).status, 200);
      assert.equal((await call(admin, 'status')).data.connection.connected, false);
      console.log('PASS superadmin disconnect removes the active credential from the backend.');
    }
    const result = await call(admin, 'connect'); assert.equal(result.status, 200);
    // Public OAuth authorize URL contains no backend secrets. User completes consent in their browser.
    execFileSync('rundll32', ['url.dll,FileProtocolHandler', result.data.url], { windowsHide: true, stdio: 'ignore' });
    console.log('GOOGLE_CONSENT_OPENED: complete authorization in the browser.');
    let connected = false;
    for (let attempt = 0; attempt < 120; attempt++) {
      await new Promise(r => setTimeout(r, 5000));
      state = await call(admin, 'status');
      if (state.data.connection?.connected && state.data.connection?.token_refresh_verified_at) { connected = true; break; }
      if (state.data.authorization_error) throw Error(state.data.authorization_error.message);
    }
    assert(connected, 'Google authorization was not completed within ten minutes.');
    console.log('PASS real Google consent, Drive quota/account verification and forced automatic token refresh.');
  }
} catch (error) {
  // Test errors must never print passwords, sessions, OAuth URLs/codes, or user rows.
  let message = String(error.message).replaceAll(password, '[redacted]');
  console.error(message.replace(/eyJ[\w-]+\.[\w-]+\.[\w-]+/g, '[redacted token]'));
  process.exitCode = 1;
} finally {
  await browser?.close();
  if (fixture) {
    await admin.auth.signOut({ scope: 'global' });
    assert.match(fixture.user_id, /^[a-f0-9-]{36}$/);
    sql(`begin;delete from app_private.access_audit where actor_id='${fixture.user_id}'::uuid;delete from app_private.platform_superadmins where user_id='${fixture.user_id}'::uuid;delete from auth.users where id='${fixture.user_id}'::uuid and email='${email}';commit;`);
    writeFileSync(folder + '/manifest.json', JSON.stringify({ user_id: fixture.user_id, email, cleaned: true }));
  }
  await burner.auth.signOut({ scope: 'local' });
}
