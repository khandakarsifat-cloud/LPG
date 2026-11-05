// Real authenticated full-backup acceptance. No interception or original admin credential changes.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { parseEnv } from 'node:util';
import { createClient } from '@supabase/supabase-js';
import { chromium } from 'playwright';
import { provisionTestIdentity } from '../supabase/tests/trusted-test-provisioning.mjs';
assert(process.argv.includes('--vps'), 'Explicit VPS target required');
const config = parseEnv(readFileSync('deploy/.env.frontend', 'utf8'));
const backend = parseEnv(readFileSync('deploy/.env.backend', 'utf8'));
const burner = parseEnv(readFileSync('.env.live-test', 'utf8'));
const api = 'https://api.lpg.144.79.249.4.sslip.io';
const url = 'https://floral-dew-443b.khandakarsifat.workers.dev';
assert.equal(config.VITE_SUPABASE_URL, api); assert.equal(backend.VPS_HOST, '144.79.249.4');
const client = () => createClient(api, config.VITE_SUPABASE_ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const admin = client(), owner = client();
const folder = '.temp/core-overhaul/manual-backup'; mkdirSync(folder, { recursive: true });
let email = `full-backup-${randomUUID().slice(0, 8)}@example.invalid`;
const password = randomUUID() + 'Aa9';
const resume = process.argv.includes('--resume-active');
const ssh = [...(backend.VPS_SSH_KEY ? ['-i', backend.VPS_SSH_KEY] : []), '-p', backend.VPS_PORT, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', `${backend.VPS_USER}@${backend.VPS_HOST}`];
let fixture, browser, jobId;
const call = async (c, path, body = {}) => {
  const { data } = await c.auth.getSession();
  const response = await fetch(`${api}/backups/v1/${path}`, { method: 'POST', headers: { Authorization: `Bearer ${data.session.access_token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  return { status: response.status, body: await response.json() };
};
try {
  assert(!(await owner.auth.signInWithPassword({ email: burner.LPG_TEST_EMAIL, password: burner.LPG_TEST_PASSWORD })).error);
  assert.equal((await call(owner, 'full', { request_id: randomUUID() })).status, 403);
  if (resume) {
    fixture = JSON.parse(readFileSync(`${folder}/fixture.json`, 'utf8'));
    assert(/^[0-9a-f-]{36}$/.test(fixture.user_id));
    const token = execFileSync('ssh', [...ssh, 'sudo docker exec -i lpg-db-1 psql -X -U supabase_admin -d postgres -qAt -v ON_ERROR_STOP=1'], { input: `select token from auth.refresh_tokens where user_id='${fixture.user_id}' and revoked=false order by created_at desc limit 1;`, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] }).trim();
    assert(token, 'The fixture has no recoverable test session');
    const result = await admin.auth.refreshSession({ refresh_token: token }); assert(!result.error);
    email = result.data.user.email; assert(email.startsWith('full-backup-') && email.endsWith('@example.invalid'));
  } else {
    fixture = await provisionTestIdentity({ email, password, platform: true });
    writeFileSync(`${folder}/fixture.json`, JSON.stringify({ user_id: fixture.user_id, purpose: 'Disposable Manual Full Backup acceptance administrator' }));
    assert(!(await admin.auth.signInWithPassword({ email, password })).error);
  }
  browser = await chromium.launch({ channel: 'chrome', headless: true });
  let context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, serviceWorkers: 'block' });
  let page = await context.newPage(); page.setDefaultTimeout(30000);
  let requestId;
  page.on('request', request => { if (request.url() === `${api}/backups/v1/full`) requestId = request.postDataJSON().request_id; });
  if (resume) {
    const { data } = await admin.auth.getSession();
    await context.addInitScript(({ key, value }) => localStorage.setItem(key, value), { key: `sb-${new URL(api).host}-auth-token`, value: JSON.stringify(data.session) });
    await page.goto(`${url}/#/admin?section=backups`);
  } else {
    await page.goto(`${url}/?full-backup=${randomUUID()}#/login`);
    await page.getByLabel('Email Address', { exact: true }).fill(email);
    await page.getByLabel('Password', { exact: true }).fill(password);
    await page.getByRole('button', { name: 'Sign In', exact: true }).click();
    await page.getByRole('button', { name: 'Backups', exact: true }).click();
  }
  const initial = await call(admin, 'status'); assert.equal(initial.status, 200);
  const schedule = initial.body.settings;
  if (!resume) {
    assert(!['queued', 'running'].includes(initial.body.job.status), 'Another backup is active; do not overlap');
    await page.getByRole('button', { name: /^(Create Full Backup|Retry Full Backup)$/ }).click();
    const dialog = page.getByRole('dialog');
    await dialog.getByRole('button', { name: 'Create Full Backup', exact: true }).click();
    await page.getByText('Full backup started on the server. The automatic schedule is unchanged.', { exact: true }).waitFor();
  } else requestId = initial.body.job.job_id;
  let state = (await call(admin, 'status')).body;
  jobId = state.job.job_id; assert.equal(jobId, requestId);
  assert.equal((await call(admin, 'full', { request_id: requestId })).status, 200);
  if (['queued', 'running'].includes(state.job.status)) assert.equal((await call(admin, 'full', { request_id: randomUUID() })).status, 409);
  assert.deepEqual(state.settings, schedule);
  await page.reload();
  await page.getByLabel('Full backup progress').waitFor();
  await page.screenshot({ path: `${folder}/desktop-progress.png` });
  await page.setViewportSize({ width: 390, height: 844 });
  assert(await page.evaluate(() => [...document.querySelectorAll('html,body,.page-content')].every(e => e.scrollWidth <= e.clientWidth + 2)), 'Phone backup page overflows');
  await page.screenshot({ path: `${folder}/phone-progress.png` });
  // Restart the actual browser process; the backup has no client-side lifetime.
  const { data: reconnect } = await admin.auth.getSession();
  await browser.close();
  browser = await chromium.launch({ channel: 'chrome', headless: true });
  context = await browser.newContext({ viewport: { width: 390, height: 844 }, colorScheme: 'dark', serviceWorkers: 'block' });
  await context.addInitScript(({ key, value }) => localStorage.setItem(key, value), { key: `sb-${new URL(api).host}-auth-token`, value: JSON.stringify(reconnect.session) });
  page = await context.newPage(); page.setDefaultTimeout(30000);
  await page.goto(`${url}/#/admin?section=backups`); await page.getByLabel('Full backup progress').waitFor();
  assert.equal((await call(admin, 'status')).body.job.job_id, jobId, 'Browser restart must reconnect to the original server job');
  await page.screenshot({ path: `${folder}/reconnected-browser-phone.png` });
  console.log(resume ? 'PASS published admin monitoring, ordinary-owner denial, original-request replay, overlap rejection, reload recovery and phone layout' : 'PASS real published admin action, ordinary-owner denial, idempotent replay, overlap rejection, reload recovery and phone layout');
  let phase; const samples = []; const start = Date.now();
  while (Date.now() - start < 60 * 60 * 1000) {
    state = (await call(admin, 'status')).body;
    assert.equal(state.job.job_id, jobId); assert.deepEqual(state.settings, schedule);
    assert(!JSON.stringify(state).includes('refresh_token'));
    samples.push({ at: new Date().toISOString(), ...state.job });
    writeFileSync(`${folder}/progress.json`, JSON.stringify(samples, null, 2));
    if (phase !== state.job.phase) { phase = state.job.phase; console.log(`Backup stage: ${phase}`); }
    if (state.job.status === 'completed') break;
    assert(['queued', 'running'].includes(state.job.status), state.job.error ?? 'Backup stopped without verification');
    await new Promise(resolve => setTimeout(resolve, 10000));
  }
  assert.equal(state.job.status, 'completed', 'Full backup verification timed out');
  if (process.argv.includes('--assert-network-progress')) assert(state.job.network_transferred_bytes > 0, 'The existing transfer engine must report actual network bytes');
  const point = state.history.find(p => p.job_id === jobId && p.available);
  assert(point && point.type === 'full' && point.status === 'verified');
  assert.equal(state.recovery.snapshot_id, point.snapshot_id);
  assert.equal(state.recovery.database.admin_identity_verified, true);
  assert(state.recovery.files_verified && state.recovery.auth_health && state.recovery.storage_health);
  writeFileSync(`${folder}/verified.json`, JSON.stringify({ job: state.job, point, recovery: state.recovery }, null, 2));
  await page.reload(); await page.getByRole('heading', { name: 'Completed', exact: true }).waitFor();
  await page.screenshot({ path: `${folder}/phone-verified.png` });
  console.log(`PASS full encrypted cloud backup and isolated restore: ${point.snapshot_id}; original admin identity verified`);
} finally {
  if (browser) await browser.close();
  if (fixture && (!jobId || (await call(admin, 'status')).body.job.status === 'completed')) {
    await admin.auth.signOut({ scope: 'global' });
    const args = [...(backend.VPS_SSH_KEY ? ['-i', backend.VPS_SSH_KEY] : []), '-p', backend.VPS_PORT, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', `${backend.VPS_USER}@${backend.VPS_HOST}`];
    execFileSync('ssh', [...args, 'sudo docker exec -i lpg-db-1 psql -X -U supabase_admin -d postgres -qAt -v ON_ERROR_STOP=1'], { input: `begin;delete from app_private.access_audit where actor_id='${fixture.user_id}'::uuid;delete from app_private.platform_superadmins where user_id='${fixture.user_id}'::uuid;delete from auth.users where id='${fixture.user_id}'::uuid and email='${email}';commit;`, stdio: ['pipe', 'pipe', 'pipe'] });
  }
}
