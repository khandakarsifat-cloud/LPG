import type { ReceiptData } from '../types/receipt.ts';
import type { SaleTransaction } from '../types/sale.ts';
import type { SaleSettlement } from '../types/finance.ts';
import { paymentMethodLabel } from './payments.ts';

export function buildSaleReceipt(sale: SaleTransaction, settlement: SaleSettlement, shopName?: string): ReceiptData {
  return {
    sale_id: sale.sale_id, created_at: sale.created_at, shop_name: shopName,
    customer_name: sale.customers?.name || 'Unknown', customer_phone: sale.customers?.phone || '', customer_tier: sale.sale_tier,
    subtotal: Number(sale.subtotal), discount_amount: Number(sale.discount_amount), exchange_fee: Number(sale.exchange_fee), total_amount: Number(sale.total_amount), notes: sale.notes,
    paid_amount: Number(settlement.paid), due_amount: Number(settlement.due), payments: settlement.receipt_payments, payment_tracking: settlement.tracking,
    items: (sale.sale_items ?? []).map(line => {
      const type = line.type;
      if (type !== 'refill' && type !== 'package' && type !== 'empty_return') throw new Error('Unsupported receipt item type.');
      return { name: `${line.items?.lpg_brands?.brand_name || line.items?.brand || 'Unknown'} ${line.items?.size_kg ?? ''}kg`.trim(), type, quantity: Number(line.quantity), unit_price: Number(line.unit_price), line_total: Number(line.line_total) };
    }),
  };
}

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

export function formatReceipt(data: ReceiptData, paperWidth: 58 | 80 = 80): ReceiptLine[] {
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
    lines.push({ text: item.name, bold: true, right: paperWidth === 80 && item.type !== 'empty_return' ? money(item.line_total) : undefined });
    if (paperWidth === 58) {
      lines.push({ text: `${labels[item.type]} x${item.quantity}` });
      lines.push({ text: item.type === 'empty_return' ? 'Free' : `@ ${money(item.unit_price)}`, right: item.type === 'empty_return' ? '-' : money(item.line_total) });
    } else {
      lines.push({ text: `${labels[item.type]} x${item.quantity}${item.type === 'empty_return' ? '' : ` @ ${money(item.unit_price)}`}` });
      if (item.type === 'empty_return') lines.push({ text: 'Free', right: '-' });
    }
  }
  lines.push({ text: '────────────────────────' }, { text: 'Subtotal', right: money(data.subtotal) });
  if (data.discount_amount > 0) lines.push({ text: 'Discount', right: `-${money(data.discount_amount)}` });
  if (data.exchange_fee > 0) lines.push({ text: 'Exchange Fee', right: money(data.exchange_fee) });
  lines.push({ text: 'TOTAL', right: money(data.total_amount), bold: true });
  if (data.payments) {
    for (const payment of data.payments) {
      const method = paymentMethodLabel[payment.method] ?? payment.method;
      const label = payment.wallet_name.toLowerCase().includes(method.toLowerCase()) ? payment.wallet_name : `${method} · ${payment.wallet_name}`;
      lines.push({ text: `${label}${payment.phase === 'collection' ? ' (collected later)' : ''}`, right: money(payment.amount) });
    }
  }
  const paid = data.paid_amount ?? data.total_amount;
  const due = data.due_amount ?? Math.max(0, data.total_amount - paid);
  lines.push({ text: 'Total paid', right: money(paid), bold: true });
  lines.push({ text: 'Remaining due', right: money(due), bold: due > 0 });
  lines.push({ text: due > 0 ? (paid > 0 ? 'PARTIALLY PAID' : 'UNPAID') : 'PAID IN FULL', bold: true, center: true });
  if (data.payment_tracking === false) lines.push({ text: 'Historical payment methods not recorded', center: true });
  const refills = data.items.filter(item => item.type === 'refill').reduce((sum, item) => sum + item.quantity, 0);
  const empties = data.items.filter(item => item.type === 'empty_return').reduce((sum, item) => sum + item.quantity, 0);
  if (refills || empties) lines.push({ text: `${refills} refills | ${empties} empties returned` });
  if (data.notes) lines.push({ text: `Note: ${data.notes}` });
  lines.push({ text: 'Thank you for your business!', center: true }, { text: 'Powered by LPG Manager', center: true });
  return lines.map(line => ({ ...line, text: clean(line.text), right: line.right && clean(line.right) }));
}

