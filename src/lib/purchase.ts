import type { Purchase, PurchaseDraft, PurchaseLinePayload } from '../types/purchase.ts';

export const purchaseDate = (date: string | null) => date ? new Date(date).toLocaleString('en-BD', {
  timeZone: 'Asia/Dhaka', day: 'numeric', month: 'short', year: 'numeric', hour: 'numeric', minute: '2-digit',
}) : 'Pending';

export const emptyPurchaseDraft = (): PurchaseDraft => ({
  truck_id: null, transport_cost: 0, labour_cost: 0, commission: 0, notes: '', items: [],
});

export function purchaseDraft(purchase: Purchase): PurchaseDraft {
  return {
    truck_id: purchase.truck_id, transport_cost: Number(purchase.transport_cost),
    labour_cost: Number(purchase.labour_cost), commission: Number(purchase.commission), notes: purchase.notes ?? '',
    items: purchase.items.map(item => ({
      purchase_item_id: item.purchase_item_id, item_id: item.item_id, type: item.type,
      quantity: item.quantity,
      empty_dispatched: purchase.status === 'created' ? (item.type === 'refill' ? item.quantity : 0) : item.empty_dispatched,
      unit_price: Number(item.unit_price),
    })),
  };
}

export function purchaseTotals(lines: PurchaseLinePayload[], commission: number, transport: number, labour: number, purchase?: Purchase) {
  // Unpaid receipts bill actual quantities. Prepayment freezes billed quantities.
  const subtotalCents = lines.reduce((sum, line) => {
    const billed = purchase?.status !== 'created'
      ? purchase?.items.find(item => item.purchase_item_id === line.purchase_item_id)?.billed_quantity : undefined;
    return sum + (billed ?? line.quantity) * Math.round(line.unit_price * 100);
  }, 0);
  const payableCents = subtotalCents - Math.round(commission * 100);
  return {
    subtotal: subtotalCents / 100, company_payable: payableCents / 100,
    total_cost: (payableCents + Math.round(transport * 100) + Math.round(labour * 100)) / 100,
  };
}

export function purchaseAccess(purchase: Purchase, canManage = true, isOwner = false, financialLocked = purchase.payment_status !== 'unpaid') {
  const complete = purchase.status === 'received' && purchase.payment_status === 'paid';
  const editable = canManage && !complete && purchase.status !== 'cancelled';
  return {
    complete, editable, products: editable && purchase.status === 'created',
    cancel: canManage && isOwner && (purchase.status === 'created' || purchase.status === 'in_transit'),
    financials: editable && !financialLocked,
    dispatch: editable && purchase.status === 'created', receive: editable && purchase.status === 'in_transit',
    pay: editable && purchase.status !== 'created' && purchase.payment_status !== 'paid' && Number(purchase.paid_amount ?? 0) < Number(purchase.total_cost),
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
  item_id: string; empty_quantity: number; brand: string; size_kg: number; mouth_size?: string | null;
}[]): EmptyShortage[] {
  const required = new Map<string, number>();
  for (const line of lines) if (line.type === 'refill') required.set(line.item_id, (required.get(line.item_id) ?? 0) + line.quantity);
  return items.flatMap(item => {
    const quantity = required.get(item.item_id) ?? 0;
    return quantity > item.empty_quantity ? [{ item_id: item.item_id,
      product: `${item.brand} ${item.size_kg} kg ${item.mouth_size ?? ''}`.trim(),
      required: quantity, available: item.empty_quantity, missing: quantity - item.empty_quantity }] : [];
  });
}

export function validatePurchaseDraft(draft: PurchaseDraft, subtotal: number): string | null {
  const amounts = [draft.transport_cost, draft.labour_cost, draft.commission, ...draft.items.map(i => i.unit_price)];
  if (amounts.some(n => !Number.isFinite(n) || n < 0 || n > 9999999999.99)) return 'Enter valid nonnegative costs and prices.';
  if (draft.commission > subtotal) return 'Commission cannot exceed the product subtotal.';
  const keys = new Set<string>();
  for (const line of draft.items) {
    if (!line.item_id || !Number.isInteger(line.quantity) || line.quantity <= 0 || !Number.isInteger(line.empty_dispatched) || line.empty_dispatched < 0) {
      return 'Select a product and enter a positive expected quantity and whole outgoing quantities.';
    }
    if (line.type === 'package' && line.empty_dispatched !== 0) return 'New cylinders do not dispatch empties.';
    if (line.type === 'refill' && line.empty_dispatched !== line.quantity) return 'Refills exchange one empty cylinder per refill.';
    const key = `${line.item_id}:${line.type}`;
    if (keys.has(key)) return 'Each product can have one refill line and one new-cylinder line.';
    keys.add(key);
  }
  return null;
}

export type PurchaseSort = 'date_desc' | 'date_asc' | 'amount_desc' | 'amount_asc';
export interface PurchaseFilters {
  search: string; status: string; payment: string; from: string; to: string; sort: PurchaseSort;
}

// Use the dealership's calendar day, including both date-range boundaries.
const purchaseDateFormatter = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Dhaka', year: 'numeric', month: '2-digit', day: '2-digit' });
export function purchaseDay(date: string): string {
  return purchaseDateFormatter.format(new Date(date));
}

export function filterPurchases(purchases: Purchase[], filters: PurchaseFilters): Purchase[] {
  const groups = filters.search.toLowerCase().split(',').map(group => group.trim().split(/\s+/).filter(Boolean)).filter(group => group.length);
  return purchases.filter(purchase => {
    const statusMatches = filters.status === 'all' || purchase.status === filters.status
      || filters.status === 'pending_refund' && purchase.status === 'cancelled' && !purchase.financial_closed_at
      || filters.status === 'closed' && purchase.status === 'cancelled' && Boolean(purchase.financial_closed_at);
    if (!statusMatches || (filters.payment !== 'all' && purchase.payment_status !== filters.payment)) return false;
    const day = purchaseDay(purchase.created_at);
    if ((filters.from && day < filters.from) || (filters.to && day > filters.to)) return false;
    if (!groups.length) return true;
    const text = [purchase.purchase_id, purchase.company_name, purchase.plant_name, purchase.truck_name,
      purchase.notes, purchase.receipt_notes, purchase.status, purchase.payment_status,
      ...purchase.items.flatMap(item => [item.brand_name, `${item.size_kg}kg`, `${item.size_kg} kg`, item.mouth_size,
        item.type === 'refill' ? 'refill exchange' : 'package new cylinders'])].join(' ').toLowerCase();
    return groups.some(group => group.every(term => text.includes(term)));
  }).sort((a, b) => {
    const difference = filters.sort.startsWith('amount') ? Number(a.total_cost) - Number(b.total_cost)
      : new Date(a.created_at).getTime() - new Date(b.created_at).getTime();
    return (filters.sort.endsWith('desc') ? -difference : difference) || a.purchase_id.localeCompare(b.purchase_id);
  });
}
