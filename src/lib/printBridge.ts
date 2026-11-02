import type { ReceiptData } from '../types/receipt.ts';
import type { PrinterDiscovery, ReceiptPrinterConfig } from '../types/printing.ts';
import { isPrinterIPAddress } from './printerIdentity.ts';

const BRIDGE_URL = 'http://127.0.0.1:17891';
export function readBridgeSettings() {
  try { return { url: localStorage.getItem('lpg:print-bridge:url') || BRIDGE_URL, token: localStorage.getItem('lpg:print-bridge:token') || '' }; }
  catch { return { url: BRIDGE_URL, token: '' }; }
}
export function saveBridgeSettings(url: string, token: string) {
  const parsed = new URL(url);
  const local = parsed.origin === BRIDGE_URL;
  if ((!local && (parsed.protocol !== 'https:' || !isPrinterIPAddress(parsed.hostname) || token.length < 32)) || parsed.username || parsed.password || parsed.pathname !== '/' || parsed.search || parsed.hash) {
    throw new Error('Use the default localhost bridge or a private HTTPS bridge address with its 32+ character pairing token.');
  }
  localStorage.setItem('lpg:print-bridge:url', parsed.origin);
  localStorage.setItem('lpg:print-bridge:token', local ? '' : token);
}

async function bridgeRequest<T>(path: string, body?: unknown): Promise<T> {
  let response: Response;
  const settings = readBridgeSettings();
  try {
    response = await fetch(`${settings.url}${path}`, {
      method: body === undefined ? 'GET' : 'POST',
      cache: 'no-store',
      headers: { 'X-LPG-Print-Client': '1', ...(settings.token ? { 'X-LPG-Print-Token': settings.token } : {}), ...(body === undefined ? {} : { 'Content-Type': 'application/json' }) },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(body === undefined ? 20_000 : 60_000),
    });
  } catch (error) {
    if (body === undefined) console.warn('[LPG print bridge] Discovery request failed:', error instanceof Error ? error.name : 'Network error');
    if (error instanceof Error && (error.name === 'TimeoutError' || error.name === 'AbortError')) {
      throw new Error(path === '/print'
        ? 'Print result is unknown. Check the printer before explicitly reprinting the saved sale.'
        : 'Printer discovery/connectivity timed out. Check the local print service and network, then refresh.', { cause: error });
    }
    throw new Error(`Local print service unavailable or connection lost. Run Restart LPG Print Bridge.exe on the shop's Windows computer, then Refresh. If it is not installed, run LPG Print Bridge Setup.exe first. Check this device's Bridge URL, HTTPS certificate and pairing token. Allow browser local network access if prompted.${path !== '/print' ? '' : ' Check the printer before reprinting, as the request may have reached it.'}`, { cause: error });
  }
  const result = await response.json().catch(error => {
    if (body === undefined) console.warn('[LPG print bridge] Invalid discovery response:', response.status);
    throw new Error(path === '/print'
      ? 'Print result is unknown because the local service returned an invalid response. Check the printer before explicitly reprinting the saved sale.'
      : 'Local print service returned an invalid response. Run Restart LPG Print Bridge.exe and Refresh.', { cause: error });
  });
  if (!response.ok) {
    if (body === undefined) console.warn('[LPG print bridge] Discovery response failed:', response.status, result.code || 'UNKNOWN');
    throw new Error(result.message || 'Printer communication failed.');
  }
  return result as T;
}

export const discoverPrinters = () => bridgeRequest<PrinterDiscovery>('/printers');
export const discoverNetworkPrinters = (subnet: string, port: number) => bridgeRequest<Pick<PrinterDiscovery, 'printers'>>('/network/discover', { subnet, port });
export const testNetworkPrinter = (ip_address: string, port: number) => bridgeRequest<{ connected: boolean; message: string }>('/network/test', { ip_address, port });

export const sendReceipt = (config: ReceiptPrinterConfig, receipt: ReceiptData) =>
  bridgeRequest<{ job_id: number; message: string }>('/print', {
    request_id: crypto.randomUUID(), config, receipt,
  });
