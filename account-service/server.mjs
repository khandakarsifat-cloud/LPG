import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
export function validatePassword(password) {
  if (typeof password !== 'string' || password.length < 12 || password.length > 128 || !/[a-z]/.test(password) || !/[A-Z]/.test(password) || !/[0-9]/.test(password)) {
    throw Object.assign(new Error('Use 12–128 characters including uppercase, lowercase and a number.'), { status: 400 });
  }
}
class APIError extends Error {
  constructor(message, status = 400) { super(message); this.status = status; }
}

export function createAccountService(config, request = fetch) {
  const origins = new Set(config.origins);
  const buckets = new Map();
  async function upstream(path, token, body, method = 'POST') {
    let response;
    try {
      response = await request(config.apiURL + path, {
        method, headers: { apikey: config.publicKey, Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }), signal: AbortSignal.timeout(20_000),
      });
    } catch { throw new APIError('Account service could not reach Auth. Retry with the same request.', 503); }
    const data = await response.json().catch(() => ({}));
    if (!response.ok) {
      // Auth/SQL payloads, passwords and tokens must never be logged or reflected.
      const message = data.code === '42501' ? 'Access denied. Refresh your account and permissions.'
        : /already.*registered|already.*exists/i.test(data.msg ?? data.message ?? '') ? 'An account with this email already exists.'
        : path.includes('/rpc/') && typeof data.message === 'string' && data.message.length < 250 ? data.message
        : path.includes('/token') ? 'Current password is incorrect, or this account is unavailable.'
        : 'Account operation failed. Retry with the same request or contact the administrator.';
      throw new APIError(message, response.status === 401 || response.status === 403 ? response.status : 400);
    }
    return data;
  }
  const rpc = (name, token, body) => upstream('/rest/v1/rpc/' + name, token, body);
  return createServer({ requestTimeout: 30_000, headersTimeout: 10_000, maxHeaderSize: 16_384 }, async (req, res) => {
    const origin = req.headers.origin;
    const send = (status, body) => {
      res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
        ...(origin && origins.has(origin) ? { 'Access-Control-Allow-Origin': origin, Vary: 'Origin' } : {}) });
      res.end(JSON.stringify(body));
    };
    try {
      if (req.method === 'GET' && ['/healthz', '/accounts/v1/healthz'].includes(req.url)) { send(200, { status: 'ok' }); return; }
      if (origin && !origins.has(origin)) throw new APIError('Origin not allowed', 403);
      if (req.method === 'OPTIONS') {
        res.writeHead(204, { 'Access-Control-Allow-Origin': origin ?? '', 'Access-Control-Allow-Methods': 'POST, OPTIONS',
          'Access-Control-Allow-Headers': 'authorization, content-type', 'Access-Control-Max-Age': '600', Vary: 'Origin' }); res.end(); return;
      }
      if (req.method !== 'POST' || !['/accounts/v1/provision', '/accounts/v1/password'].includes(req.url)) throw new APIError('Not found', 404);
      if (!req.headers['content-type']?.startsWith('application/json')) throw new APIError('JSON required', 415);
      const token = /^Bearer ([A-Za-z0-9._-]+)$/.exec(req.headers.authorization ?? '')?.[1];
      if (!token || token.length > 8192) throw new APIError('Sign in required', 401);
      const chunks = []; let size = 0;
      for await (const chunk of req) { size += chunk.length; if (size > 16_384) throw new APIError('Request too large', 413); chunks.push(chunk); }
      let body; try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { throw new APIError('Invalid JSON', 400); }
      if (!body || typeof body !== 'object' || Array.isArray(body)) throw new APIError('Invalid request', 400);
      const user = await upstream('/auth/v1/user', token, undefined, 'GET');
      const context = await rpc('get_access_context', token, {});
      // Bound memory and rate limit by verified identity, never client IP headers.
      const now = Date.now();
      if (buckets.size > 2000) for (const [id, item] of buckets) if (item.until < now) buckets.delete(id);
      if (buckets.size >= 10_000 && !buckets.has(user.id)) throw new APIError('Account service is busy. Try again shortly.', 503);
      const bucket = buckets.get(user.id);
      if (bucket && bucket.until > now && bucket.count >= 20) throw new APIError('Too many account operations. Try again in a minute.', 429);
      buckets.set(user.id, bucket && bucket.until > now ? { ...bucket, count: bucket.count + 1 } : { until: now + 60_000, count: 1 });
      validatePassword(body.password);
      if (req.url === '/accounts/v1/password') {
        if (context.access_status !== 'active' || context.reset_pending) throw new APIError('This account is unavailable.', 403);
        if (typeof body.current_password !== 'string' || body.current_password.length > 128 || body.password === body.current_password) throw new APIError('Enter your current password and a different new password.');
        const verified = await upstream('/auth/v1/token?grant_type=password', config.publicKey, { email: user.email, password: body.current_password });
        if (verified.user?.id !== user.id) throw new APIError('Reauthentication failed', 403);
        // The auth.users trigger clears the first-login restriction only after a real hash
        // change, records the event and revokes every existing Auth session atomically.
        const nonce = await rpc('prepare_own_password_change', verified.access_token, {});
        // The pinned GoTrue server applies role before password in one transaction.
        // A database trigger consumes this marker while preserving role=authenticated.
        await upstream('/auth/v1/admin/users/' + user.id, config.serviceKey, { password: body.password, role: 'lpg_password:self:' + nonce }, 'PUT');
        send(200, { password_changed: true, sign_in_required: true }); return;
      }
      if (context.must_change_password || context.reset_pending || context.access_status !== 'active') throw new APIError('Change your password before managing accounts.', 403);
      if (!uuid(body.request_id) || !body.operation || typeof body.operation !== 'object' || Array.isArray(body.operation)) throw new APIError('A request ID and operation are required.');
      const prepared = await rpc('prepare_account_operation', token, { p_request_id: body.request_id, p_payload: body.operation });
      if (prepared.state === 'complete') { send(200, prepared.result); return; }
      if (!uuid(prepared.target_user_id)) throw new APIError('Invalid provisioning response', 503);
      const target = prepared.target_user_id;
      if (body.operation.kind === 'reset') {
        await upstream('/auth/v1/admin/users/' + target, config.serviceKey, { password: body.password, role: 'lpg_password:reset:' + body.request_id }, 'PUT');
      } else {
        // A stable, database-reserved Auth UUID makes retries recoverable after timeouts.
        // The endpoint never adopts an existing user by email and never resets on retry.
        let existing;
        try { existing = await upstream('/auth/v1/admin/users/' + target, config.serviceKey, undefined, 'GET'); }
        catch (error) { if (error.status !== 400) throw error; }
        if (!existing?.id) await upstream('/auth/v1/admin/users', config.serviceKey, {
          id: target, email: body.operation.email, password: body.password, email_confirm: true,
          user_metadata: { full_name: body.operation.name }, app_metadata: { lpg_provisioning_request: body.request_id },
        });
      }
      const result = await rpc('complete_account_operation', config.serviceKey, { p_request_id: body.request_id });
      send(200, result);
    } catch (error) {
      send(error.status ?? 500, { error: error instanceof APIError || error.status === 400 ? error.message : 'Account operation failed. Retry with the same request.' });
    }
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const config = process.env.ACCOUNT_API_URL ? {
    apiURL: process.env.ACCOUNT_API_URL, publicKey: process.env.ACCOUNT_PUBLIC_KEY,
    serviceKey: process.env.ACCOUNT_SERVICE_KEY, origins: process.env.ACCOUNT_ALLOWED_ORIGINS.split(','),
  } : JSON.parse(readFileSync(process.env.ACCOUNT_SERVICE_CONFIG ?? '/run/account-service.json', 'utf8'));
  createAccountService(config).listen(8081, '0.0.0.0');
}
