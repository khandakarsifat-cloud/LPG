import type { Purchase, PurchaseDraft, PurchaseLinePayload } from '../types/purchase.ts';

export const purchaseDate = (date: string | null) => date ? new Date(date).toLocaleString('en-BD', {
  timeZone: 'Asia/Dhaka', day: 'numeric', month: 'short', year: 'numeric', hour: 'numeric', minute: '2-digit',
}) : 'Pending';

export const emptyPurchaseDraft = (): PurchaseDraft => ({
  vehicle_id: null, transport_cost: 0, labour_cost: 0, rebate_amount: 0, notes: '', items: [],
});

export function purchaseDraft(purchase: Purchase): PurchaseDraft {
  return {
    vehicle_id: purchase.vehicle_id, transport_cost: Number(purchase.transport_cost),
    labour_cost: Number(purchase.labour_cost), rebate_amount: Number(purchase.rebate_amount), notes: purchase.notes ?? '',
    items: purchase.items.map(item => ({
      purchase_item_id: item.purchase_item_id, item_id: item.item_id,
      quantity: item.quantity,
      unit_price: Number(item.unit_price), bottle_quantity: item.bottle_quantity, bottle_unit_price: Number(item.bottle_unit_price),
    })),
  };
}

export function purchaseTotals(lines: PurchaseLinePayload[], transport: number, labour: number) {
  const subtotalCents = lines.reduce((sum, line) => sum + line.quantity * Math.round(line.unit_price * 100) + line.bottle_quantity * Math.round(line.bottle_unit_price * 100), 0);
  const payableCents = subtotalCents;
  return {
    subtotal: subtotalCents / 100, company_payable: payableCents / 100,
    total_cost: (payableCents + Math.round(transport * 100) + Math.round(labour * 100)) / 100,
  };
}

export function purchaseAccess(purchase: Purchase, canManage = true, canCancel = false, financialLocked = purchase.payment_status !== 'unpaid') {
  const complete = purchase.status === 'received' && purchase.payment_status === 'paid';
  const editable = canManage && !complete && purchase.status !== 'cancelled';
  return {
    complete, editable, products: editable && !financialLocked && purchase.status === 'created',
    cancel: canManage && canCancel && (purchase.status === 'created' || purchase.status === 'in_transit' || purchase.business_category === 'stove' && purchase.status === 'received'),
    financials: editable && !financialLocked && purchase.status !== 'received',
    dispatch: editable && (purchase.business_category !== 'stove' || Number(purchase.transport_cost)>0) && purchase.status === 'created', receive: editable && (purchase.status === 'in_transit' || purchase.business_category === 'stove' && purchase.status === 'created' && Number(purchase.transport_cost)===0),
    pay: editable && (purchase.status !== 'created' || purchase.business_category === 'stove') && purchase.payment_status !== 'paid' && Number(purchase.paid_amount ?? 0) < (Number(purchase.company_payable) + Number(purchase.labour_cost) - Number(purchase.rebate_amount)),
  };
}

export interface EmptyShortage {
  item_id: string; product: string; required: number; available: number; missing: number;
}

export class PurchaseStockError extends Error {
  shortages: EmptyShortage[];
  constructor(shortages: EmptyShortage[]) {
    super('Not enough empty cylinders');
    this.shortages = shortages;
  }
}

export function purchaseEmptyShortages(lines: PurchaseLinePayload[], items: {
  item_id: string; empty_quantity: number; lpg_brands: { brand_name: string } | null; size_kg: number; mouth_size?: string | null;
}[]): EmptyShortage[] {
  const required = new Map<string, number>();
  for (const line of lines) required.set(line.item_id, (required.get(line.item_id) ?? 0) + line.quantity - line.bottle_quantity);
  return items.flatMap(item => {
    const quantity = required.get(item.item_id) ?? 0;
    return quantity > item.empty_quantity ? [{ item_id: item.item_id,
      product: `${item.lpg_brands?.brand_name ?? 'Product unavailable'} ${item.size_kg} kg ${item.mouth_size ?? ''}`.trim(),
      required: quantity, available: item.empty_quantity, missing: quantity - item.empty_quantity }] : [];
  });
}

export function validatePurchaseDraft(draft: PurchaseDraft): string | null {
  const amounts = [draft.transport_cost, draft.labour_cost, draft.rebate_amount, ...draft.items.flatMap(i => [i.unit_price, i.bottle_unit_price])];
  if (amounts.some(n => !Number.isFinite(n) || n < 0 || n > 9999999999.99)) return 'Enter valid nonnegative costs and prices.';
  if (Math.round(draft.rebate_amount * 100) !== draft.rebate_amount * 100 && Math.abs(Math.round(draft.rebate_amount * 100) - draft.rebate_amount * 100) > 1e-6) return 'Enter a rebate with at most two decimals.';
  if (draft.rebate_amount > purchaseTotals(draft.items, draft.transport_cost, draft.labour_cost).subtotal) return 'Commission rebate cannot exceed the company product invoice.';
  const keys = new Set<string>();
  for (const line of draft.items) {
    if (!line.item_id || !Number.isInteger(line.quantity) || line.quantity <= 0 || !Number.isInteger(line.bottle_quantity) || line.bottle_quantity < 0 || line.bottle_quantity > line.quantity) {
      return 'Select a product. Gas quantity must be positive and Bottle quantity between zero and Gas quantity.';
    }
    if (line.bottle_quantity === 0 && line.bottle_unit_price !== 0) return 'Bottle price requires a purchased Bottle quantity.';
    const key = line.item_id;
    if (keys.has(key)) return 'Use one purchase line per product.';
    keys.add(key);
  }
  return null;
}

export type PurchaseSort = 'date_desc' | 'date_asc' | 'amount_desc' | 'amount_asc' | 'due_desc' | 'due_asc' | 'supplier_desc' | 'supplier_asc';
export interface PurchaseFilters {
  business_category?: string;
  search: string; status: string; payment: string; from: string; to: string; sort: PurchaseSort;
}
