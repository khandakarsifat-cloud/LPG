import type { DiscoveredPrinter, PrinterSettings } from '../src/types/printing.ts';
import type { ReceiptLine } from './receipt.ts';
import { runWindows } from './windows.ts';

export interface PrintTransport {
  send(printer: DiscoveredPrinter, bytes: Uint8Array, title: string): Promise<{ job_id: number }>;
}

// Transport receives printer-ready bytes. A future TCP transport can implement this boundary.
export const windowsUSBTransport: PrintTransport = {
  send: (printer, bytes, title) => runWindows('print', {
    queue_name: printer.queue_name, bytes: Buffer.from(bytes).toString('base64'), title,
  }),
};

export async function renderEscPos(lines: ReceiptLine[], settings: PrinterSettings): Promise<Uint8Array> {
  const result = await runWindows<{ bytes: string }>('render', { lines, settings });
  return Buffer.from(result.bytes, 'base64');
}
