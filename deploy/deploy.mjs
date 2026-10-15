import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, readdirSync, lstatSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { parseEnv } from 'node:util';

export const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export const services = ['db', 'auth', 'rest', 'realtime', 'imgproxy', 'storage', 'meta', 'studio', 'api-gw', 'caddy'];
export const workerURL = 'https://floral-dew-443b.khandakarsifat.workers.dev';
const backendNames = ['AZURE_HOST', 'AZURE_USER', 'AZURE_PORT', 'AZURE_SSH_KEY', 'AZURE_PROJECT_DIR', 'AZURE_COMPOSE_PROJECT', 'PRODUCTION_API_URL'];
const frontendNames = ['CLOUDFLARE_ACCOUNT_ID', 'CLOUDFLARE_API_TOKEN', 'VITE_SUPABASE_URL', 'VITE_SUPABASE_ANON_KEY'];
const redactions = new Set();

export function cleanEnv(source = process.env) {
  const names = new Set(['path', 'systemroot', 'windir', 'temp', 'tmp', 'userprofile', 'home', 'appdata', 'localappdata', 'comspec', 'pathext', 'lang', 'programfiles', 'programfiles(x86)', 'programw6432', 'programdata', 'allusersprofile']);
  return Object.fromEntries(Object.entries(source).filter(([name]) => names.has(name.toLowerCase())));
}

function safeOutput(value) {
  let result = String(value ?? '');
  for (const secret of redactions) result = result.replaceAll(secret, '[redacted]');
  return result.replace(/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g, '[redacted JWT]');
}

function run(command, args, { env = cleanEnv(), input, quiet = false, binary = false } = {}) {
  const result = spawnSync(command, args, { cwd: root, env, input, encoding: binary || input instanceof Buffer ? undefined : 'utf8', maxBuffer: 32 * 1024 * 1024, windowsHide: true });
  if (result.error) throw new Error(`Cannot run ${command}: ${result.error.code}. Check deploy/README.md prerequisites.`);
  if (!quiet && result.stdout?.length) console.log(safeOutput(result.stdout));
  if (!quiet && result.stderr?.length) console.error(safeOutput(result.stderr));
  if (result.status !== 0) throw new Error(`${command} failed (exit ${result.status}); deployment stopped. See deploy/README.md recovery instructions.`);
  return result.stdout;
}

export function validateAPI(value) {
  const url = new URL(value);
  if (url.origin !== 'https://api.lpg.20.40.48.3.sslip.io' || url.pathname !== '/' || url.search || url.hash || url.username || url.password) {
    throw new Error('Production API must be https://api.lpg.20.40.48.3.sslip.io (the existing Azure gateway).');
  }
  return url.origin;
}

export function validateAnon(key) {
  try {
    const [header, payload, signature, extra] = key.split('.');
    const claims = JSON.parse(Buffer.from(payload, 'base64url').toString());
    if (!header || !signature || extra || claims.role !== 'anon' || (claims.exp && claims.exp * 1000 <= Date.now())) throw new Error();
  } catch {
    throw new Error('VITE_SUPABASE_ANON_KEY must be the existing, unexpired Azure anon JWT; secret/service_role keys are prohibited.');
  }
}

export function config(kind) {
  const file = resolve(root, 'deploy', `.env.${kind}`);
  if (!existsSync(file)) throw new Error(`Missing deploy/.env.${kind}. Copy deploy/.env.${kind}.example and populate it.`);
  const values = parseEnv(readFileSync(file, 'utf8'));
  const names = kind === 'backend' ? backendNames : frontendNames;
  const missing = names.filter(name => !values[name]?.trim() || /^(replace-|<)/.test(values[name]));
  if (missing.length) throw new Error(`Missing values in deploy/.env.${kind}: ${missing.join(', ')}`);
  const extra = Object.keys(values).filter(name => !names.includes(name));
  if (extra.length) throw new Error(`Unsupported variables in deploy/.env.${kind}: ${extra.join(', ')}. Backend secrets stay on the VPS.`);
  if (kind === 'backend') {
    for (const name of ['AZURE_HOST', 'AZURE_USER', 'AZURE_COMPOSE_PROJECT']) {
      if (!/^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(values[name])) throw new Error(`Invalid ${name}.`);
    }
    if (!/^\d+$/.test(values.AZURE_PORT) || Number(values.AZURE_PORT) < 1 || Number(values.AZURE_PORT) > 65535) throw new Error('Invalid AZURE_PORT.');
    if (!/^\/[a-zA-Z0-9_/-]+$/.test(values.AZURE_PROJECT_DIR) || ['/', '/opt', '/home', '/tmp'].includes(values.AZURE_PROJECT_DIR) || values.AZURE_PROJECT_DIR.includes('//')) throw new Error('AZURE_PROJECT_DIR must be a specific absolute Linux project directory.');
    if (!existsSync(values.AZURE_SSH_KEY)) throw new Error('AZURE_SSH_KEY does not exist. Use the existing private key; do not upload it.');
    validateAPI(values.PRODUCTION_API_URL);
  } else {
    if (!/^[a-f0-9]{32}$/i.test(values.CLOUDFLARE_ACCOUNT_ID)) throw new Error('CLOUDFLARE_ACCOUNT_ID must be the existing account ID (32 hexadecimal characters).');
    redactions.add(values.CLOUDFLARE_API_TOKEN);
    redactions.add(values.VITE_SUPABASE_ANON_KEY);
    validateAPI(values.VITE_SUPABASE_URL);
    validateAnon(values.VITE_SUPABASE_ANON_KEY);
  }
  return values;
}

export function validateGraph(model) {
  const enabled = Object.entries(model.services).filter(([, service]) => !service.profiles?.length).map(([name]) => name);
  if (enabled.length !== services.length || enabled.some(name => !services.includes(name))) throw new Error('Azure Compose must enable exactly the ten production services, including Studio/meta.');
  for (const name of services) {
    for (const dependency of Object.keys(model.services[name].depends_on ?? {})) {
      if (!services.includes(dependency)) throw new Error(`${name} pulls in excluded service ${dependency}.`);
    }
    if (model.services[name].build) throw new Error(`Production service ${name} unexpectedly builds an image.`);
  }
  for (const [key, name] of [['lpg_db_data', 'lpg_db_data'], ['lpg_storage_data', 'lpg_storage_data'], ['db-config', 'lpg_db-config']]) {
    if (!model.volumes[key]?.external || model.volumes[key].name !== name) throw new Error(`Persistent volume ${key} changed; deployment refused.`);
  }
}

export function backendFiles() {
  const migrations = readdirSync(resolve(root, 'supabase/migrations')).filter(name => name.endsWith('.sql')).sort();
  const versions = new Set();
  for (const name of migrations) {
    const match = /^(\d{14})_[a-zA-Z0-9_]+\.sql$/.exec(name);
    if (!match || versions.has(match[1])) throw new Error(`Invalid or duplicate migration version: ${name}`);
    versions.add(match[1]);
  }
  const files = ['compose.yml', 'compose.azure.yml', 'deploy/Caddyfile', 'deploy/backend.py',
    ...readdirSync(resolve(root, 'supabase/docker/volumes/api/envoy')).filter(name => /\.(yaml|sh)$/.test(name)).map(name => `supabase/docker/volumes/api/envoy/${name}`),
    ...migrations.map(name => `supabase/migrations/${name}`)];
  for (const file of files) if (!lstatSync(resolve(root, file)).isFile()) throw new Error(`Deployment files must be regular files: ${file}`);
  return files;
}

function checkBackend() {
  backendFiles();
  try {
    // Synthetic placeholders only: never render the private development .env.
    const output = run('docker', ['compose', '--env-file', '.env.example', '-f', 'compose.yml', '-f', 'compose.azure.yml', 'config', '--format', 'json'], {
      env: { ...cleanEnv(), API_DOMAIN: 'api.lpg.20.40.48.3.sslip.io' }, quiet: true,
    });
    validateGraph(JSON.parse(output));
    console.log('Azure Compose validated: ten production services, safe dependencies and external data volumes.');
  } catch (error) {
    if (error.message?.includes('Cannot run docker: ENOENT')) {
      console.log('Local docker CLI not found; Compose validation will be enforced remotely by the VPS updater.');
      return;
    }
    throw error;
  }
}

async function cloudflare(config, path) {
  const response = await fetch(`https://api.cloudflare.com/client/v4/accounts/${config.CLOUDFLARE_ACCOUNT_ID}/workers/${path}`, {
    headers: { Authorization: `Bearer ${config.CLOUDFLARE_API_TOKEN}` }, signal: AbortSignal.timeout(20000),
  });
  const body = await response.json();
  if (!response.ok || !body.success) throw new Error(`Cloudflare read-only preflight failed (HTTP ${response.status}). Check account ID, existing Worker and token permissions.`);
  return body.result;
}

async function checkRemoteWorker(values) {
  const subdomain = await cloudflare(values, 'subdomain');
  if (subdomain.subdomain !== 'khandakarsifat') throw new Error('Cloudflare account does not own the expected khandakarsifat.workers.dev URL.');
  const script = await cloudflare(values, 'scripts/floral-dew-443b/subdomain');
  if (!script.enabled) throw new Error('Existing floral-dew-443b Worker is missing or its workers.dev URL is disabled. No Worker will be created.');
  const settings = await cloudflare(values, 'scripts/floral-dew-443b/settings');
  if ((settings.bindings ?? []).some(binding => !['plain_text', 'secret_text', 'assets'].includes(binding.type))) {
    throw new Error('Existing Worker has non-static bindings. Inspect and reconcile its configuration before deploying.');
  }
  console.log('Verified existing Worker and expected account subdomain.');
}

export function validateRESTHealth(status, body) {
  // A zero-row request must reach PostgREST and preserve anonymous denial.
  if (![401, 403].includes(status) || body?.code !== '42501') throw new Error('REST health/anonymous authorization check failed. Expected the existing permission-denied response from PostgREST.');
}

export async function checkPublicAPI(url, anon) {
  validateAnon(anon);
  for (const path of ['/auth/v1/health', '/rest/v1/items?select=*&limit=0', '/storage/v1/status']) {
    const response = await fetch(`${url}${path}`, { headers: { apikey: anon, Authorization: `Bearer ${anon}` }, signal: AbortSignal.timeout(20000), redirect: 'error' });
    if (path.startsWith('/rest/')) { validateRESTHealth(response.status, await response.json()); continue; }
    if (!response.ok) throw new Error(`Production API check failed: ${path} (HTTP ${response.status}). Frontend deployment stopped.`);
    await response.body?.cancel();
  }
}

function wrangler(values, dryRun) {
  run(process.execPath, ['node_modules/wrangler/bin/wrangler.js', 'deploy', '--config', 'wrangler.json', '--no-autoconfig', ...(dryRun ? ['--dry-run'] : [])], {
    env: { ...cleanEnv(), CI: 'true', WRANGLER_SEND_METRICS: 'false', WRANGLER_LOG_SANITIZE: 'true', CLOUDFLARE_LOAD_DEV_VARS_FROM_DOT_ENV: 'false',
      ...(dryRun ? {} : { CLOUDFLARE_ACCOUNT_ID: values.CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_API_TOKEN: values.CLOUDFLARE_API_TOKEN }) },
  });
}

export function buildFrontend(values) {
  const worker = JSON.parse(readFileSync(resolve(root, 'wrangler.json'), 'utf8'));
  if (worker.name !== 'floral-dew-443b' || worker.assets?.directory !== './dist' || worker.account_id || worker.env || worker.main || worker.routes) throw new Error('Wrangler config changed the target or static asset workflow.');
  const env = cleanEnv();
  run(process.execPath, ['node_modules/typescript/bin/tsc', '-b'], { env });
  run(process.execPath, ['deploy/frontend-build.mjs'], { env: { ...env, VITE_SUPABASE_URL: validateAPI(values.VITE_SUPABASE_URL), VITE_SUPABASE_ANON_KEY: values.VITE_SUPABASE_ANON_KEY } });
  if (!existsSync(resolve(root, 'dist/index.html'))) throw new Error('Production build did not generate dist/index.html.');
  wrangler(values, true);
}

export function shellQuote(value) { return `'${value.replaceAll("'", "'\\''")}'`; }

async function deployBackend(values, approval) {
  const files = backendFiles();
  const archive = run('tar', ['-cf', '-', ...files], { quiet: true, binary: true });
  // tar bytes must remain binary on Windows.
  const sshArgs = ['-i', values.AZURE_SSH_KEY, '-p', values.AZURE_PORT, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=15', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=3', `${values.AZURE_USER}@${values.AZURE_HOST}`];
  const command = `umask 077; stage=$(mktemp -d /tmp/lpg-deploy.XXXXXX) || exit 1; tar -xf - -C "$stage" && sudo -n python3 "$stage/deploy/backend.py" ${shellQuote(values.AZURE_PROJECT_DIR)} "$stage" ${shellQuote(values.AZURE_COMPOSE_PROJECT)} ${shellQuote(validateAPI(values.PRODUCTION_API_URL))} ${shellQuote(approval)}; result=$?; rm -rf -- "$stage"; exit "$result"`;
  run('ssh', [...sshArgs, command], { input: archive });
  // The updater verifies public Auth/REST/Storage with the VPS anon key and
  // checks the dashboard login. Bare health requests are gateway-protected.
  // Frontend/all also checks these endpoints from Windows with its public key.
  console.log('Azure deployment and public HTTPS health check passed.');
}

export async function main(args = process.argv.slice(2)) {
  const [target, ...flags] = args;
  if (!['backend', 'frontend', 'all'].includes(target) || flags.some(flag => flag !== '--check' && !/^--approve-migrations=(\d{14}(,\d{14})*)$/.test(flag))) throw new Error('Usage: deploy.mjs backend|frontend|all [--check] [--approve-migrations=version,...]');
  if (flags.filter(flag => flag.startsWith('--approve-migrations=')).length > 1) throw new Error('Supply migration approval once.');
  const check = flags.includes('--check');
  const approval = flags.find(flag => flag.startsWith('--approve-migrations='))?.split('=')[1] ?? '';
  if (check && approval) throw new Error('--check cannot be combined with migration approval.');
  if (target === 'frontend' && approval) throw new Error('Migration approval applies only to backend/all.');
  const backend = target !== 'frontend' ? config('backend') : undefined;
  const frontend = target !== 'backend' ? config('frontend') : undefined;
  if (backend && frontend && validateAPI(backend.PRODUCTION_API_URL) !== validateAPI(frontend.VITE_SUPABASE_URL)) throw new Error('Backend and frontend production API URLs differ.');
  if (backend) checkBackend();
  if (frontend) buildFrontend(frontend);
  if (check) { console.log('Local validation passed. No SSH/API calls or publishing performed.'); return; }
  if (frontend) await checkRemoteWorker(frontend);
  if (backend) await deployBackend(backend, approval);
  if (frontend) {
    await checkPublicAPI(validateAPI(frontend.VITE_SUPABASE_URL), frontend.VITE_SUPABASE_ANON_KEY);
    wrangler(frontend, false);
    const response = await fetch(`${workerURL}/?deployment-check=${Date.now()}`, { signal: AbortSignal.timeout(20000) });
    if (!response.ok || !(await response.text()).includes('<div id="root">')) throw new Error('Worker published, but frontend HTML verification failed. See recovery instructions.');
    console.log(`Frontend deployed and reachable at ${workerURL}/`);
  }
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
  main().catch(error => { console.error(`Deployment error: ${safeOutput(error.message)}`); process.exitCode = 1; });
}
