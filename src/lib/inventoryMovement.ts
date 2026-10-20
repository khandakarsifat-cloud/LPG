import { MOVEMENT_TYPE_LABELS, type InventoryMovement } from '../types/inventory.ts';

export type InventoryHistorySource = 'all' | 'purchase' | 'sale';
export const PURCHASE_MOVEMENT_FILTER = 'reference_type.in.(purchase_dispatch,purchase_receipt_refill,purchase_receipt_new,purchase_cancellation),movement_type.in.(purchase,refill,purchase_adjustment)';
export const SALE_MOVEMENT_FILTER = 'reference_type.eq.sale,movement_type.eq.sale';

/** Inclusive calendar days in Bangladesh, expressed as a half-open timestamp range. */
export function inventoryHistoryBounds(from: string, to: string) {
  const since = from ? new Date(`${from}T00:00:00+06:00`).toISOString() : undefined;
  const end = to ? new Date(`${to}T00:00:00+06:00`) : undefined;
  if (end) end.setUTCDate(end.getUTCDate() + 1);
  return { since, until: end?.toISOString() };
}

/** Full saved references only. A short note or coincidental UUID is not a relationship. */
export function inventoryMovementSource(movement: Pick<InventoryMovement, 'reference_type' | 'reference_id' | 'movement_type' | 'notes'>): {
  kind: Exclude<InventoryHistorySource, 'all'> | null; id: string | null;
} {
  if (movement.reference_type === 'sale' || movement.movement_type === 'sale') {
    return { kind: 'sale', id: movement.reference_type === 'sale' ? movement.reference_id : null };
  }
  if (movement.reference_type?.startsWith('purchase_')) return { kind: 'purchase', id: movement.reference_id };
  const legacy = movement.notes?.match(/^(?:Empty bottles sent for refill \(Purchase ([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\)|Received goods from Purchase ([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})|Quantity adjustment for Purchase ([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}))$/i);
  const id = legacy?.slice(1).find(Boolean) ?? null;
  if (id || ['purchase', 'refill', 'purchase_adjustment'].includes(movement.movement_type)) return { kind: 'purchase', id };
  return { kind: null, id: null };
}

/** Describe the recorded delta, including separate filled and empty effects and cancellation reversals. */
export function inventoryMovementActions(movement: Pick<InventoryMovement, 'reference_type' | 'movement_type' | 'filled_quantity_change' | 'empty_quantity_change'>,
  source: Exclude<InventoryHistorySource, 'all'> | null, counterparty: string | null): string[] {
  const actions: string[] = [];
  const filled = movement.filled_quantity_change;
  const empty = movement.empty_quantity_change;
  if (source === 'sale') {
    const name = counterparty ?? 'customer';
    if (filled < 0) actions.push(`Sold to ${name} on POS sale`);
    if (empty > 0) actions.push(`Received empty from ${name} on POS sale`);
    if (filled > 0) actions.push(`Received filled from ${name} on POS sale`);
    if (empty < 0) actions.push(`Sent empty to ${name} on POS sale`);
  } else if (source === 'purchase') {
    const name = counterparty ? `${counterparty} (plant)` : 'plant';
    if (movement.reference_type === 'purchase_cancellation') {
      if (filled < 0) actions.push(`Reversed received stock from ${name} on cancelled purchase`);
      if (empty > 0) actions.push(`Restored empty from ${name} on cancelled purchase`);
    } else if (movement.reference_type === 'purchase_receipt_new') {
      actions.push(`Received package from ${name} on purchase`);
    } else if (movement.reference_type === 'purchase_receipt_refill') {
      actions.push(`Received refill from ${name} on purchase`);
    } else {
      if (filled > 0) actions.push(`Received filled from ${name} on purchase`);
      if (filled < 0) actions.push(`Adjusted filled stock for ${name} on purchase`);
      if (empty < 0) actions.push(`Sent empty to ${name} on purchase`);
      if (empty > 0) actions.push(`Received empty from ${name} on purchase`);
    }
  }
  return actions.length ? actions : [inventoryMovementLabel(movement)];
}

export function inventoryMovementLabel(movement: Pick<InventoryMovement, 'reference_type' | 'movement_type'>): string {
  switch (movement.reference_type) {
    case 'purchase_dispatch': return 'Purchase dispatch';
    case 'purchase_receipt_refill': return 'Refills received';
    case 'purchase_receipt_new': return 'New cylinders received';
    case 'purchase_cancellation': return 'Purchase cancelled';
    default: return MOVEMENT_TYPE_LABELS[movement.movement_type] ?? movement.movement_type;
  }
}
