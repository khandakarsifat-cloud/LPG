import { spawnSync } from 'node:child_process';
import { cleanEnv, config } from './deploy.mjs';

// Copy one credential directly to the user's clipboard; never log or save it.
try {
  const flags = process.argv.slice(2);
  if (flags.length > 1 || (flags.length && flags[0] !== '--username')) {
    throw new Error('Usage: dashboard-credentials.mjs [--username]');
  }
  const values = config('backend');
  const field = flags.length ? 'DASHBOARD_USERNAME' : 'DASHBOARD_PASSWORD';
  const script = `import json, subprocess, sys
args = ['docker', 'compose', '--project-directory', '${values.AZURE_PROJECT_DIR}', '--env-file', '${values.AZURE_PROJECT_DIR}/.env', '-p', '${values.AZURE_COMPOSE_PROJECT}', '-f', '${values.AZURE_PROJECT_DIR}/compose.yml', '-f', '${values.AZURE_PROJECT_DIR}/compose.azure.yml', 'ps', '-q', 'api-gw']
result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
if result.returncode or not result.stdout.strip(): sys.exit(1)
result = subprocess.run(['docker', 'inspect', result.stdout.decode().strip()], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
if result.returncode: sys.exit(1)
container = json.loads(result.stdout)[0]
if container['Config']['Labels'].get('com.docker.compose.project') != '${values.AZURE_COMPOSE_PROJECT}': sys.exit(1)
env = dict(entry.split('=', 1) for entry in container['Config']['Env'])
value = env.get('${field}', '')
if not value or '\\n' in value or '\\r' in value: sys.exit(1)
sys.stdout.write(value)
`;
  const result = spawnSync('ssh', ['-i', values.AZURE_SSH_KEY, '-p', values.AZURE_PORT,
    '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=15',
    `${values.AZURE_USER}@${values.AZURE_HOST}`, 'sudo -n python3 -'], {
    input: script, encoding: 'utf8', env: cleanEnv(), windowsHide: true,
  });
  if (result.error || result.status !== 0 || !result.stdout) throw new Error('Could not retrieve the dashboard credential over SSH. Check the existing backend connection.');
  const clipboard = spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', '$input | Set-Clipboard'], {
    input: result.stdout, encoding: 'utf8', env: cleanEnv(), windowsHide: true,
  });
  if (clipboard.error || clipboard.status !== 0) throw new Error('Could not copy the credential to the Windows clipboard.');
  console.log(`Dashboard ${flags.length ? 'username' : 'password'} copied to clipboard. Paste it into the HTTPS dashboard login.`);
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
