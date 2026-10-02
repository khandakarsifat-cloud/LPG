import type { ReceiptData } from '../src/types/receipt.ts';

export interface ReceiptLine {
  text: string;
  bold?: boolean;
  center?: boolean;
  right?: string;
}

const labels = { refill: 'Refill', package: 'New Package', empty_return: 'Empty Return' };
const money = (value: number) => `Tk ${value.toLocaleString('en-BD', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
// Remove control characters, including ESC/POS commands, from all receipt content.
const clean = (text: string) => [...text].map(character => {
  const code = character.codePointAt(0) ?? 0;
  return code < 32 || code === 127 ? ' ' : character;
}).join('');

export function formatReceipt(data: ReceiptData): ReceiptLine[] {
  const lines: ReceiptLine[] = [
    { text: data.shop_name || 'Gas Dealership', bold: true, center: true },
    { text: 'Official Sales Receipt', center: true },
    { text: new Date(data.created_at).toLocaleString('en-BD', { timeZone: 'Asia/Dhaka' }), center: true },
    { text: `Receipt: #${data.sale_id.slice(0, 8).toUpperCase()}`, center: true },
    { text: '────────────────────────' },
    { text: 'CUSTOMER', bold: true },
    { text: data.customer_name },
    { text: `Ph: ${data.customer_phone} · ${data.customer_tier}` },
    { text: '────────────────────────' },
  ];
  for (const item of data.items) {
    lines.push({ text: item.name, bold: true });
    lines.push({ text: `${labels[item.type]} x${item.quantity}` });
    lines.push({ text: item.type === 'empty_return' ? 'Free' : `@ ${money(item.unit_price)}`, right: item.type === 'empty_return' ? '-' : money(item.line_total) });
  }
  lines.push({ text: '────────────────────────' }, { text: 'Subtotal', right: money(data.subtotal) });
  if (data.discount_amount > 0) lines.push({ text: 'Discount', right: `-${money(data.discount_amount)}` });
  if (data.exchange_fee > 0) lines.push({ text: 'Exchange Fee', right: money(data.exchange_fee) });
  lines.push({ text: 'TOTAL', right: money(data.total_amount), bold: true });
  const refills = data.items.filter(item => item.type === 'refill').reduce((sum, item) => sum + item.quantity, 0);
  const empties = data.items.filter(item => item.type === 'empty_return').reduce((sum, item) => sum + item.quantity, 0);
  if (refills || empties) lines.push({ text: `${refills} refills | ${empties} empties returned` });
  if (data.notes) lines.push({ text: `Note: ${data.notes}` });
  lines.push({ text: 'Thank you for your business!', center: true }, { text: 'Powered by LPG Manager', center: true });
  return lines.map(line => ({ ...line, text: clean(line.text), right: line.right && clean(line.right) }));
}
