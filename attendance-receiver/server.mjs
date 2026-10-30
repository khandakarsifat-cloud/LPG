import http from 'node:http';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { isIP } from 'node:net';

const MAX_BODY = 512 * 1024;
const MAX_ROWS = 2000;
export class ProtocolError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

// ATTLOG has no unique scan ID. Keep occurrences within a packet, while a retry
// of that packet produces exactly the same keys. Never retain the upload body.
export function parseAttendance(body) {
  const lines = body.split(/\r?\n/).filter(line => line.trim());
  if (lines.length > MAX_ROWS) throw new ProtocolError(413, 'Too many records');
  const occurrences = new Map();
  return lines.map(line => {
    const parts = line.split('\t').map(part => part.trim());
    const [pin, timestamp, status = '0', verify = '0', workcode = '0', reserved = ''] = parts;
    if (!/^[\w-]{1,24}$/.test(pin) || !/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/.test(timestamp)
      || parts.length > 16 || [status, verify, workcode, reserved, ...parts.slice(6)].some(v => !/^[\w.-]{0,24}$/.test(v))) {
      // Describe structure only: never echo a PIN, timestamp or field content.
      throw new ProtocolError(400, `Invalid attendance record (columns=${parts.length}, pin=${/^[\w-]{1,24}$/.test(pin)}, time=${/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/.test(timestamp)}, fields=${[status, verify, workcode, reserved, ...parts.slice(6)].every(v => /^[\w.-]{0,24}$/.test(v))})`);
    }
    // MB20-VL firmware sends eleven columns. Optional trailing data is neither
    // stored nor used as identity, so firmware formatting changes do not replay
    // scans and unnecessary personal/device data never enters our records.
    const canonical = JSON.stringify([pin, timestamp, status || '0', verify || '0', workcode || '0']);
    const occurrence = (occurrences.get(canonical) ?? 0) + 1;
    occurrences.set(canonical, occurrence);
    return { pin, timestamp, status, verify, workcode,
      key: createHash('sha256').update(canonical + ':' + occurrence).digest('hex') };
  });
}

export function options(serial, stamp = '0', timezone = 6) {
  return `GET OPTION FROM: ${serial}\nStamp=${stamp}\nATTLOGStamp=${stamp}\nOpStamp=9999\nOPERLOGStamp=9999\nATTPHOTOStamp=9999\nErrorDelay=60\nDelay=30\nRequestDelay=30\nTransTimes=00:00;12:00\nTransInterval=1\nTransFlag=TransData AttLog\nTimeZone=${timezone}\nRealtime=1\nEncrypt=None\nServerVer=2.2.14\nSupportPing=1\n`;
}

async function readBody(req) {
  const chunks = []; let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_BODY) throw new ProtocolError(413, 'Upload too large');
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString('utf8');
}

export function createReceiver(receive, log = value => console.log(JSON.stringify(value))) {
  let active = 0;
  const server = http.createServer({ maxHeaderSize: 8192 }, async (req, res) => {
    const send = (status, body) => { res.writeHead(status, { 'Content-Type': 'text/plain; charset=utf-8', 'Content-Length': Buffer.byteLength(body), 'Cache-Control': 'no-store' }); res.end(body); };
    if (req.url === '/healthz' && req.method === 'GET') return send(200, 'OK');
    if (active >= 8) return send(503, 'BUSY');
    active++;
    let route = 'invalid', serial, source;
    const metadata = () => ({ serial: /^[A-Za-z0-9_-]{1,40}$/.test(serial ?? '') ? serial : undefined,
      source: typeof source === 'string' && isIP(source) ? source : undefined,
      tls: /^[A-Za-z0-9. ]{1,20}$/.test(req.headers['x-adms-tls'] ?? '') ? req.headers['x-adms-tls'] : undefined });
    try {
      const url = new URL(req.url, 'http://receiver');
      route = url.pathname.replace(/\.aspx$/, '').replace(/\/$/, '');
      if (!['/iclock/cdata', '/iclock/getrequest', '/iclock/devicecmd', '/iclock/ping'].includes(route)) throw new ProtocolError(404, 'Not found');
      if (!['GET', 'POST'].includes(req.method)) throw new ProtocolError(405, 'Method not allowed');
      serial = url.searchParams.get('SN');
      source = req.headers['x-adms-source'];
      if (!/^[A-Za-z0-9_-]{1,40}$/.test(serial ?? '')) throw new ProtocolError(403, 'Unregistered device');
      // Resolve an approved device/business before parsing sensitive payloads.
      // Legacy ADMS serial identification is not cryptographic authentication.
      const auth = await receive({ p_serial: serial, p_action: 'heartbeat', p_records: [], p_stamp: null });
      const table = url.searchParams.get('table');
      if (route === '/iclock/cdata' && req.method === 'POST') {
        if (table !== 'ATTLOG') {
          if (!['OPERLOG', 'ATTPHOTO', 'BIODATA', 'USER', 'FP', 'FACE', 'USERPIC', 'BIOPHOTO', 'WORKCODE', 'OPTIONS', 'ERRORLOG'].includes((table ?? '').toUpperCase())) {
            throw new ProtocolError(422, 'Unsupported upload table');
          }
          // Do not collect enrollments, names, templates, photos, or access data.
          // Discard bounded bodies without persisting or logging their contents.
          await readBody(req);
          return send(200, 'OK');
        }
        const records = parseAttendance(await readBody(req));
        const stamp = url.searchParams.get('Stamp');
        if (stamp !== null && !/^[\w:.-]{1,64}$/.test(stamp)) throw new ProtocolError(400, 'Invalid stamp');
        await receive({ p_serial: serial, p_action: 'upload', p_records: records, p_stamp: stamp });
        send(200, `OK: ${records.length}`);
        log({ route, status: 200, records: records.length, ...metadata() });
      } else {
        if (req.method === 'POST') await readBody(req);
        send(200, route === '/iclock/cdata' && url.searchParams.has('options') ? options(serial, auth.stamp ?? '0', auth.timezone ?? 6) : 'OK');
        if (route === '/iclock/cdata' && url.searchParams.has('options')) log({ route, status: 200, operation: 'options', ...metadata() });
      }
    } catch (error) {
      const status = error instanceof ProtocolError ? error.status : 503;
      if (!res.headersSent) send(status, status === 503 ? 'RETRY' : error.message);
      // No URLs, bodies, credentials, enrollment IDs, or raw database errors.
      log({ route, status, reason: error instanceof ProtocolError ? error.message : 'Backend unavailable', ...metadata() });
    } finally { active--; }
  });
  server.requestTimeout = 20_000;
  server.headersTimeout = 10_000;
  server.keepAliveTimeout = 5_000;
  server.maxConnections = 24;
  return server;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const token = readFileSync('/run/attendance-token', 'utf8').trim();
  const receive = async body => {
    const response = await fetch('http://rest:3000/rpc/attendance_receive', {
      method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(body), signal: AbortSignal.timeout(12_000),
    });
    if (!response.ok) {
      if ([401, 403].includes(response.status)) throw new ProtocolError(403, 'Unregistered device');
      if (response.status === 400) throw new ProtocolError(400, 'Invalid attendance data or device date');
      throw new Error('Database unavailable');
    }
    return response.json();
  };
  const server = createReceiver(receive);
  server.listen(8080, '0.0.0.0');
  for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => {
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(1), 20_000).unref();
  });
}
