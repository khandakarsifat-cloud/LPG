import type { PriceType } from '../types/inventory.ts';

interface SellingPriceRow {
  item_id: string;
  customer_tier: string;
  price_type: PriceType;
  price: number;
  effective_from: string;
  effective_to?: string | null;
}

/** MRP never participates in a sale. Resolve the active tier, then retail. */
export function getSellingPrice(rows: readonly SellingPriceRow[], itemId: string, type: PriceType, tier: string, now = Date.now()) {
  const active = rows.filter(row => row.item_id === itemId && row.price_type === type
    && Date.parse(row.effective_from) <= now
    && (!row.effective_to || Date.parse(row.effective_to) > now));
  const latest = (customerTier: string) => active.filter(row => row.customer_tier === customerTier)
    .sort((a, b) => Date.parse(b.effective_from) - Date.parse(a.effective_from))[0];
  return Number((latest(tier) ?? (tier !== 'retail' ? latest('retail') : undefined))?.price ?? 0);
}
