import { useState } from 'react';
import { Minus, Plus, X } from 'lucide-react';
import { useGroupedListPage, useGridPageSize } from '../../hooks/useListPage';
import { groupInventoryByBrand } from '../../lib/inventoryGroups';
import type { InventoryProductIdentity, LPGBrand } from '../../types/inventory';
import type { BottleInput } from '../../types/bottles';
import { Pagination } from '../ui/Pagination';

export function BottleCollectionPicker({ catalog, brands, value, onChange, outstanding, disabled }: {
  catalog: InventoryProductIdentity[]; brands: Pick<LPGBrand, 'brand_id' | 'brand_name'>[];
  value: BottleInput; onChange: (value: BottleInput) => void; outstanding: number; disabled: boolean;
}) {
  const [search, setSearch] = useState('');
  const received = value.lines.reduce((sum, line) => sum + line.quantity, 0);
  const terms = search.toLowerCase().trim().split(/\s+/).filter(Boolean);
  const groups = groupInventoryByBrand(catalog.filter(item => {
    const text = `${item.lpg_brands?.brand_name ?? 'Product unavailable'} ${item.size_kg}kg ${item.size_kg} kg ${item.mouth_size ?? ''}`.toLowerCase();
    return terms.every(term => text.includes(term));
  }), brands);
  const { grid, columns, pageSize } = useGridPageSize({ compact: true, rowHeight: 110 });
  const paging = useGroupedListPage(groups.flatMap(group => group.items), columns, pageSize, search);
  const update = (id: string, quantity: number) => {
    const other = value.lines.filter(line => line.received_item_id !== id);
    onChange({ ...value, lines: quantity === 0 ? other : [...other, { received_item_id: id, quantity, acknowledged: false }] });
  };
  return <div className="bottle-picker">
    <label className="input-group"><span className="input-label">Find bottles</span><input className="input-field" type="search" placeholder="Brand, weight or mouth size" value={search} onChange={event => setSearch(event.target.value)} /></label>
    <div className="bottle-picker-summary" role="status"><span>Collecting <strong>{received}</strong> · Remaining after <strong>{Math.max(0, outstanding - received)}</strong></span>
      <button type="button" className="btn btn-ghost" disabled={disabled || value.lines.length === 0} onClick={() => onChange({ ...value, lines: [] })}>Clear</button></div>
    {value.lines.some(line => line.quantity > 0) && <div className="bottle-selected" aria-label="Selected bottles">{value.lines.filter(line => line.quantity > 0).map(line => {
      const item = catalog.find(item => item.item_id === line.received_item_id);
      const name = item ? `${item.lpg_brands?.brand_name ?? 'Product unavailable'} ${item.size_kg}kg ${item.mouth_size ?? ''}`.trim() : 'Product';
      return <button type="button" className="bottle-selected-item" key={line.received_item_id} disabled={disabled} aria-label={`Remove ${name}`} onClick={() => update(line.received_item_id, 0)}>{line.quantity} × {name}<X size={12} /></button>;
    })}</div>}
    <div className="bottle-picker-grid adaptive-grid adaptive-grid--bottles" ref={grid}>{paging.entries.map((item, index) => {
        const quantity = value.lines.find(line => line.received_item_id === item.item_id)?.quantity ?? 0;
        const name = `${item.lpg_brands?.brand_name ?? 'Product unavailable'} ${item.size_kg}kg ${item.mouth_size ?? ''}`.trim();
        return <div key={item.item_id} className={`bottle-picker-card${quantity > 0 ? ' is-selected' : ''}${index === 0 || paging.entries[index - 1].brand_id !== item.brand_id ? ' brand-row-start' : ''}`}>
          <strong className="bottle-picker-brand">{item.lpg_brands?.brand_name ?? 'Product unavailable'}</strong>
          <div className="bottle-picker-identity"><strong>{item.size_kg}<small> kg</small></strong><span>{item.mouth_size || 'Standard mouth'}</span></div>
          <div className="bottle-stepper">
            <button type="button" className="btn btn-ghost" aria-label={`Decrease ${name}`} disabled={disabled || quantity <= 0} onClick={() => update(item.item_id, quantity - 1)}><Minus size={14} /></button>
            <input className="input-field" aria-label={`Received quantity for ${name}`} type="number" inputMode="numeric" min={0} max={2147483647} step={1} value={quantity} disabled={disabled} onChange={event => update(item.item_id, event.target.value === '' ? 0 : Number(event.target.value))} />
            <button type="button" className="btn btn-ghost" aria-label={`Increase ${name}`} disabled={disabled || quantity >= 2147483647 || (quantity === 0 && value.lines.length >= 200)} onClick={() => update(item.item_id, quantity + 1)}><Plus size={14} /></button>
          </div>
        </div>;
      })}</div>
    {paging.total === 0 && <p className="payment-hint">{catalog.length ? 'No bottles match your search.' : 'No registered bottles available.'}</p>}
    <Pagination {...paging} onChange={paging.setPage} label="products" />
  </div>;
}
