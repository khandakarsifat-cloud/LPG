import type { ReceiptData } from '../types/receipt.ts';
import type { SaleTransaction } from '../types/sale.ts';
import type { SaleSettlement } from '../types/finance.ts';
import { paymentMethodLabel } from './payments.ts';
import type { SaleBottles } from '../types/bottles.ts';
import type { LPGBrand } from '../types/inventory.ts';
import { groupInventoryByBrand, orderSaleLines } from './inventoryGroups.ts';

export function buildSaleReceipt(sale: SaleTransaction, settlement: SaleSettlement, shopName?: string, bottles?: SaleBottles, brands: Pick<LPGBrand, 'brand_id' | 'brand_name'>[] = []): ReceiptData {
  const products = (sale.sale_items ?? []).map(line => ({ item_id: line.item_id ?? line.items?.item_id ?? '', brand_id: line.items?.brand_id ?? '',
    size_kg: Number(line.items?.size_kg ?? 0), mouth_size: line.items?.mouth_size ?? null,
    lpg_brands: line.items?.lpg_brands ? { brand_id: line.items.brand_id ?? '', brand_name: line.items.lpg_brands.brand_name } : null }));
  const productOrder = [...new Set(groupInventoryByBrand(products, brands).flatMap(group => group.items.map(item => item.item_id)))];
  return {
    sale_id: sale.sale_id, created_at: sale.created_at, shop_name: shopName,
    customer_name: sale.customers?.name || 'Unknown', customer_phone: sale.customers?.phone || '', customer_tier: sale.sale_tier,
    subtotal: Number(sale.subtotal), discount_amount: Number(sale.discount_amount), exchange_fee: Number(sale.exchange_fee), total_amount: Number(sale.total_amount), notes: sale.notes,
    paid_amount: Number(settlement.paid), due_amount: Number(settlement.due), payments: settlement.receipt_payments, unattributed_paid: settlement.unattributed_paid,
    additional_charges: Number(settlement.additional_charges ?? 0), bottles,
    items: orderSaleLines((sale.sale_items ?? []).map(line => {
      const type = line.type;
      if (type !== 'refill' && type !== 'package' && type !== 'empty_return') throw new Error('Unsupported receipt item type.');
      return { item_id: line.item_id ?? line.items?.item_id, name: `${line.items?.lpg_brands?.brand_name ?? 'Unknown'} ${Number(line.items?.size_kg ?? 0)}kg${line.items?.mouth_size ? ` ${line.items.mouth_size}` : ''}`.trim(), type, quantity: Number(line.quantity), unit_price: Number(line.unit_price), line_total: Number(line.line_total) };
    }), productOrder),
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
  const actual = new Map<string, { name: string; quantity: number }>();
  for (const line of data.bottles?.actual ?? []) {
    if (!line.item_id) continue;
    const previous = actual.get(line.item_id);
    actual.set(line.item_id, { name: line.name, quantity: (previous?.quantity ?? 0) + Number(line.quantity) });
  }
  const shown = new Set<string>();
  for (const item of data.items) {
    if (item.type === 'empty_return') {
      if (item.item_id && shown.has(item.item_id)) continue;
      if (item.item_id) shown.add(item.item_id);
      // Original sale rows define expectations; every physical receipt counts once.
      const expected = item.item_id ? data.items.filter(line => line.type === 'empty_return' && line.item_id === item.item_id).reduce((sum, line) => sum + Number(line.quantity), 0) : item.quantity;
      const received = item.item_id ? actual.get(item.item_id)?.quantity ?? 0 : 0;
      lines.push({ text: item.name, bold: true }, { text: `Expected ${expected} | Received ${received}` });
      continue;
    }
    lines.push({ text: item.name, bold: true, right: paperWidth === 80 ? money(item.line_total) : undefined });
    if (paperWidth === 58) {
      lines.push({ text: `${labels[item.type]} x${item.quantity}` });
      lines.push({ text: `@ ${money(item.unit_price)}`, right: money(item.line_total) });
    } else {
      lines.push({ text: `${labels[item.type]} x${item.quantity} @ ${money(item.unit_price)}` });
    }
  }
  if (data.bottles) {
    for (const [id, product] of actual) {
      if (!shown.has(id)) lines.push({ text: product.name, bold: true }, { text: `Expected 0 | Received ${product.quantity}` });
    }
    if (data.bottles.expected > 0) lines.push({ text: data.bottles.outstanding === 0 ? 'Bottle Settled' : `Bottles outstanding: ${data.bottles.outstanding}`, bold: true });
  }
  lines.push({ text: '────────────────────────' }, { text: 'Subtotal', right: money(data.subtotal) });
  if (data.discount_amount > 0) lines.push({ text: 'Discount', right: `-${money(data.discount_amount)}` });
  if (data.exchange_fee > 0) lines.push({ text: 'Exchange Cost', right: money(data.exchange_fee) });
  if (data.additional_charges) lines.push({ text: 'Original invoice total', right: money(data.total_amount) }, { text: 'Additional Settlement Cost', right: money(data.additional_charges) });
  lines.push({ text: 'TOTAL', right: money(data.total_amount + (data.additional_charges ?? 0)), bold: true });
  if (data.payments) {
    for (const payment of data.payments) {
      const method = paymentMethodLabel[payment.method] ?? payment.method;
      const label = payment.wallet_name.toLowerCase().includes(method.toLowerCase()) ? payment.wallet_name : `${method} · ${payment.wallet_name}`;
      lines.push({ text: `${label}${payment.phase === 'collection' ? ' (collected later)' : ''}`, right: money(payment.amount) });
    }
  }
  const paid = data.paid_amount;
  const due = data.due_amount;
  lines.push({ text: 'Total paid', right: money(paid), bold: true });
  lines.push({ text: 'Remaining due', right: money(due), bold: due > 0 });
  lines.push({ text: due > 0 ? (paid > 0 ? 'PARTIALLY PAID' : 'UNPAID') : 'PAID IN FULL', bold: true, center: true });
  if (data.unattributed_paid) lines.push({ text: 'Paid without recorded payment methods', right: money(data.unattributed_paid) });
  if (data.notes) lines.push({ text: `Note: ${data.notes}` });
  lines.push({ text: 'Thank you for your business!', center: true }, { text: 'Powered by LPG Manager', center: true });
  return lines.map(line => ({ ...line, text: clean(line.text), right: line.right && clean(line.right) }));
}

