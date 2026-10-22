// Eight independent forwards avoid the Windows OpenSSH per-process socket limit.
// No public port is opened; every connection still targets the isolated API.
import { config, cleanEnv } from '../../../deploy/deploy.mjs';
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import assert from 'node:assert/strict';

const backend = config('backend');
assert.equal(backend.AZURE_HOST, '20.40.48.3', 'Only the existing development VPS');
assert.equal(backend.AZURE_PROJECT_DIR, '/opt/lpg');
mkdirSync('.temp/business-load', { recursive: true });
assert(!existsSync('.temp/business-load/stop-tunnels'), 'Remove the prior stop marker before starting');
const children = Array.from({ length: 8 }, (_, index) => spawn('ssh', [
  '-i', backend.AZURE_SSH_KEY, '-p', backend.AZURE_PORT,
  '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
  '-o', 'ExitOnForwardFailure=yes', '-o', 'ServerAliveInterval=30',
  '-N', '-L', `127.0.0.1:${53300 + index}:127.0.0.1:3300`,
  `${backend.AZURE_USER}@${backend.AZURE_HOST}`,
], { env: cleanEnv(), stdio: ['ignore', 'ignore', 'inherit'], windowsHide: true }));
writeFileSync('.temp/business-load/tunnel-pids.json', JSON.stringify(children.map(child => child.pid)));
let closing = false;
function close(code = 0) {
  if (closing) return;
  closing = true;
  clearInterval(timer);
  for (const child of children) child.kill();
  process.exitCode = code;
}
for (const child of children) {
  child.on('error', () => close(1));
  child.on('exit', code => { if (!closing) close(code || 1); });
}
const timer = setInterval(() => {
  if (existsSync('.temp/business-load/stop-tunnels')) close();
}, 1000);
process.on('SIGINT', () => close());
process.on('SIGTERM', () => close());
console.log('Eight private SSH forwards started on localhost ports 53300–53307');
