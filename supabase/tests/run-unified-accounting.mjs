// Real PostgreSQL contracts and concurrency on a prefix-checked disposable clone.
import assert from 'node:assert/strict';
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { parseEnv } from 'node:util';

assert(process.argv.includes('--vps'), 'Explicit --vps target required');
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
const concurrencyFile = 'supabase/tests/core-overhaul-concurrency.py';
const payload = {
  migrations, reset: readFileSync('deploy/business-data-reset.sql', 'utf8'),
  access_helpers: readFileSync('supabase/tests/account-access-fixtures.sql', 'utf8'),
  transport_cash: readFileSync('supabase/tests/purchase-transport-cash.sql', 'utf8'),
  functional: readFileSync('supabase/tests/core-overhaul.sql', 'utf8'),
  security: readFileSync('supabase/tests/core-overhaul-security.sql', 'utf8'),
  rebate: readFileSync('supabase/tests/purchase-rebate.sql', 'utf8'),
  visibility: readFileSync('supabase/tests/finance-visibility-performance.sql', 'utf8'),
  access_performance_deletion: readFileSync('supabase/tests/access-performance-deletion.sql', 'utf8'),
  lending: readFileSync('supabase/tests/lending-and-activity.sql', 'utf8'),
  action_storage: readFileSync('supabase/tests/summarized-actions.sql', 'utf8'),
  fifo_cutover: readFileSync('supabase/tests/fifo-component-cutover.sql', 'utf8').split('-- FIFO CUTOVER BOUNDARY'),
  concurrency: existsSync(concurrencyFile) ? readFileSync(concurrencyFile, 'utf8') : '',
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
