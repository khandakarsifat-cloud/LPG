import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { backendFiles, cleanEnv, main, shellQuote, validateAnon, validateAPI, validateGraph, validateRESTHealth, services } from './deploy.mjs';

const anon = role => `${Buffer.from('{"alg":"HS256"}').toString('base64url')}.${Buffer.from(JSON.stringify({ role, exp: 4102444800 })).toString('base64url')}.signature`;

test('deployment children do not inherit development, privileged or injected build environment', () => {
  const env = cleanEnv({ PATH: 'bin', SystemRoot: 'windows', VITE_SUPABASE_URL: 'http://localhost:54321', VITE_PRIVATE: 'secret', SERVICE_ROLE_KEY: 'secret', CLOUDFLARE_API_TOKEN: 'secret', COMPOSE_FILE: 'dev.yml', NODE_OPTIONS: '--require injected.js' });
  assert.deepEqual(env, { PATH: 'bin', SystemRoot: 'windows' });
});

test('public configuration accepts only existing Azure endpoint and anon role', () => {
  assert.equal(validateAPI('https://api.lpg.20.40.48.3.sslip.io/'), 'https://api.lpg.20.40.48.3.sslip.io');
  for (const url of ['http://localhost:54321', 'https://example.com', 'https://api.lpg.20.40.48.3.sslip.io/?key=x']) assert.throws(() => validateAPI(url));
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
  model.volumes.lpg_db_data.external = false;
  assert.throws(() => validateGraph(model), /volume/);
});

test('backend bundle excludes environments, credentials, local data and restore utilities', () => {
  const files = backendFiles();
  assert(files.includes('compose.azure.yml'));
  assert(files.some(name => name.startsWith('supabase/migrations/')));
  assert(!files.some(name => /\.env|\.pem|restore|storage\/|volumes\/db\//.test(name)));
});

test('frontend build explicitly disables Vite env-file loading', () => {
  assert.match(readFileSync(new URL('./frontend-build.mjs', import.meta.url), 'utf8'), /envDir: false/);
});

test('REST health distinguishes existing anonymous denial from bad keys or gateway errors', () => {
  validateRESTHealth(401, { code: '42501' });
  for (const [status, body] of [[401, { code: 'PGRST301' }], [403, {}], [200, []], [503, { code: '42501' }]]) assert.throws(() => validateRESTHealth(status, body));
});

test('unsafe or ambiguous command flags fail before any deployment', async () => {
  await assert.rejects(main(['all', '--approve-migrations=bad']), /Usage/);
  await assert.rejects(main(['all', '--check', '--approve-migrations=20261012000000']), /cannot be combined/);
  await assert.rejects(main(['frontend', '--approve-migrations=20261012000000']), /only to backend/);
  assert.equal(shellQuote("a'b"), "'a'\\''b'");
});
