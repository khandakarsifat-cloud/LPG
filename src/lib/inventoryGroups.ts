import type { ItemWithBrand, LPGBrand } from '../types/inventory.ts';

/** Catalog order comes from Settings; distinct legacy/unassigned products stay visible. */
export function groupInventoryByBrand(items: readonly ItemWithBrand[], brands: readonly LPGBrand[]) {
  const ranks = new Map(brands.map((brand, index) => [brand.brand_id, index]));
  const names = new Map(brands.map(brand => [brand.brand_id, brand.brand_name]));
  const groups = new Map<string, { key: string; name: string; rank: number; items: ItemWithBrand[] }>();
  for (const item of items) {
    const key = item.brand_id ?? `legacy:${item.brand}`;
    let group = groups.get(key);
    if (!group) {
      group = { key, name: names.get(key) ?? item.lpg_brands?.brand_name ?? item.brand,
        rank: ranks.get(key) ?? Number.MAX_SAFE_INTEGER, items: [] };
      groups.set(key, group);
    }
    group.items.push(item);
  }
  return [...groups.values()].sort((a, b) => a.rank - b.rank || a.name.localeCompare(b.name) || a.key.localeCompare(b.key))
    .map(group => ({ ...group, items: group.items.sort((a, b) => a.size_kg - b.size_kg
      || (a.mouth_size ?? '').localeCompare(b.mouth_size ?? '') || a.item_id.localeCompare(b.item_id)) }));
}
