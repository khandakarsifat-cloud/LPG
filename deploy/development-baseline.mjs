import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { parseEnv } from 'node:util';

const [action, ...flags] = process.argv.slice(2);
assert(['preflight', 'prepare', 'status', 'reset', 'release', 'complete', 'abort'].includes(action), 'Expected a baseline action');
assert(flags.includes('--vps'), 'Explicit --vps target required');
assert(flags.every(flag => flag === '--vps' || flag === '--delete-business-data' || /^--preserve-admin=[0-9a-f-]{36}$/.test(flag) || /^--snapshot=[0-9a-f]{64}$/.test(flag)), 'Unknown baseline argument');
const administrator = flags.find(flag => flag.startsWith('--preserve-admin='))?.split('=')[1];
const snapshot = flags.find(flag => flag.startsWith('--snapshot='))?.split('=')[1];
if (action === 'prepare' || action === 'reset') assert(administrator, 'Identify the existing administrator to preserve');
if (action === 'reset') assert(snapshot && flags.includes('--delete-business-data'), 'Verified snapshot and explicit business-data deletion flag are required');
if (action === 'complete') assert(snapshot, 'New verified full snapshot is required');
const settings = parseEnv(readFileSync('deploy/.env.backend', 'utf8'));
assert.equal(settings.VPS_HOST, '144.79.249.4'); assert.equal(settings.VPS_PROJECT_DIR, '/opt/lpg');
const ssh = [...(settings.VPS_SSH_KEY ? ['-i', settings.VPS_SSH_KEY] : []), '-p', settings.VPS_PORT,
  '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=3',
  `${settings.VPS_USER}@${settings.VPS_HOST}`];
const quote = value => "'" + value.replaceAll("'", "'\"'\"'") + "'";
try {
  const result = execFileSync('ssh', [...ssh, 'sudo -n python3 -B -c ' + quote(readFileSync('deploy/development-baseline.py', 'utf8'))], {
    input: JSON.stringify({ action, administrator, snapshot, delete_business_data: flags.includes('--delete-business-data'), reset_sql: action === 'reset' ? readFileSync('deploy/business-data-reset.sql', 'utf8') : undefined }),
    encoding: 'utf8', timeout: 10 * 60 * 1000, maxBuffer: 2 * 1024 * 1024, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'],
  });
  process.stdout.write(result);
} catch (error) {
  if (error.stdout) process.stdout.write(error.stdout);
  if (error.stderr) process.stderr.write(error.stderr);
  process.exitCode = 1;
}
