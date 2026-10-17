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
