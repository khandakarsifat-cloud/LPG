import type { PriceType } from '../types/inventory.ts';
import type { POSSalePayload } from '../hooks/usePOS.ts';

interface SellingPriceRow {
  item_id: string;
  customer_tier: string;
  price_type: PriceType;
  price: number;
  effective_from: string;
  effective_to?: string | null;
}

/** MRP never participates in a sale. Resolve the active tier, then retail. */
export function findSellingPrice(rows: readonly SellingPriceRow[], itemId: string, type: PriceType, tier: string, now = Date.now()) {
  const active = rows.filter(row => row.item_id === itemId && row.price_type === type
    && Date.parse(row.effective_from) <= now
    && (!row.effective_to || Date.parse(row.effective_to) > now));
  const latest = (customerTier: string) => active.filter(row => row.customer_tier === customerTier)
    .sort((a, b) => Date.parse(b.effective_from) - Date.parse(a.effective_from))[0];
  const row = latest(tier) ?? (tier !== 'retail' ? latest('retail') : undefined);
  return row ? Number(row.price) : null;
}

export function getSellingPrice(rows: readonly SellingPriceRow[], itemId: string, type: PriceType, tier: string, now = Date.now()) {
  return findSellingPrice(rows, itemId, type, tier, now) ?? 0;
}

/** A tier change applies to the whole draft sale, including existing quantities. */
export function repriceSaleItems(items: POSSalePayload['items'], rows: readonly SellingPriceRow[], tier: string, now = Date.now()): POSSalePayload['items'] {
  return items.map(item => ({ ...item, unit_price: item.type === 'empty_return'
    ? 0 : getSellingPrice(rows, item.item_id, item.type, tier, now) }));
}
