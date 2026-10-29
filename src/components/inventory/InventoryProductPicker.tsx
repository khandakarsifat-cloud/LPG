import { useGroupedListPage, useGridPageSize } from '../../hooks/useListPage';
import { useState } from 'react';
import { PurchaseDialog } from '../purchases/PurchaseControls';
import { ProductTile } from './BalancesGrid';
import { groupInventoryByBrand } from '../../lib/inventoryGroups';
import type { InventoryProductIdentity, LPGBrand } from '../../types/inventory';
import { Pagination } from '../ui/Pagination';
import '../purchases/purchases.css';

export function InventoryProductPicker({ items, brands, selected, onApply, onClose, subtitle = 'Choose which products appear in inventory history.', showStock = true }: {
  items: InventoryProductIdentity[]; brands: Pick<LPGBrand, 'brand_id' | 'brand_name'>[]; selected: string[] | null;
  onApply: (ids: string[] | null) => void; onClose: () => void;
  subtitle?: string; showStock?: boolean;
}) {
  const [draft, setDraft] = useState(() => new Set(selected ?? items.map(item => item.item_id)));
  const [search, setSearch] = useState('');
  const groups = groupInventoryByBrand(items.filter(item => `${item.lpg_brands?.brand_name ?? 'Product unavailable'} ${item.size_kg}kg ${item.size_kg} kg ${item.mouth_size ?? ''}`.toLowerCase().includes(search.toLowerCase().trim())), brands);
  const flat = groups.flatMap(group => group.items);
  const { grid, columns, pageSize } = useGridPageSize({ compact: true });
  const paging = useGroupedListPage(flat, columns, pageSize, search);
  const count = items.filter(item => draft.has(item.item_id)).length;
  const toggle = (id: string) => setDraft(previous => {
    const next = new Set(previous);
    if (next.has(id)) next.delete(id); else next.add(id);
    return next;
  });
  return <PurchaseDialog title="Select products" subtitle={subtitle} onClose={onClose}>
    <div className="modal-body inv-picker-body">
      <label className="input-group"><span className="input-label">Find a product</span><input className="input-field" placeholder="Brand, weight or mouth size" value={search} onChange={event => setSearch(event.target.value)} /></label>
      <div className="inv-picker-toolbar"><span aria-live="polite">{count} of {items.length} selected</span>
        <div><button className="btn btn-secondary" onClick={() => setDraft(new Set(items.map(item => item.item_id)))}>Select all</button>
          <button className="btn btn-ghost" onClick={() => setDraft(new Set())}>Clear selection</button></div>
      </div>
      <div className="inv-tiles-grid adaptive-grid adaptive-grid--inventory" ref={grid}>{paging.entries.map((item, index) => <ProductTile key={item.item_id} item={item}
        startsBrand={index === 0 || paging.entries[index - 1].brand_id !== item.brand_id}
        showStock={showStock} selected={draft.has(item.item_id)} onClick={() => toggle(item.item_id)} />)}</div>
      {!items.length && <p className="product-help">No registered products yet.</p>}
      {items.length > 0 && flat.length === 0 && <p className="product-help">No products match your search.</p>}
      <Pagination {...paging} onChange={paging.setPage} label="products" />
    </div>
    <div className="modal-footer"><button className="btn btn-secondary" onClick={onClose}>Cancel</button>
      <button className="btn btn-primary" onClick={() => onApply(count === items.length ? null : items.filter(item => draft.has(item.item_id)).map(item => item.item_id))}>
        Apply {count === items.length ? 'all products' : `${count} ${count === 1 ? 'product' : 'products'}`}</button></div>
  </PurchaseDialog>;
}
