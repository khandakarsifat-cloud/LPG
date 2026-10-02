import test from 'node:test';
import assert from 'node:assert/strict';
import { request } from 'node:http';
import type { AddressInfo } from 'node:net';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { createPrintServer } from './server.ts';
import { PrintError } from './errors.ts';
import { discoverPrinters } from '../src/lib/printBridge.ts';
import type { PrinterDiscovery } from '../src/types/printing.ts';

test('discovery API rescans on every request and recovers after enumeration failure', async () => {
  let scans = 0;
  const server = createPrintServer(async () => {
    scans++;
    if (scans === 2) throw new PrintError('WINDOWS_FAILED', 'Windows printer enumeration failed.', 503);
    return { printers: [], usb_devices: [], warnings: [`Scan ${scans}`] };
  });
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  const port = (server.address() as AddressInfo).port;
  const get = () => new Promise<{ status: number; cache: string | undefined; body: string }>((resolve, reject) => {
    const req = request({ hostname: '127.0.0.1', port, path: '/printers', headers: {
      Host: '127.0.0.1:17891', Origin: 'http://127.0.0.1:3001', 'X-LPG-Print-Client': '1',
    } }, response => {
      let body = '';
      response.setEncoding('utf8');
      response.on('data', chunk => { body += chunk; });
      response.on('end', () => resolve({ status: response.statusCode!, cache: response.headers['cache-control'], body }));
    });
    req.on('error', reject); req.end();
  });
  try {
    const first = await get();
    assert.equal(first.status, 200);
    assert.equal(first.cache, 'no-store');
    assert.deepEqual(JSON.parse(first.body).printers, []);
    assert.deepEqual(JSON.parse(first.body).warnings, ['Scan 1']);
    const failure = await get();
    assert.equal(failure.status, 503);
    assert.equal(JSON.parse(failure.body).code, 'WINDOWS_FAILED');
    const recovered = await get();
    assert.equal(recovered.status, 200);
    assert.deepEqual(JSON.parse(recovered.body).warnings, ['Scan 3']);
    assert.equal(scans, 3);
  } finally { await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve())); }
});

test('frontend Refresh makes uncached discovery requests independently of saved configuration', async t => {
  let scans = 0;
  t.mock.method(globalThis, 'fetch', async (url: string, options: RequestInit) => {
    assert.equal(url, 'http://127.0.0.1:17891/printers');
    assert.equal(options.method, 'GET');
    assert.equal(options.cache, 'no-store');
    assert.equal(options.body, undefined);
    assert.equal(new Headers(options.headers).get('X-LPG-Print-Client'), '1');
    scans++;
    return Response.json({ printers: [], usb_devices: [], warnings: [`Scan ${scans}`] });
  });
  assert.deepEqual((await discoverPrinters()).warnings, ['Scan 1']);
  assert.deepEqual((await discoverPrinters()).warnings, ['Scan 2']);
});

test('frontend reports stopped bridge and Windows enumeration failure without returning an empty success', async t => {
  t.mock.method(console, 'warn', () => {});
  const fetchMock = t.mock.method(globalThis, 'fetch', async () => { throw new TypeError('Failed to fetch'); });
  await assert.rejects(discoverPrinters(), /Run npm run print:bridge.*then Refresh/);
  fetchMock.mock.mockImplementation(async () => Response.json({ code: 'WINDOWS_FAILED', message: 'Windows printer enumeration failed.' }, { status: 503 }));
  await assert.rejects(discoverPrinters(), /Windows printer enumeration failed/);
  fetchMock.mock.mockImplementation(async () => new Response('not JSON'));
  await assert.rejects(discoverPrinters(), /invalid response/);
  fetchMock.mock.mockImplementation(async () => Response.json({ printers: [], usb_devices: [] }));
  assert.deepEqual(await discoverPrinters(), { printers: [], usb_devices: [] });
});

test('Windows queue discovery survives failed USB metadata, supports custom USB monitors, and distinguishes no queues from failure', { skip: process.platform !== 'win32' }, () => {
  const helper = fileURLToPath(new URL('./windows.ps1', import.meta.url)).replaceAll("'", "''");
  const scan = (queues: string, usb: string) => spawnSync('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', `
    function Get-Printer { [CmdletBinding()] param() ${queues} }
    function Get-PrinterPort { [CmdletBinding()] param() [pscustomobject]@{ Name='Vendor PORT:'; PortMonitor='USB Printer Monitor'; Description='Custom port' } }
    function Get-PnpDevice { [CmdletBinding()] param([switch]$PresentOnly) ${usb} }
    function Get-ItemProperty { [CmdletBinding()] param([string]$LiteralPath) @{ MachineGuid='fixture-host' } }
    & '${helper}' -Action discover
  `], { input: '{}', encoding: 'utf8', timeout: 10_000, windowsHide: true });
  const installed = "[pscustomobject]@{ Name='Any Vendor Thermal'; PortName='Vendor PORT:'; DriverName='Generic RAW'; PrinterStatus=0 }";
  const degraded = scan(installed, "throw 'Fixture USB enumeration failure'");
  assert.equal(degraded.status, 0, degraded.stderr);
  const discovery: PrinterDiscovery = JSON.parse(degraded.stdout);
  assert.equal(discovery.printers.length, 1);
  assert.equal(discovery.printers[0].queue_name, 'Any Vendor Thermal');
  assert.equal(discovery.printers[0].supported, true);
  assert.deepEqual(discovery.usb_devices, []);
  assert.equal(discovery.warnings?.length, 1);
  assert.match(degraded.stderr, /USB device enumeration failed/);
  const empty = scan('@()', '@()');
  assert.equal(empty.status, 0, empty.stderr);
  assert.deepEqual(JSON.parse(empty.stdout).printers, []);
  const failed = scan("throw 'Fixture spooler failure'", '@()');
  assert.equal(failed.status, 1);
  assert.match(JSON.parse(failed.stdout).error, /Windows printer enumeration \(Get-Printer\) failed/);
});
