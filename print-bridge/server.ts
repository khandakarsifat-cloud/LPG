import { createServer, type IncomingMessage, type RequestListener } from 'node:http';
import { createServer as createSecureServer } from 'node:https';
import { readFileSync } from 'node:fs';
import { timingSafeEqual } from 'node:crypto';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { PrintError } from './errors.ts';
import { PrintJobs } from './jobs.ts';
import { validatePrintRequest } from './validation.ts';
import { discoverWindowsPrinters, resolvePrinter } from './windows.ts';
import { formatReceipt } from './receipt.ts';
import { renderEscPos, windowsUSBTransport } from './transport.ts';
import { discoverNetwork, localSubnets, privateIPv4, probeNetwork, sendNetwork } from './network.ts';

const PORT = 17891;
const defaultOrigins = [
  'http://127.0.0.1:3001', 'http://localhost:3001',
  'http://127.0.0.1:5173', 'http://localhost:5173',
  'https://floral-dew-443b.khandakarsifat.workers.dev',
];

export function allowedOrigins(extra = process.env.LPG_PRINT_ORIGINS || '') {
  const values = [...defaultOrigins, ...extra.split(',').map(value => value.trim()).filter(Boolean)];
  for (const value of values) {
    const url = new URL(value);
    const local = url.protocol === 'http:' && ['localhost', '127.0.0.1'].includes(url.hostname);
    if ((!local && url.protocol !== 'https:') || url.origin !== value) {
      throw new Error('LPG_PRINT_ORIGINS must contain exact HTTP loopback origins or HTTPS origins.');
    }
  }
  return new Set(values);
}

async function readBody(request: IncomingMessage) {
  if (request.headers['content-type'] !== 'application/json') throw new PrintError('INVALID_REQUEST', 'JSON content type required.', 415);
  let size = 0;
  const chunks: Buffer[] = [];
  for await (const chunk of request) {
    size += chunk.length;
    if (size > 128 * 1024) throw new PrintError('INVALID_REQUEST', 'Print request too large.', 413);
    chunks.push(chunk);
  }
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); }
  catch { throw new PrintError('INVALID_REQUEST', 'Invalid JSON print request.'); }
}

export function createPrintServer(discover = discoverWindowsPrinters) {
  const origins = allowedOrigins();
  const jobs = new PrintJobs(join(process.env.LPG_PRINT_DATA_DIR || join(process.env.LOCALAPPDATA || homedir(), 'LPGManager', 'PrintBridge'), 'jobs'));
  const host = process.env.LPG_PRINT_HOST || '127.0.0.1';
  const lan = host !== '127.0.0.1';
  const token = process.env.LPG_PRINT_TOKEN || '';
  if (lan && (!privateIPv4(host) || token.length < 32 || !process.env.LPG_PRINT_TLS_CERT || !process.env.LPG_PRINT_TLS_KEY)) {
    throw new Error('LAN bridge access requires a private LPG_PRINT_HOST, a 32+ character LPG_PRINT_TOKEN and trusted LPG_PRINT_TLS_CERT / LPG_PRINT_TLS_KEY files.');
  }
  const handler: RequestListener = async (request, response) => {
    const started = Date.now();
    const diagnostic = process.env.LPG_PRINT_DIAGNOSTICS === '1';
    response.setHeader('Content-Type', 'application/json');
    response.setHeader('Cache-Control', 'no-store');
    const reply = (status: number, body: unknown) => { response.writeHead(status); response.end(JSON.stringify(body)); };
    try {
      // Reject DNS rebinding and browser requests from unapproved origins.
      if (request.headers.host !== `${host}:${PORT}`) throw new PrintError('FORBIDDEN', 'Configured bridge host required.', 403);
      const origin = request.headers.origin;
      if (origin && !origins.has(origin)) throw new PrintError('FORBIDDEN', `Application origin is not allowed. Add ${origin} to LPG_PRINT_ORIGINS in the bridge settings and restart the bridge.`, 403);
      if (origin) {
        response.setHeader('Access-Control-Allow-Origin', origin);
        response.setHeader('Vary', 'Origin');
        response.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
        response.setHeader('Access-Control-Allow-Headers', 'Content-Type, X-LPG-Print-Client, X-LPG-Print-Token');
        response.setHeader('Access-Control-Allow-Private-Network', 'true');
      }
      if (!['/health', '/printers', '/print', '/network/discover', '/network/test'].includes(request.url || '')) throw new PrintError('NOT_FOUND', 'Unknown print service endpoint.', 404);
      if (request.method === 'OPTIONS') { response.writeHead(204); response.end(); return; }
      // This custom header forces browser preflight even for discovery. No arbitrary RAW endpoint.
      if (request.headers['x-lpg-print-client'] !== '1') throw new PrintError('FORBIDDEN', 'Print client header required.', 403);
      if (lan) {
        const supplied = Buffer.from(String(request.headers['x-lpg-print-token'] || ''));
        const expected = Buffer.from(token);
        if (supplied.length !== expected.length || !timingSafeEqual(supplied, expected)) throw new PrintError('FORBIDDEN', 'Bridge pairing token is incorrect. Update this device’s bridge settings.', 403);
      }
      if (request.url === '/health' && request.method === 'GET') { reply(200, { version: 1, platform: process.platform }); return; }
      if (request.url === '/printers' && request.method === 'GET') {
        if (diagnostic) console.info('[LPG print bridge] GET /printers: scanning Windows.');
        const discovery = await discover();
        if (diagnostic) console.info(`[LPG print bridge] GET /printers: 200, ${discovery.printers.length} queues, ${discovery.usb_devices.length} USB devices, ${Date.now() - started}ms.`);
        reply(200, { ...discovery, network_subnets: localSubnets() }); return;
      }
      if (request.url === '/network/test' && request.method === 'POST') { reply(200, await probeNetwork(await readBody(request))); return; }
      if (request.url === '/network/discover' && request.method === 'POST') {
        const input = await readBody(request);
        reply(200, { printers: await discoverNetwork(input?.subnet, input?.port ?? 9100) }); return;
      }
      if (request.url !== '/print' || request.method !== 'POST') throw new PrintError('METHOD_NOT_ALLOWED', 'Unsupported print service method.', 405);
      const payload = validatePrintRequest(await readBody(request));
      const result = await jobs.submit(payload.request_id, payload, async () => {
        const identity = payload.config.printer;
        const printer = identity.transport === 'network_tcp' ? identity : resolvePrinter(identity, await discover());
        const bytes = await renderEscPos(formatReceipt(payload.receipt, payload.config.paper_width_mm), payload.config);
        if (printer.transport === 'network_tcp') return sendNetwork(printer, bytes);
        return windowsUSBTransport.send(printer, bytes, `LPG Receipt ${payload.receipt.sale_id.slice(0, 8)}`);
      });
      reply(200, { ...result, message: payload.config.printer.transport === 'network_tcp' ? 'Receipt bytes sent to network printer. Physical output is not confirmed.' : `Receipt sent to printer (Windows job ${result.job_id}).` });
    } catch (error) {
      const failure = error instanceof PrintError ? error : new PrintError('BRIDGE_FAILED', 'Local print service failed. Check Windows Print Spooler and restart the bridge.', 503);
      if (request.url === '/printers') console.error(`[LPG print bridge] Discovery API failed: ${failure.status} ${failure.code} (${Date.now() - started}ms). ${failure.message}`);
      reply(failure.status, { code: failure.code, message: failure.message });
    }
  };
  return lan ? createSecureServer({ cert: readFileSync(process.env.LPG_PRINT_TLS_CERT!), key: readFileSync(process.env.LPG_PRINT_TLS_KEY!) }, handler) : createServer(handler);
}

export function startPrintBridge() {
  if (process.platform !== 'win32') throw new Error('Run the print bridge on the Windows host, outside Docker.');
  const server = createPrintServer();
  server.on('error', error => {
    console.error('[LPG print bridge] Service startup/listener failed:', error.message);
    process.exitCode = 1;
  });
  server.requestTimeout = 10_000;
  server.headersTimeout = 5_000;
  const host = process.env.LPG_PRINT_HOST || '127.0.0.1';
  server.listen(PORT, host, () => process.stdout.write('LPG print bridge ready. Dashboard Refresh rescans printers.\n'));
  return server;
}
