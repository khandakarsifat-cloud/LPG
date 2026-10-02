import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { PrintJobs } from './jobs.ts';
import { PrintError } from './errors.ts';
import { formatReceipt } from './receipt.ts';
import { resolvePrinter } from './windows.ts';
import { validatePrintRequest } from './validation.ts';
import { allowedOrigins } from './server.ts';
import { renderEscPos } from './transport.ts';
import { completeSale } from '../src/lib/completeSale.ts';
import type { ReceiptData } from '../src/types/receipt.ts';
import type { DiscoveredPrinter, ReceiptPrinterConfig, USBDevice } from '../src/types/printing.ts';

const device: USBDevice = { device_id: 'USBPRINT\\TEST\\INSTANCE', serial_number: 'serial-1', vendor_id: '1234', product_id: '5678', manufacturer: 'Test', model: 'Thermal', present: true, port_name: 'USB001' };
const printer: DiscoveredPrinter = { queue_id: 'queue1', host_id: 'host1', queue_name: 'Test Printer', port_name: 'USB001', driver_name: 'RAW capable', transport: 'windows_usb', device, supported: true, available: true, unavailable_reason: null };
const config: ReceiptPrinterConfig = { tenant_id: '11111111-1111-4111-8111-111111111111', printer, paper_width_mm: 80, printable_width_dots: 576, auto_cut: false };
const receipt: ReceiptData = {
  sale_id: '22222222-2222-4222-8222-222222222222', created_at: '2026-10-02T04:00:00Z', shop_name: 'বাংলা দোকান',
  customer_name: 'Test Customer', customer_phone: '01700000000', customer_tier: 'retail',
  items: [
    { name: 'Brand 12kg', type: 'refill', quantity: 2, unit_price: 1200, line_total: 2400 },
    { name: 'Returned cylinder', type: 'empty_return', quantity: 2, unit_price: 0, line_total: 0 },
  ], subtotal: 2400, discount_amount: 100, exchange_fee: 50, total_amount: 2350, notes: 'Thank you\u001b@',
};
const requestId = '33333333-3333-4333-8333-333333333333';

test('receipt content preserves customer, Bengali, prices, adjustments and empty return rules', () => {
  const lines = formatReceipt(receipt);
  assert.equal(lines[0].text, receipt.shop_name);
  assert(lines.some(line => line.text === 'TOTAL' && line.right === 'Tk 2,350.00'));
  assert(lines.some(line => line.text === 'Discount' && line.right === '-Tk 100.00'));
  assert(lines.some(line => line.text === 'Exchange Fee' && line.right === 'Tk 50.00'));
  assert(lines.some(line => line.text === 'Free' && line.right === '-'));
  assert(lines.some(line => line.text === '2 refills | 2 empties returned'));
  assert(!lines.some(line => line.text.includes('\u001b')));
});

test('checkout commits once before printing; a failed print resolves with the saved sale', async () => {
  let creates = 0;
  let saved = false;
  const result = await completeSale(async () => { creates++; return { sale_id: receipt.sale_id }; }, () => { saved = true; }, async id => {
    assert(saved); assert.equal(id, receipt.sale_id);
    throw new Error('Bridge unavailable');
  });
  assert.equal(result.sale.sale_id, receipt.sale_id);
  assert(result.printError instanceof Error);
  assert(saved); assert.equal(creates, 1);
  let prints = 0;
  await assert.rejects(completeSale(async () => { throw new Error('Sale failed'); }, () => { throw new Error('Must not complete'); }, async () => { prints++; }), /Sale failed/);
  assert.equal(prints, 0);
});

test('printer resolution refuses disconnected hardware, other hosts and changed physical devices', () => {
  assert.equal(resolvePrinter(printer, { printers: [printer], usb_devices: [device] }), printer);
  assert.throws(() => resolvePrinter(printer, { printers: [printer], usb_devices: [{ ...device, present: false }] }), /disconnected/);
  assert.throws(() => resolvePrinter({ ...printer, host_id: 'other-host' }, { printers: [printer], usb_devices: [device] }), /unavailable/);
  assert.throws(() => resolvePrinter(printer, { printers: [{ ...printer, device: { ...device, device_id: 'other-device' } }], usb_devices: [device] }), /no longer matches/);
  assert.throws(() => resolvePrinter(printer, { printers: [{ ...printer, available: false }], usb_devices: [device] }), /unavailable/);
});

test('hardware identity survives a queue rename when its association is unambiguous', () => {
  const renamed = { ...printer, queue_id: 'renamed', queue_name: 'Renamed Thermal' };
  assert.equal(resolvePrinter(printer, { printers: [renamed], usb_devices: [device] }), renamed);
});

test('validation bounds receipt, paper, transport and request identifiers', () => {
  const payload = { request_id: requestId, receipt, config };
  assert.equal(validatePrintRequest(payload).receipt, receipt);
  assert.throws(() => validatePrintRequest({ ...payload, config: { ...config, paper_width_mm: 58 } }), /paper profile/);
  assert.throws(() => validatePrintRequest({ ...payload, config: { ...config, printer: { ...printer, transport: 'ethernet' } } }), /Only Windows USB/);
  assert.throws(() => validatePrintRequest({ ...payload, request_id: '../bad-path' }), /identifier/);
  assert.throws(() => validatePrintRequest({ ...payload, receipt: { ...receipt, total_amount: NaN } }), /amount/);
  assert.throws(() => allowedOrigins('http://evil.example'), /loopback origins/);
});

test('persistent request journal never sends the same job twice, including after bridge restart', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'lpg-print-test-'));
  try {
    let sent = 0;
    const send = async () => { sent++; return { job_id: 42 }; };
    const jobs = new PrintJobs(directory);
    assert.equal((await jobs.submit(requestId, receipt, send)).job_id, 42);
    assert.equal((await new PrintJobs(directory).submit(requestId, receipt, send)).job_id, 42);
    assert.equal(sent, 1);
    await assert.rejects(jobs.submit(requestId, { ...receipt, total_amount: 1 }, send), /different content/);
    const record = JSON.parse(await readFile(join(directory, `${requestId}.json`), 'utf8'));
    await writeFile(join(directory, `${requestId}.json`), JSON.stringify({ fingerprint: record.fingerprint }));
    await assert.rejects(new PrintJobs(directory).submit(requestId, receipt, send), /already started/);
    assert.equal(sent, 1);
  } finally { await rm(directory, { recursive: true, force: true }); }
});

test('printing failure is retained without replay; an explicit new reprint request is separate', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'lpg-print-test-'));
  try {
    let sends = 0;
    const fail = async () => { sends++; throw new PrintError('PRINT_FAILED', 'Paper out.', 503); };
    const jobs = new PrintJobs(directory);
    await assert.rejects(jobs.submit(requestId, receipt, fail), /Paper out/);
    await assert.rejects(new PrintJobs(directory).submit(requestId, receipt, fail), /Paper out/);
    assert.equal(sends, 1);
    const result = await jobs.submit('44444444-4444-4444-8444-444444444444', receipt, async () => ({ job_id: 43 }));
    assert.equal(result.job_id, 43);
  } finally { await rm(directory, { recursive: true, force: true }); }
});

test('real Windows renderer emits width-aware raster ESC/POS and optional cut for 80/58 mm', { skip: process.platform !== 'win32' }, async () => {
  for (const [paper, dots] of [[80, 576], [58, 384]] as const) {
    const bytes = await renderEscPos(formatReceipt(receipt), { paper_width_mm: paper, printable_width_dots: dots, auto_cut: true });
    assert.deepEqual([...bytes.slice(0, 2)], [0x1b, 0x40]);
    assert.deepEqual([...bytes.slice(8, 10)], [dots % 256, Math.floor(dots / 256)]);
    assert.deepEqual([...bytes.slice(-3)], [0x1d, 0x56, 1]);
    assert(bytes.length > 1000);
    const noCut = await renderEscPos([{ text: 'Test' }], { paper_width_mm: paper, printable_width_dots: dots, auto_cut: false });
    assert.deepEqual([...noCut.slice(-3)], [0x1b, 0x64, 4]);
  }
});
