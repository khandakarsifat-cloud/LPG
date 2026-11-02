import { createServer } from 'node:net';
import { createInterface } from 'node:readline';
import { loadSettings } from './runtime.ts';
import { startPrintBridge } from './server.ts';

// The native host assigns a kill-on-close Windows job before releasing this handshake.
// A killed host cannot leave a print helper or renderer running behind its replacement.
const commands = createInterface({ input: process.stdin });
if (process.env.LPG_PRINT_MANAGED === '1') {
  const command = await new Promise<string>(resolve => {
    commands.once('line', resolve);
    commands.once('close', () => resolve(''));
  });
  if (command !== 'start') process.exit(1);
}

loadSettings();
// Covers service, portable and source executions, including different LAN bind addresses.
const singleton = createServer(socket => socket.destroy());
singleton.on('error', () => { console.error('Another print bridge is running, or its singleton port 17892 is unavailable.'); process.exit(1); });
singleton.listen(17892, '127.0.0.1', () => {
  const server = startPrintBridge();
  server.once('error', () => { singleton.close(); commands.close(); });
  let closing = false;
  const shutdown = () => {
    if (closing) return;
    closing = true;
    // Finish in-flight requests; their journal reservations already survive forced termination.
    server.close(() => { singleton.close(); commands.close(); process.exit(0); });
    server.closeIdleConnections();
    setTimeout(() => process.exit(1), 40_000).unref();
  };
  commands.on('line', command => { if (command === 'shutdown') shutdown(); });
  if (process.env.LPG_PRINT_MANAGED === '1') commands.on('close', shutdown);
  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);
});
