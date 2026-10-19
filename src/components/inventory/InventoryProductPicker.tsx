import { useState } from 'react';
import { PurchaseDialog } from '../purchases/PurchaseControls';
import { ProductTile } from './BalancesGrid';
import { groupInventoryByBrand } from '../../lib/inventoryGroups';
import type { ItemWithBrand, LPGBrand } from '../../types/inventory';
import '../purchases/purchases.css';

export function InventoryProductPicker({ items, brands, selected, onApply, onClose }: {
  items: ItemWithBrand[]; brands: LPGBrand[]; selected: string[] | null;
  onApply: (ids: string[] | null) => void; onClose: () => void;
}) {
  const [draft, setDraft] = useState(() => new Set(selected ?? items.map(item => item.item_id)));
  const count = items.filter(item => draft.has(item.item_id)).length;
  const toggle = (id: string) => setDraft(previous => {
    const next = new Set(previous);
    if (next.has(id)) next.delete(id); else next.add(id);
    return next;
  });
  return <PurchaseDialog title="Select products" subtitle="Choose which products appear in inventory history." onClose={onClose}>
    <div className="modal-body inv-picker-body">
      <div className="inv-picker-toolbar"><span aria-live="polite">{count} of {items.length} selected</span>
        <div><button className="btn btn-secondary" onClick={() => setDraft(new Set(items.map(item => item.item_id)))}>Select all</button>
          <button className="btn btn-ghost" onClick={() => setDraft(new Set())}>Clear selection</button></div>
      </div>
      <div className="inv-brand-groups">{groupInventoryByBrand(items, brands).map(group => <section key={group.key} aria-label={`${group.name} products`}>
        <h3 className="inv-brand-heading">{group.name}</h3>
        <div className="inv-tiles-grid">{group.items.map(item => <ProductTile key={item.item_id} item={item}
          selected={draft.has(item.item_id)} onClick={() => toggle(item.item_id)} />)}</div>
      </section>)}</div>
      {!items.length && <p className="product-help">No registered products yet.</p>}
    </div>
    <div className="modal-footer"><button className="btn btn-secondary" onClick={onClose}>Cancel</button>
      <button className="btn btn-primary" onClick={() => onApply(count === items.length ? null : items.filter(item => draft.has(item.item_id)).map(item => item.item_id))}>
        Apply {count === items.length ? 'all products' : `${count} ${count === 1 ? 'product' : 'products'}`}</button></div>
  </PurchaseDialog>;
}
