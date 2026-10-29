import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { backendFiles, checkPublicAPI, cleanEnv, main, shellQuote, validateAnon, validateAPI, validateGraph, validateRESTHealth, services } from './deploy.mjs';

const anon = role => `${Buffer.from('{"alg":"HS256"}').toString('base64url')}.${Buffer.from(JSON.stringify({ role, exp: 4102444800 })).toString('base64url')}.signature`;

test('deployment children do not inherit development, privileged or injected build environment', () => {
  const env = cleanEnv({ PATH: 'bin', SystemRoot: 'windows', VITE_SUPABASE_URL: 'http://localhost:54321', VITE_PRIVATE: 'secret', SERVICE_ROLE_KEY: 'secret', CLOUDFLARE_API_TOKEN: 'secret', COMPOSE_FILE: 'dev.yml', NODE_OPTIONS: '--require injected.js' });
  assert.deepEqual(env, { PATH: 'bin', SystemRoot: 'windows' });
});

test('public configuration accepts only existing VPS endpoint and anon role', () => {
  assert.equal(validateAPI('https://api.lpg.144.79.249.4.sslip.io/'), 'https://api.lpg.144.79.249.4.sslip.io');
  for (const url of ['http://localhost:54321', 'https://example.com', 'https://api.lpg.144.79.249.4.sslip.io/?key=x']) assert.throws(() => validateAPI(url));
  validateAnon(anon('anon'));
  for (const key of [anon('service_role'), 'sb_secret_private', 'placeholder', '']) assert.throws(() => validateAnon(key));
});

test('production dependency closure rejects indirect development services and volume replacement', () => {
  const model = { services: Object.fromEntries(services.map(name => [name, {}])), volumes: { lpg_db_data: { external: true, name: 'lpg_db_data' }, lpg_storage_data: { external: true, name: 'lpg_storage_data' }, 'db-config': { external: true, name: 'lpg_db-config' } } };
  validateGraph(model);
  model.services.mailpit = { profiles: ['development'] };
  model.services.auth.depends_on = { mailpit: {} };
  assert.throws(() => validateGraph(model), /excluded/);
  delete model.services.auth.depends_on;
  model.services.db.ports = [{ target: 5432, published: '5432', host_ip: '0.0.0.0' }];
  assert.throws(() => validateGraph(model), /publicly published/);
  delete model.services.db.ports;
  model.services.caddy.ports = [{ target: 443, published: '8443', host_ip: '0.0.0.0' }];
  assert.throws(() => validateGraph(model), /80\/443/);
  delete model.services.caddy.ports;
  model.volumes.lpg_db_data.external = false;
  assert.throws(() => validateGraph(model), /volume/);
});

test('routine bundle excludes environments, credentials, local data and bootstrap initialization', () => {
  const files = backendFiles();
  assert(files.includes('compose.vps.yml'));
  assert(files.some(name => name.startsWith('supabase/migrations/')));
  assert(!files.some(name => /\.env|\.pem|bootstrap|storage\/|volumes\/db\//.test(name)));
  const initial = backendFiles(true);
  assert(initial.includes('deploy/bootstrap.py'));
  assert(initial.includes('.env.example'));
  assert(initial.includes('supabase/docker/volumes/db/roles.sql'));
  assert(!initial.some(name => /(^|\/)\.env$|\.env\.(backend|frontend)$|\.pem/.test(name)));
});

test('frontend build explicitly disables Vite env-file loading', () => {
  assert.match(readFileSync(new URL('./frontend-build.mjs', import.meta.url), 'utf8'), /envDir: false/);
});

test('REST health distinguishes existing anonymous denial from bad keys or gateway errors', () => {
  validateRESTHealth(401, { code: '42501' });
  for (const [status, body] of [[401, { code: 'PGRST301' }], [403, {}], [200, []], [503, { code: '42501' }]]) assert.throws(() => validateRESTHealth(status, body));
});

test('public API health uses the anon key and rejects gateway-only Auth denial', async t => {
  const key = anon('anon');
  const paths = [];
  t.mock.method(globalThis, 'fetch', async (url, options) => {
    assert.equal(options.headers.apikey, key);
    assert.equal(options.headers.Authorization, `Bearer ${key}`);
    const path = new URL(url).pathname;
    paths.push(path);
    return new Response(path.startsWith('/rest/') ? JSON.stringify({ code: '42501' }) : '{}', {
      status: path.startsWith('/rest/') ? 401 : 200,
    });
  });
  await assert.rejects(checkPublicAPI('https://api.lpg.144.79.249.4.sslip.io'), /anon JWT/);
  assert.equal(paths.length, 0);
  await checkPublicAPI('https://api.lpg.144.79.249.4.sslip.io', key);
  assert.deepEqual(paths, ['/auth/v1/health', '/rest/v1/items', '/storage/v1/status']);
  t.mock.method(globalThis, 'fetch', async () => new Response('Unauthorized', { status: 401 }));
  await assert.rejects(checkPublicAPI('https://api.lpg.144.79.249.4.sslip.io', key), /auth\/v1\/health/);
});

test('unsafe or ambiguous command flags fail before any deployment', async () => {
  await assert.rejects(main(['all', '--approve-migrations=bad']), /Usage/);
  await assert.rejects(main(['all', '--check', '--approve-migrations=20261012000000']), /cannot be combined/);
  await assert.rejects(main(['frontend', '--approve-migrations=20261012000000']), /only to backend/);
  assert.equal(shellQuote("a'b"), "'a'\\''b'");
});
