import type { ReceiptData } from '../types/receipt.ts';
import { formatReceipt } from './receipt.ts';

const escapeHTML = (value: string) => value.replaceAll('&', '&amp;').replaceAll('<', '&lt;')
  .replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&#39;');

export function browserReceiptHTML(receipt: ReceiptData, paperWidth: 58 | 80 = 80) {
  const lines = formatReceipt(receipt, paperWidth).map(line => /^─+$/.test(line.text)
    ? '<div class="divider"></div>'
    : `<div class="line${line.bold ? ' bold' : ''}${line.center ? ' center' : ''}"><span>${escapeHTML(line.text)}</span>${line.right ? `<span class="amount">${escapeHTML(line.right)}</span>` : ''}</div>`).join('');
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; font-src 'none'">
    <title>Receipt ${escapeHTML(receipt.sale_id.slice(0, 8).toUpperCase())}</title>
    <style>
      @page { size: auto; margin: ${paperWidth === 58 ? 2 : 3}mm; }
      * { box-sizing: border-box; }
      body { margin: 0; background: white; color: black; font: ${paperWidth === 58 ? '11px/1.3' : '12px/1.4'} Arial, sans-serif; }
      main { width: 100%; max-width: ${paperWidth === 58 ? 48 : 72}mm; margin: 0 auto; }
      .line { display: flex; justify-content: space-between; gap: 2mm; break-inside: avoid; }
      .line > span { min-width: 0; overflow-wrap: anywhere; white-space: pre-wrap; }
      .bold { font-weight: bold; }
      .center { justify-content: center; text-align: center; }
      .amount { flex-shrink: 0; text-align: right; max-width: 65%; font-variant-numeric: tabular-nums; }
      .divider { border-top: 1px dashed black; margin: 2mm 0; }
    </style></head><body><main>${lines}</main></body></html>`;
}

export async function printBrowserReceipt(receipt: ReceiptData, paperWidth: 58 | 80 = 80) {
  // A same-origin frame avoids popup blockers after checkout and async sale reads.
  const frame = document.createElement('iframe');
  frame.title = 'Printable sales receipt';
  frame.setAttribute('aria-hidden', 'true');
  frame.style.cssText = 'position:fixed;left:-10000px;top:0;width:800px;height:600px;border:0;';
  let loadTimeout = 0;
  const loaded = new Promise<void>((resolve, reject) => {
    loadTimeout = window.setTimeout(() => reject(new Error('Browser receipt preparation timed out. Try printing the saved sale again.')), 15_000);
    frame.onload = () => resolve();
    frame.onerror = () => reject(new Error('Could not prepare the browser receipt.'));
  });
  frame.srcdoc = browserReceiptHTML(receipt, paperWidth);
  const timeout = window.setTimeout(() => frame.remove(), 5 * 60_000);
  const cleanup = () => { window.clearTimeout(timeout); frame.remove(); };
  document.body.append(frame);
  try {
    await loaded;
    window.clearTimeout(loadTimeout);
    const printWindow = frame.contentWindow;
    if (!printWindow) throw new Error('Browser printing is unavailable.');
    await printWindow.document.fonts.ready;
    // Keep the frame alive until print preview closes (including cancellation).
    printWindow.addEventListener('afterprint', () => window.setTimeout(cleanup, 0), { once: true });
    printWindow.focus();
    printWindow.print();
    return { message: 'Browser print dialog opened. Confirm printing in your browser.' };
  } catch (error) { window.clearTimeout(loadTimeout); cleanup(); throw error; }
}
