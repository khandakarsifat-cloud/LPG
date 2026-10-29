import { Minus, Plus } from 'lucide-react';
import type { BottleInput, BottleObligation, BottleProduct } from '../../types/bottles';
import { validateBottles } from '../../lib/bottles';
import type { InventoryProductIdentity, LPGBrand } from '../../types/inventory';
import { BottleCollectionPicker } from './BottleCollectionPicker';
import './bottles.css';

export function ReceivedBottles({ obligations, products, value, onChange, disabled = false, collection = false, previouslyReceived = 0, catalog = [], brands = [] }: {
 obligations: BottleObligation[]; products: BottleProduct[]; value: BottleInput; onChange: (value: BottleInput) => void; disabled?: boolean; collection?: boolean; previouslyReceived?: number;
 catalog?: InventoryProductIdentity[]; brands?: Pick<LPGBrand, 'brand_id' | 'brand_name'>[];
}) {
 const lines = value.lines; const expected = obligations.reduce((sum,o) => sum + o.expected, 0);
 const received = lines.reduce((sum,l) => sum + l.quantity, 0); const outstanding = Math.max(0, expected - previouslyReceived);
 const validation = validateBottles(obligations, products, lines.filter(l => l.quantity !== 0), collection, previouslyReceived);
 const update = (index: number, patch: Partial<BottleInput['lines'][number]>) => onChange({ ...value, lines: lines.map((l,i) => i === index ? { ...l, ...patch, acknowledged: patch.acknowledged ?? false } : l) });
 const differs = obligations.some(o => (lines.find(l => l.received_item_id === o.item_id)?.quantity ?? 0) !== o.expected);
 return <section className="bottle-editor" aria-label="Received bottles">
  <div className="bottle-summary"><span>Expected <strong>{expected}</strong></span><span>{collection ? 'Previously received' : 'Received'} <strong>{collection ? previouslyReceived : received}</strong></span><span>Outstanding <strong>{collection ? outstanding : Math.max(0, outstanding - received)}</strong></span></div>
  {collection ? <BottleCollectionPicker catalog={catalog} brands={brands} value={value} onChange={onChange} disabled={disabled} outstanding={outstanding} /> : <div className="bottle-column-labels"><span>Product</span><span>Expected</span><span>Received</span></div>}
  {lines.map((line,index) => {
   const obligation = obligations.find(o => o.item_id === line.received_item_id);
   const actual = products.find(p => p.item_id === line.received_item_id);
   const acknowledge = line.quantity > 0 && (!obligation || obligation.received + line.quantity > obligation.expected);
   if (collection && !acknowledge) return null;
   return <div className={collection ? 'bottle-collection-ack' : 'bottle-product-row'} key={line.received_item_id || index}>
    {!collection && <><strong>{actual?.name ?? obligation?.name}</strong>
    <span className="bottle-number">{obligation?.expected ?? 0}</span>
    <div className="bottle-stepper"><button type="button" className="btn btn-ghost" aria-label={`Decrease ${actual?.name ?? 'received quantity'}`} disabled={disabled || line.quantity <= 0} onClick={() => update(index,{quantity:line.quantity-1})}><Minus size={14} /></button><input aria-label={`Received quantity ${index+1}`} className="input-field" type="number" inputMode="numeric" min={0} max={2147483647} step={1} value={line.quantity} disabled={disabled} onChange={e => update(index,{ quantity: e.target.value === '' ? 0 : Number(e.target.value) })} /><button type="button" className="btn btn-ghost" aria-label={`Increase ${actual?.name ?? 'received quantity'}`} disabled={disabled || line.quantity >= 2147483647} onClick={() => update(index,{quantity:line.quantity+1})}><Plus size={14} /></button></div>
    </>}
    {acknowledge && <label className="bottle-acknowledge"><input type="checkbox" checked={Boolean(line.acknowledged)} disabled={disabled} onChange={e => update(index,{ acknowledged: e.target.checked })} />{obligation ? `I accept ${actual?.name}: total received exceeds the original ${obligation.expected} expected.` : `I accept ${actual?.name}, which was not originally expected.`}</label>}
   </div>;
  })}
  {!collection && catalog.length > 0 && <details><summary>Other received products</summary><BottleCollectionPicker catalog={catalog.filter(item => !obligations.some(o => o.item_id === item.item_id))} brands={brands} value={value} onChange={onChange} disabled={disabled} outstanding={outstanding} /></details>}
  {(collection || differs) && <label className="input-group"><span className="input-label">Bottle note (optional)</span><textarea className="input-field" maxLength={1000} value={value.note} disabled={disabled} onChange={e => onChange({ ...value, note: e.target.value })} placeholder="Add collection details…" /></label>}
  <p className="payment-hint">Each physical bottle reduces the total outstanding count by one.</p>
  {validation.error && <p role="alert" className="payment-error">{validation.error}</p>}
 </section>;
}
