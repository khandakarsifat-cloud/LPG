import { MOVEMENT_TYPE_LABELS, type InventoryMovement } from '../types/inventory.ts';

export function inventoryMovementLabel(movement: Pick<InventoryMovement, 'reference_type' | 'movement_type'>): string {
  switch (movement.reference_type) {
    case 'purchase_dispatch': return 'Purchase dispatch';
    case 'purchase_receipt_refill': return 'Refills received';
    case 'purchase_receipt_new': return 'New cylinders received';
    default: return MOVEMENT_TYPE_LABELS[movement.movement_type] ?? movement.movement_type;
  }
}
