// Real PostgreSQL contracts and concurrency on a prefix-checked disposable clone.
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { parseEnv } from 'node:util';

assert(process.argv.includes('--vps'), 'Explicit --vps target required');
assert(process.argv.slice(2).every(arg=>arg==='--vps'), 'Unsupported current-suite option; historical replay requires its explicit replay runner');
const settings = parseEnv(readFileSync('deploy/.env.backend', 'utf8'));
assert.equal(settings.VPS_HOST, '144.79.249.4');
assert.equal(settings.VPS_PROJECT_DIR, '/opt/lpg');
const ssh = [...(settings.VPS_SSH_KEY ? ['-i', settings.VPS_SSH_KEY] : []), '-p', settings.VPS_PORT,
  '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ServerAliveInterval=15',
  '-o', 'ServerAliveCountMax=3', `${settings.VPS_USER}@${settings.VPS_HOST}`];
const migrations = readdirSync('supabase/migrations').filter(name => /^\d{14}_.+\.sql$/.test(name)).sort().map(name => ({
  version: name.slice(0, 14), name: name.slice(15, -4), sql: readFileSync(`supabase/migrations/${name}`, 'utf8'),
}));
const quote = value => "'" + value.replaceAll("'", "'\"'\"'") + "'";
const payload = {
  migrations, reset: readFileSync('deploy/business-data-reset.sql', 'utf8'),
  canonical_components: readFileSync('supabase/tests/component-inventory.sql', 'utf8'),
  component_concurrency: readFileSync('supabase/tests/component-concurrency.py', 'utf8'),
  access_helpers: readFileSync('supabase/tests/account-access-fixtures.sql', 'utf8'),
  visibility: readFileSync('supabase/tests/finance-visibility-performance.sql', 'utf8'),
  access_deletion: readFileSync('supabase/tests/access-performance-deletion.sql', 'utf8'),
  finance_actions: ['purchase-rebate.sql','purchase-transport-cash.sql','summarized-actions.sql'].map(name=>({name,sql:readFileSync('supabase/tests/'+name,'utf8')})),
};

try {
  const result = execFileSync('ssh', [...ssh, 'sudo -n python3 -B -c ' + quote(readFileSync('supabase/tests/core-overhaul-runner.py', 'utf8'))], {
    input: JSON.stringify(payload), encoding: 'utf8', maxBuffer: 4 * 1024 * 1024, timeout: 40 * 60 * 1000,
    windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'],
  });
  process.stdout.write(result);
} catch (error) {
  if (error.stdout) process.stdout.write(error.stdout);
  if (error.stderr) process.stderr.write(error.stderr);
  process.exitCode = 1;
}
