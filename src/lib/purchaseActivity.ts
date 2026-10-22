import { formatBDT } from './formatBDT.ts';
import type { Purchase, PurchaseActivity } from '../types/purchase.ts';

const record = (value: unknown): Record<string, unknown> =>
  value !== null && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : {};
const amount = (value: unknown): string | null =>
  (typeof value === 'number' || typeof value === 'string' && value.trim() !== '') && Number.isFinite(Number(value))
    ? formatBDT(Number(value)) : null;

const titles: Record<string, string> = {
  created: 'Purchase created', updated: 'Purchase updated', dispatched: 'Truck dispatched',
  received: 'Shipment received', paid: 'Full payment recorded', logistics_updated: 'Operating costs updated',
  legacy_import: 'Historical purchase retained', cancelled: 'Purchase cancelled', transit_closed: 'Transit costs settled',
  transport_funded: 'Transport funding adjusted', payment_recorded: 'Purchase payment recorded',
  cancellation_confirmed: 'Owner confirmed cancellation', cancellation_initiated: 'Cancellation initiated',
  refund_recorded: 'Refund / funding reversal recorded', refund_completed: 'Refunds completed', financially_closed: 'Purchase financially closed',
};

/** Describe recorded evidence only; current purchase values are used for labels, never historical amounts. */
export function describePurchaseActivity(activity: PurchaseActivity, purchase: Purchase, previousItems?: unknown) {
  const details = activity.details ?? {};
  const before = record(details.before), after = record(details.after);
  const changes: string[] = [];
  const totals: string[] = [];
  const snapshots: string[] = [];
  const moneyFields = [
    ['commission', 'Commission'], ['transport_cost', 'Transport'], ['labour_cost', 'Labour'],
    ['subtotal', 'Product subtotal'], ['company_payable', 'Company payable'], ['total_cost', 'Total cost'],
  ];
  if (activity.action === 'updated') {
    for (const [key, label] of moneyFields) {
      if (amount(before[key]) !== null && amount(after[key]) !== null && Number(before[key]) !== Number(after[key]))
        (['subtotal', 'company_payable', 'total_cost'].includes(key) ? totals : changes).push(`${label}: ${amount(before[key])} → ${amount(after[key])}`);
    }
    if ('truck_id' in before && 'truck_id' in after && before.truck_id !== after.truck_id) {
      const truck = after.truck_id === purchase.truck_id ? purchase.truck_name : null;
      changes.push(after.truck_id ? `Truck ${before.truck_id ? 'reassigned' : 'assigned'}${truck ? `: ${truck}` : ''}` : 'Truck assignment removed');
    }
    if ('notes' in before && 'notes' in after && (before.notes ?? '') !== (after.notes ?? '')) {
      changes.push(after.notes ? `Notes ${before.notes ? 'updated' : 'added'}: ${String(after.notes)}` : 'Notes cleared');
    }
    const oldItems = Array.isArray(details.before_items) ? details.before_items : previousItems;
    const items = Array.isArray(details.items) ? details.items.map(record) : null;
    const label = (item: Record<string, unknown>) => {
      const product = purchase.items.find(line => line.item_id === item.item_id);
      return `${product ? `${product.brand_name} ${product.size_kg} kg${product.mouth_size ? ` ${product.mouth_size}` : ''}` : 'Product'} ${item.type === 'refill' ? 'refill' : 'new cylinders'}`;
    };
    if (items) {
      for (const item of items) {
        snapshots.push(`${label(item)}: ${item.quantity} × ${amount(item.unit_price) ?? 'price not recorded'}`);
        if (Array.isArray(oldItems)) {
          const old = oldItems.map(record).find(line => line.item_id === item.item_id && line.type === item.type);
          if (!old) changes.push(`Added ${label(item)}: ${item.quantity} × ${amount(item.unit_price) ?? 'price not recorded'}`);
          else {
            if (Number(old.quantity) !== Number(item.quantity)) changes.push(`${label(item)} quantity: ${old.quantity} → ${item.quantity}`);
            if (amount(old.unit_price) !== amount(item.unit_price)) changes.push(`${label(item)} price: ${amount(old.unit_price)} → ${amount(item.unit_price)}`);
            if (Number(old.empty_dispatched) !== Number(item.empty_dispatched)) changes.push(`${label(item)} empties: ${old.empty_dispatched} → ${item.empty_dispatched}`);
          }
        }
      }
      if (Array.isArray(oldItems)) for (const old of oldItems.map(record)) {
        if (!items.some(item => item.item_id === old.item_id && item.type === old.type)) changes.push(`Removed ${label(old)} (${old.quantity})`);
      }
    }
    changes.push(...totals);
    if (!changes.length) changes.push(items && !Array.isArray(oldItems)
      ? 'Purchase saved. Product quantities and prices are recorded below; earlier product values were not captured in this entry.'
      : 'Purchase saved; no recorded field changes.');
  } else {
    if (Array.isArray(details.payments)) for (const value of details.payments) {
      const payment = record(value);
      changes.push(`${String(payment.wallet_name ?? 'Wallet')} · ${String(payment.component ?? 'payment')}: ${amount(payment.amount) ?? 'Unknown amount'}${payment.reference ? ` · Ref: ${String(payment.reference)}` : ''}`);
      if (payment.payment_id) changes.push(`Payment reference: ${String(payment.payment_id)}`);
      if (Number(payment.logistics_reversal) > 0) changes.push(`Logistics funding reversed: ${amount(payment.logistics_reversal)}; truck expenses retained.`);
    }
    for (const [key, label] of [['paid_amount', 'Total paid'], ['due', 'Outstanding'], ['refunded', 'Refund / reversal'], ['refund_due', 'Refund remaining'], ['amount', 'Amount']]) {
      const value = amount(details[key]); if (value !== null) changes.push(`${label}: ${value}`);
    }
    if (details.operation_id) changes.push(`Operation: ${String(details.operation_id)}`);
    if (activity.action === 'logistics_updated') {
      for (const [key, label] of [['driver_cost', 'Driver'], ['helper_cost', 'Helper'], ['oil_cost', 'Oil'], ['others_cost', 'Others']]) {
        if (amount(before[key]) !== amount(after[key]) && amount(before[key]) !== null && amount(after[key]) !== null) changes.push(`${label}: ${amount(before[key])} → ${amount(after[key])}`);
      }
      if (Array.isArray(after.additional_costs)) for (const value of after.additional_costs) { const cost = record(value); changes.push(`${String(cost.name)}: ${amount(cost.amount)}`); }
    }
    if (activity.action === 'created') changes.push('Order opened. Stock and payment are unchanged.');
    if (activity.action === 'received' && !details.notes) changes.push('Shipment received into inventory.');
    if (activity.action === 'cancelled' && typeof details.previous_status === 'string')
      changes.push(`Cancelled from ${details.previous_status.replaceAll('_', ' ')}.`);
    for (const [key, label] of [['company_payable', 'Company payment'], ['transport_cost', 'Transport'], ['labour_cost', 'Labour'],
      ['total_cost', 'Settled total'], ['transport_fee', 'Transport fee'], ['operating_cost', 'Operating costs']]) {
      const value = amount(details[key]);
      if (value !== null) changes.push(`${label}: ${value}`);
    }
    if (typeof details.empty_cylinders === 'number') changes.push(`${details.empty_cylinders} empty cylinders dispatched`);
    if (typeof details.notes === 'string' && details.notes) changes.push(details.notes);
    if (typeof details.message === 'string' && details.message) changes.push(details.message);
  }
  return { title: titles[activity.action] ?? 'Purchase activity', changes, snapshots };
}
