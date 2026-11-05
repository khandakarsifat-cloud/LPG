// Private Storage acceptance and existing isolated restore-drill credentials.
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { execFileSync } from 'node:child_process';
import { createClient } from '@supabase/supabase-js';
assert(process.argv.includes('--vps'));
const f = parseEnv(readFileSync('deploy/.env.frontend', 'utf8')), b = parseEnv(readFileSync('deploy/.env.backend', 'utf8')), s = parseEnv(readFileSync('.env.core-test', 'utf8'));
const file = '.temp/core-business/manifest.json', m = JSON.parse(readFileSync(file, 'utf8'));
assert.equal(b.VPS_HOST, '144.79.249.4'); assert.equal(f.VITE_SUPABASE_URL, 'https://api.lpg.144.79.249.4.sslip.io');
const c = createClient(f.VITE_SUPABASE_URL, f.VITE_SUPABASE_ANON_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
assert(!(await c.auth.signInWithPassword({ email: s.LPG_TEST_EMAIL, password: s.LPG_TEST_PASSWORD })).error);
try {
  const path = `${m.tenant_id}/core-recovery-proof.png`;
  const bytes = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII=', 'base64');
  if (!m.storage_path) { const r = await c.storage.from('product-images').upload(path, bytes, { contentType: 'image/png', cacheControl: '0' }); assert(!r.error, r.error?.message); m.storage_path = path; writeFileSync(file, JSON.stringify(m, null, 2)); }
  const r = await c.storage.from('product-images').download(path); assert(!r.error, r.error?.message); assert(Buffer.from(await r.data.arrayBuffer()).equals(bytes));
  const anon = createClient(f.VITE_SUPABASE_URL, f.VITE_SUPABASE_ANON_KEY, { auth: { persistSession: false } }); assert((await anon.storage.from('product-images').download(path)).error);
  const ssh = [...(b.VPS_SSH_KEY ? ['-i', b.VPS_SSH_KEY] : []), '-p', b.VPS_PORT, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', `${b.VPS_USER}@${b.VPS_HOST}`];
  const program = "import json,sys,os\nfrom pathlib import Path\np=Path('/opt/lpg/deploy/backup-secrets/acceptance.json')\nx=json.load(sys.stdin)\np.write_text(json.dumps(x))\np.chmod(0o600)\n";
  const quote = v => "'" + v.replaceAll("'", "'\"'\"'") + "'";
  execFileSync('ssh', [...ssh, 'sudo -n python3 -B -c ' + quote(program)], { input: JSON.stringify({ email: s.LPG_TEST_EMAIL, password: s.LPG_TEST_PASSWORD }), stdio: ['pipe', 'ignore', 'pipe'] });
  console.log('PASS actual private Storage upload/download, anonymous denial and fresh restore-drill membership configuration');
} finally { await c.auth.signOut({ scope: 'local' }); }
