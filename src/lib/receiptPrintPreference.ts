import type { ReceiptPrintMethod } from '../types/printing.ts';

const key = (tenantId: string) => `lpg:receipt-print-method:v1:${tenantId}`;

export function readReceiptPrintMethod(tenantId: string): ReceiptPrintMethod {
  try { return localStorage.getItem(key(tenantId)) === 'browser' ? 'browser' : 'windows_usb'; }
  catch { return 'windows_usb'; }
}

export function writeReceiptPrintMethod(tenantId: string, method: ReceiptPrintMethod) {
  // Throw if storage is unavailable so the UI never claims an unsaved preference.
  localStorage.setItem(key(tenantId), method);
}

export function readBrowserPaperWidth(tenantId: string): 58 | 80 {
  try { return localStorage.getItem(`lpg:browser-paper:${tenantId}`) === '58' ? 58 : 80; }
  catch { return 80; }
}
export function writeBrowserPaperWidth(tenantId: string, width: 58 | 80) {
  localStorage.setItem(`lpg:browser-paper:${tenantId}`, String(width));
}
