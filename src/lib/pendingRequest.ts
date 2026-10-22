interface PendingRequest { id: string; body: Record<string, unknown> }
const isObject = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

/** Keep an uncertain operation in this tab until its original result is recovered. */
export function readPendingRequest(key: string): PendingRequest | null {
  const raw = sessionStorage.getItem(key);
  if (!raw) return null;
  let value: unknown;
  try { value = JSON.parse(raw); }
  catch { throw new Error('The pending request could not be read. Keep this tab open and contact the owner.'); }
  if (!isObject(value) || typeof value.id !== 'string' || !isObject(value.body)) {
    throw new Error('The pending request could not be read. Keep this tab open and contact the owner.');
  }
  return { id: value.id, body: value.body };
}

export function hasPendingRequest(key: string) {
  try { return Boolean(readPendingRequest(key)); }
  catch { return true; } // Fail closed without crashing the screen or starting another write.
}

export function prepareRequest(key: string, body?: Record<string, unknown>): PendingRequest {
  const pending = readPendingRequest(key);
  if (pending) {
    if (body && JSON.stringify(body) !== JSON.stringify(pending.body)) {
      throw new Error('An earlier request is awaiting confirmation. Recover it before starting another.');
    }
    return pending;
  }
  if (!body) throw new Error('No request is awaiting confirmation.');
  const request = { id: crypto.randomUUID(), body };
  // Persist before sending: storage failure must never leave an untracked write.
  sessionStorage.setItem(key, JSON.stringify(request));
  return request;
}

export function finishRequest(key: string, id: string) {
  if (readPendingRequest(key)?.id === id) sessionStorage.removeItem(key);
}

/** Input/constraint failures permit correction. Auth, gateway and transient
 * failures can happen before an earlier commit is found, so retain its key. */
export function isDefiniteRejection(code?: string) {
  return Boolean(code && ['P0001', '23505', '23503', '23514', '23502', '22003', '22P02', '22023'].includes(code));
}
