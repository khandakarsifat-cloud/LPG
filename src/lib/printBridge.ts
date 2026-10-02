import type { ReceiptData } from '../types/receipt';
import type { PrinterDiscovery, ReceiptPrinterConfig } from '../types/printing';

const BRIDGE_URL = 'http://127.0.0.1:17891';

async function bridgeRequest<T>(path: string, body?: unknown): Promise<T> {
  let response: Response;
  try {
    response = await fetch(`${BRIDGE_URL}${path}`, {
      method: body === undefined ? 'GET' : 'POST',
      headers: { 'X-LPG-Print-Client': '1', ...(body === undefined ? {} : { 'Content-Type': 'application/json' }) },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(body === undefined ? 20_000 : 60_000),
    });
  } catch (error) {
    if (error instanceof Error && (error.name === 'TimeoutError' || error.name === 'AbortError')) {
      throw new Error(body === undefined
        ? 'Printer discovery timed out. Check the local print service and refresh.'
        : 'Print result is unknown. Check the printer before explicitly reprinting the saved sale.', { cause: error });
    }
    throw new Error(`Local print service unavailable or connection lost. Start it on this Windows computer and allow browser local network access.${body === undefined ? '' : ' Check the printer before reprinting, as the request may have reached it.'}`, { cause: error });
  }
  const result = await response.json();
  if (!response.ok) throw new Error(result.message || 'Printer communication failed.');
  return result as T;
}

export const discoverPrinters = () => bridgeRequest<PrinterDiscovery>('/printers');

export const sendReceipt = (config: ReceiptPrinterConfig, receipt: ReceiptData) =>
  bridgeRequest<{ job_id: number; message: string }>('/print', {
    request_id: crypto.randomUUID(), config, receipt,
  });
