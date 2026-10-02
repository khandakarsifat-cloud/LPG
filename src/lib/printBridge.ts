import type { ReceiptData } from '../types/receipt.ts';
import type { PrinterDiscovery, ReceiptPrinterConfig } from '../types/printing.ts';

const BRIDGE_URL = 'http://127.0.0.1:17891';

async function bridgeRequest<T>(path: string, body?: unknown): Promise<T> {
  let response: Response;
  try {
    response = await fetch(`${BRIDGE_URL}${path}`, {
      method: body === undefined ? 'GET' : 'POST',
      cache: 'no-store',
      headers: { 'X-LPG-Print-Client': '1', ...(body === undefined ? {} : { 'Content-Type': 'application/json' }) },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(body === undefined ? 20_000 : 60_000),
    });
  } catch (error) {
    if (body === undefined) console.warn('[LPG print bridge] Discovery request failed:', error instanceof Error ? error.name : 'Network error');
    if (error instanceof Error && (error.name === 'TimeoutError' || error.name === 'AbortError')) {
      throw new Error(body === undefined
        ? 'Printer discovery timed out. Check the local print service and refresh.'
        : 'Print result is unknown. Check the printer before explicitly reprinting the saved sale.', { cause: error });
    }
    throw new Error(`Local print service unavailable or connection lost. Run npm run print:bridge in the LPG folder on this Windows computer, leave it running, then Refresh. Allow browser local network access if prompted.${body === undefined ? '' : ' Check the printer before reprinting, as the request may have reached it.'}`, { cause: error });
  }
  const result = await response.json().catch(error => {
    if (body === undefined) console.warn('[LPG print bridge] Invalid discovery response:', response.status);
    throw new Error(body === undefined
      ? 'Local print service returned an invalid response. Restart npm run print:bridge and Refresh.'
      : 'Print result is unknown because the local service returned an invalid response. Check the printer before explicitly reprinting the saved sale.', { cause: error });
  });
  if (!response.ok) {
    if (body === undefined) console.warn('[LPG print bridge] Discovery response failed:', response.status, result.code || 'UNKNOWN');
    throw new Error(result.message || 'Printer communication failed.');
  }
  return result as T;
}

export const discoverPrinters = () => bridgeRequest<PrinterDiscovery>('/printers');

export const sendReceipt = (config: ReceiptPrinterConfig, receipt: ReceiptData) =>
  bridgeRequest<{ job_id: number; message: string }>('/print', {
    request_id: crypto.randomUUID(), config, receipt,
  });
