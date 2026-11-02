import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtemp, readFile, writeFile, rm, readdir } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir, networkInterfaces } from 'node:os';
import { fileURLToPath } from 'node:url';
import { createServer } from 'node:net';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import { discoverPrinters, discoverNetworkPrinters, sendReceipt, testNetworkPrinter } from '../../src/lib/printBridge.ts';

const release = fileURLToPath(new URL('../release/', import.meta.url));
const executable = join(release, 'LPG Print Bridge.exe');
const headers = { 'X-LPG-Print-Client': '1', Origin: 'http://127.0.0.1:5173' };
async function waitFor(check, message) {
  const until = Date.now() + 30000;
  do { try { const result = await check(); if (result) return result; } catch { } await delay(150); } while (Date.now() < until);
  assert.fail(message);
}
async function health() { return (await fetch('http://127.0.0.1:17891/health', { headers, signal: AbortSignal.timeout(1000) })).ok; }
function start(directory) {
  // System tools remain available; Node/npm and the repository are deliberately absent from PATH/cwd.
  return spawn(executable, ['--portable'], { cwd: tmpdir(), windowsHide: true, stdio: 'ignore', env: {
    ...process.env, PATH: `${process.env.SystemRoot}\\System32`, NODE_OPTIONS: '--this-must-be-cleared', LPG_PRINT_DATA_DIR: directory,
  } });
}
async function stop(child) {
  if (child.exitCode === null && child.signalCode === null) { const exited = once(child, 'exit'); child.kill(); await exited; }
}

test('all release executables use the Windows GUI subsystem (no console)', { skip: process.platform !== 'win32' }, async () => {
  for (const name of ['LPG Print Bridge.exe', 'LPG Print Bridge Setup.exe', 'Restart LPG Print Bridge.exe']) {
    const pe = await readFile(join(release, name));
    const header = pe.readUInt32LE(0x3c);
    assert.equal(pe.readUInt16LE(header + 24 + 68), 2, name);
  }
});

test('standalone execution, single instance, real discovery/rendering/TCP, restart history, settings and browser client', { skip: process.platform !== 'win32', timeout: 120000 }, async () => {
  await assert.rejects(health(), 'Stop any existing bridge before the isolated packaging test.');
  const directory = await mkdtemp(join(tmpdir(), 'lpg-standalone-'));
  const ip = Object.values(networkInterfaces()).flat().find(a => a && !a.internal && /^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(a.address))?.address;
  assert(ip, 'A private adapter is required for the TCP receiver fixture.');
  const received = [];
  const endpoint = createServer(socket => { socket.on('data', bytes => received.push(bytes)); socket.on('end', () => socket.end()); });
  endpoint.listen(0, ip); await once(endpoint, 'listening');
  const port = endpoint.address().port;
  await writeFile(join(directory, 'settings.json'), JSON.stringify({ LPG_PRINT_ORIGINS: 'https://standalone-test.example' }));
  let child = start(directory);
  try {
    await waitFor(health, 'Standalone bridge did not become healthy.');
    const duplicate = start(directory);
    await once(duplicate, 'exit');
    assert(await health(), 'Second instance must leave the original bridge running.');
    const discovery = await discoverPrinters();
    assert(Array.isArray(discovery.printers)); assert(Array.isArray(discovery.usb_devices));
    assert((await testNetworkPrinter(ip, port)).connected);
    const subnet = discovery.network_subnets.find(value => {
      const address = value.split('/')[0].split('.').slice(0, 3).join('.');
      return ip.startsWith(address + '.');
    });
    assert(subnet, 'The fixture adapter must be discoverable.');
    const network = await discoverNetworkPrinters(subnet, port);
    assert(network.printers.some(printer => printer.ip_address === ip && printer.port === port), 'Bounded network discovery must find the TCP receiver.');
    const config = { tenant_id: crypto.randomUUID(), paper_width_mm: 58, printable_width_dots: 384, auto_cut: false,
      printer: { transport: 'network_tcp', ip_address: ip, port, protocol: 'escpos', device: null, queue_id: `tcp:${ip}:${port}`, host_id: 'local-network', queue_name: 'Test receiver', port_name: `${ip}:${port}`, driver_name: 'ESC/POS over TCP' } };
    const receipt = { sale_id: crypto.randomUUID(), created_at: new Date().toISOString(), shop_name: 'Standalone test বাংলা', customer_name: 'Fixture only', customer_phone: '', customer_tier: 'retail',
      items: [{ name: 'Test receipt', type: 'package', quantity: 1, unit_price: 100, line_total: 100 }], subtotal: 100, discount_amount: 0, exchange_fee: 0,
      total_amount: 100, paid_amount: 0, due_amount: 100, payments: [], unattributed_paid: 0 };
    // The unmodified application's client dispatches through the packaged process.
    const result = await sendReceipt(config, receipt); assert(result.job_id > 0);
    await waitFor(() => Buffer.concat(received).length > 100, 'TCP receipt bytes missing.');
    assert.deepEqual([...Buffer.concat(received).subarray(0, 2)], [0x1b, 0x40]);
    const [journal] = await readdir(join(directory, 'jobs'));
    const request_id = journal.replace('.json', '');
    const payload = { request_id, config, receipt };
    const length = Buffer.concat(received).length;
    const submit = async value => fetch('http://127.0.0.1:17891/print', { method: 'POST', headers: { ...headers, 'Content-Type': 'application/json' }, body: JSON.stringify(value) });
    const record = await readFile(join(directory, 'jobs', journal), 'utf8');
    const sample = `$ErrorActionPreference='Stop'; $runtime=Get-CimInstance Win32_Process -Filter "ParentProcessId=${child.pid} AND Name='node.exe'"; $list=@(Get-Process -Id ${child.pid},$runtime.ProcessId); $cpu=($list|Measure-Object CPU -Sum).Sum; Start-Sleep -Seconds 2; $list=@(Get-Process -Id ${child.pid},$runtime.ProcessId); @{workingSetMiB=[Math]::Round(($list|Measure-Object WorkingSet64 -Sum).Sum/1MB,1); idleCpuSeconds=(($list|Measure-Object CPU -Sum).Sum-$cpu); windows=@($list|Where-Object MainWindowHandle -ne 0).Count}|ConvertTo-Json -Compress`;
    const measure = spawnSync(join(process.env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'), ['-NoProfile', '-NonInteractive', '-EncodedCommand', Buffer.from(sample, 'utf16le').toString('base64')], { encoding: 'utf8', windowsHide: true });
    assert.equal(measure.status, 0, measure.stderr);
    const metrics = JSON.parse(measure.stdout); assert.equal(metrics.windows, 0);
    console.log(`Measured packaged host+runtime: ${metrics.workingSetMiB} MiB working set; ${metrics.idleCpuSeconds}s CPU across 2s idle; no windows.`);
    await stop(child); // Abrupt host death must also kill its contained Node/helper processes.
    await waitFor(async () => { try { await health(); return false; } catch { return true; } }, 'Host death left an orphan listener.');
    child = start(directory); await waitFor(health, 'Manual standalone restart failed.');
    const again = await submit(payload); assert.equal(again.status, 200, await again.clone().text());
    assert.equal((await again.json()).job_id, result.job_id);
    assert.equal(Buffer.concat(received).length, length);
    assert.equal(await readFile(join(directory, 'jobs', journal), 'utf8'), record);
    const saved = JSON.parse(record);
    await writeFile(join(directory, 'jobs', journal), JSON.stringify({ fingerprint: saved.fingerprint }));
    const uncertain = await submit(payload); assert.equal(uncertain.status, 409); assert.equal((await uncertain.json()).code, 'RESULT_UNKNOWN');
    assert.equal(Buffer.concat(received).length, length, 'Interrupted jobs must never replay.');
    const permitted = await fetch('http://127.0.0.1:17891/health', { headers: { ...headers, Origin: 'https://standalone-test.example' } }); assert.equal(permitted.status, 200);
    const forbidden = await fetch('http://127.0.0.1:17891/health', { headers: { ...headers, Origin: 'https://untrusted.example' } }); assert.equal(forbidden.status, 403);
    const missingHeader = await fetch('http://127.0.0.1:17891/health'); assert.equal(missingHeader.status, 403);
    const badTarget = await submit({ ...payload, request_id: crypto.randomUUID(), config: { ...config, printer: { ...config.printer, ip_address: '8.8.8.8' } } }); assert.equal(badTarget.status, 400);
    await new Promise(resolve => endpoint.close(resolve));
    assert.equal((await testNetworkPrinter(ip, port)).connected, false);
    await stop(child);
    await writeFile(join(directory, 'settings.json'), '{bad-json');
    child = start(directory); await once(child, 'exit'); assert.notEqual(child.exitCode, 0);
    await assert.rejects(health(), 'Invalid settings must fail closed.');
    // Counts include only host + runtime. Rendering/discovery helpers are transient.
    console.log(`Packaged Windows discovery returned ${discovery.printers.length} queues; real raster receipt reached a TCP fixture without a Windows Ethernet queue. No USB jobs dispatched.`);
  } finally {
    await stop(child);
    endpoint.close();
    // This is the unique directory created above; never touch retained user bridge history.
    await rm(directory, { recursive: true, force: true });
  }
});
