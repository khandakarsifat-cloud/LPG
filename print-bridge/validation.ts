import type { ReceiptData } from '../src/types/receipt.ts';
import type { ReceiptPrinterConfig } from '../src/types/printing.ts';
import { PrintError } from './errors.ts';

function object(value: unknown): Record<string, unknown> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) throw new PrintError('INVALID_REQUEST', 'Invalid print request.');
  return value as Record<string, unknown>;
}
function text(value: unknown, limit = 500): string {
  if (typeof value !== 'string' || !value.length || value.length > limit) throw new PrintError('INVALID_REQUEST', 'Missing or oversized receipt/printer field.');
  return value;
}
function number(value: unknown, minimum = 0): number {
  if (typeof value !== 'number' || !Number.isFinite(value) || value < minimum || value > 1e12) throw new PrintError('INVALID_REQUEST', 'Invalid receipt amount or quantity.');
  return value;
}
const uuid = (value: unknown) => {
  const result = text(value, 36);
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(result)) throw new PrintError('INVALID_REQUEST', 'Invalid request, business or sale identifier.');
  return result;
};

export function validatePrintRequest(value: unknown): { request_id: string; config: ReceiptPrinterConfig; receipt: ReceiptData } {
  const input = object(value);
  const config = object(input.config);
  const printer = object(config.printer);
  if (printer.transport !== 'windows_usb') throw new PrintError('UNSUPPORTED_TRANSPORT', 'Only Windows USB receipt printers are supported.');
  text(printer.queue_id, 200); text(printer.host_id, 200); text(printer.queue_name); text(printer.port_name); text(printer.driver_name);
  const device = object(printer.device);
  text(device.device_id);
  if (!String(device.device_id).toUpperCase().startsWith('USBPRINT\\')) throw new PrintError('INVALID_REQUEST', 'Invalid USB printer identity.');
  for (const key of ['serial_number', 'vendor_id', 'product_id', 'manufacturer', 'model', 'port_name']) {
    if (device[key] !== null && device[key] !== undefined) text(device[key]);
  }
  const width = config.paper_width_mm;
  const dots = number(config.printable_width_dots);
  if ((width !== 58 && width !== 80) || !Number.isInteger(dots) || dots % 8 || dots < 240 || dots > (width === 58 ? 464 : 640) || typeof config.auto_cut !== 'boolean') {
    throw new PrintError('INVALID_SETTINGS', 'Invalid paper profile, printable width or cutter setting.');
  }
  uuid(config.tenant_id);
  const receipt = object(input.receipt);
  uuid(receipt.sale_id); text(receipt.created_at);
  if (!Number.isFinite(Date.parse(String(receipt.created_at)))) throw new PrintError('INVALID_REQUEST', 'Invalid receipt date.');
  if (receipt.shop_name) text(receipt.shop_name);
  text(receipt.customer_name); text(receipt.customer_tier);
  if (receipt.customer_phone !== '') text(receipt.customer_phone);
  if (receipt.notes) text(receipt.notes, 4000);
  for (const key of ['subtotal', 'discount_amount', 'exchange_fee', 'total_amount']) number(receipt[key], -1e12);
  if (!Array.isArray(receipt.items) || !receipt.items.length || receipt.items.length > 200) throw new PrintError('INVALID_REQUEST', 'Receipt must contain between 1 and 200 items.');
  for (const entry of receipt.items) {
    const item = object(entry);
    text(item.name);
    if (!['refill', 'package', 'empty_return'].includes(String(item.type))) throw new PrintError('INVALID_REQUEST', 'Invalid receipt item type.');
    const quantity = number(item.quantity, 1);
    if (!Number.isInteger(quantity)) throw new PrintError('INVALID_REQUEST', 'Receipt quantity must be an integer.');
    number(item.unit_price, -1e12); number(item.line_total, -1e12);
  }
  // Validation above narrows all fields used by formatting and transport.
  return { request_id: uuid(input.request_id), config: input.config as ReceiptPrinterConfig, receipt: input.receipt as ReceiptData };
}
