import type { InventoryProductIdentity, LPGBrand } from '../types/inventory.ts';

/** Catalog identity comes from the brand relationship; order comes from Settings. */
export function groupInventoryByBrand<T extends InventoryProductIdentity>(items: readonly T[], brands: readonly Pick<LPGBrand, 'brand_id' | 'brand_name'>[]) {
  const ranks = new Map(brands.map((brand, index) => [brand.brand_id, index]));
  const names = new Map(brands.map(brand => [brand.brand_id, brand.brand_name]));
  const groups = new Map<string, { key: string; name: string; rank: number; items: T[] }>();
  for (const item of items) {
    const key = item.brand_id;
    let group = groups.get(key);
    if (!group) {
      group = { key, name: names.get(key) ?? item.lpg_brands?.brand_name ?? 'Product unavailable',
        rank: ranks.get(key) ?? Number.MAX_SAFE_INTEGER, items: [] };
      groups.set(key, group);
    }
    group.items.push(item);
  }
  return [...groups.values()].sort((a, b) => a.rank - b.rank || a.name.localeCompare(b.name) || a.key.localeCompare(b.key))
    .map(group => ({ ...group, items: group.items.sort((a, b) => a.size_kg - b.size_kg
      || (a.mouth_size ?? '').localeCompare(b.mouth_size ?? '') || a.item_id.localeCompare(b.item_id)) }));
}

/** Presentation only: never reorder the cart payload or change its quantities. */
export function orderSaleLines<T extends { item_id?: string; type: string; name?: string }>(lines: readonly T[], productOrder: readonly string[]) {
  const categories: Record<string, number> = { package: 0, refill: 1, empty_return: 2 };
  const ranks = new Map(productOrder.map((id, index) => [id, index]));
  return [...lines].sort((a, b) => (categories[a.type] ?? 3) - (categories[b.type] ?? 3)
    || (ranks.get(a.item_id ?? '') ?? Number.MAX_SAFE_INTEGER) - (ranks.get(b.item_id ?? '') ?? Number.MAX_SAFE_INTEGER)
    || (a.name ?? '').localeCompare(b.name ?? '') || (a.item_id ?? '').localeCompare(b.item_id ?? ''));
}
