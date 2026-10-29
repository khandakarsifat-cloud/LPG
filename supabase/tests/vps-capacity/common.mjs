import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { resolve } from 'node:path';
import { config } from '../../../deploy/deploy.mjs';

export const state = resolve(process.env.LPG_CAPACITY_STATE || '.temp/vps-capacity');
mkdirSync(state, { recursive: true });
export const backend = config('backend');
export const frontend = config('frontend');
export const sshArgs = [...(backend.VPS_SSH_KEY ? ['-i', backend.VPS_SSH_KEY] : []),
  '-p', backend.VPS_PORT, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
  '-o', 'ConnectTimeout=10', '-o', 'ServerAliveInterval=5', '-o', 'ServerAliveCountMax=3',
  `${backend.VPS_USER}@${backend.VPS_HOST}`];
export function remote(command, input, timeout = 600000) {
  try {
    return execFileSync('ssh', [...sshArgs, command], { input, encoding: 'utf8',
      timeout, maxBuffer: 32 * 1024 * 1024, windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] }).trim();
  } catch (error) {
    writeFileSync(resolve(state, 'private-error.txt'), String(error.stderr || error.message));
    throw new Error('Remote operation failed; inspect ignored private-error.txt locally (may contain fixture data).');
  }
}
// Bound orphaned preparation transactions if the Windows SSH connection drops.
// This applies only to this tooling's psql session, never application connections.
export const sql = query => remote('sudo -n docker exec -i lpg-db-1 psql -X -U supabase_admin -d postgres -qAt -v ON_ERROR_STOP=1',
  "set idle_in_transaction_session_timeout='30s';\n" + query);
export function read(name) { return JSON.parse(readFileSync(resolve(state, name), 'utf8')); }
export function save(name, value) { writeFileSync(resolve(state, name), JSON.stringify(value, null, 2)); }
export function uuid(value) {
  if (!/^[0-9a-f-]{36}$/i.test(value)) throw Error('Invalid fixture UUID');
  return `'${value}'::uuid`;
}
