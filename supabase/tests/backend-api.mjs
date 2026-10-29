// Read-only public backend acceptance, including a disposable Realtime channel.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { randomUUID } from 'node:crypto';
import { createClient } from '@supabase/supabase-js';
import { config, checkPublicAPI, workerURL } from '../../deploy/deploy.mjs';

assert(process.argv.includes('--vps'), 'Explicit --vps target required');
const frontend = config('frontend');
const url = frontend.VITE_SUPABASE_URL;
const key = frontend.VITE_SUPABASE_ANON_KEY;
const secret = { ...parseEnv(readFileSync('.env.live-test', 'utf8')), ...process.env };
const client = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });

try {
  await checkPublicAPI(url, key);
  for (const path of ['/mcp', '/api/mcp', '/pg/query', '/functions/v1/test']) {
    assert.equal((await fetch(url + path)).status, 404, path);
  }
  for (const origin of [workerURL, url]) {
    const response = await fetch(url + '/auth/v1/token?grant_type=password', {
      method: 'OPTIONS', headers: { Origin: origin, 'Access-Control-Request-Method': 'POST',
        'Access-Control-Request-Headers': 'apikey,authorization,content-type' },
    });
    assert(response.ok);
    assert.equal(response.headers.get('access-control-allow-origin'), origin);
  }
  for (const origin of ['https://untrusted.example', 'null']) {
    assert.equal((await fetch(url + '/auth/v1/health', { headers: { Origin: origin, apikey: key } })).status, 403);
  }
  assert.equal((await fetch(url + '/auth/v1/health', { headers: { apikey: 'invalid-key' } })).status, 401);
  const jwks = await (await fetch(url + '/auth/v1/.well-known/jwks.json', { headers: { apikey: key } })).json();
  assert(jwks.keys.length && jwks.keys.every(jwk => jwk.kty === 'EC' && !jwk.d && !jwk.k));

  const auth = await client.auth.signInWithPassword({ email: secret.LPG_TEST_EMAIL, password: secret.LPG_TEST_PASSWORD });
  assert.ifError(auth.error);
  assert.equal(JSON.parse(Buffer.from(auth.data.session.access_token.split('.')[0], 'base64url')).alg, 'ES256');
  const membership = await client.from('user_profiles').select('tenant_id,is_active').eq('user_id', auth.data.user.id).single();
  assert.ifError(membership.error);
  assert(membership.data.is_active && membership.data.tenant_id);

  const channel = client.channel('migration-gateway-' + randomUUID(), { config: { broadcast: { self: true } } });
  let receive;
  const received = new Promise(resolve => { receive = resolve; });
  channel.on('broadcast', { event: 'probe' }, message => receive(message.payload));
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Realtime subscription timeout')), 20000);
    channel.subscribe(status => {
      if (status === 'SUBSCRIBED') { clearTimeout(timer); resolve(); }
      else if (['CHANNEL_ERROR', 'TIMED_OUT'].includes(status)) { clearTimeout(timer); reject(new Error('Realtime ' + status)); }
    });
  });
  await channel.send({ type: 'broadcast', event: 'probe', payload: { ok: true } });
  let timer;
  try {
    assert.deepEqual(await Promise.race([received, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error('Broadcast timeout')), 10000);
    })]), { ok: true });
  } finally { clearTimeout(timer); }
  await client.removeChannel(channel);
  console.log('PASS: HTTPS health, allowed/hostile origins, private-route and invalid-key denial, public-only JWKS, ES256 Auth/trusted membership and Realtime WebSocket round trip.');
} catch (error) {
  console.error(String(error.message).replaceAll(secret.LPG_TEST_PASSWORD, '[redacted]')
    .replace(/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g, '[redacted JWT]'));
  process.exitCode = 1;
} finally {
  await client.removeAllChannels();
  await client.auth.signOut({ scope: 'local' });
}
