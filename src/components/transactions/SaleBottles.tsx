import { useState } from 'react';
import toast from 'react-hot-toast';
import { useAuth } from '../../contexts/AuthContext';
import { useCollectBottles, useSaleBottles } from '../../hooks/useSales';
import { useInventoryBalances } from '../../hooks/useInventory';
import { validateBottles } from '../../lib/bottles';
import { formatBDT } from '../../lib/formatBDT';
import type { BottleInput, SaleBottles as SaleBottleData } from '../../types/bottles';
import { ReceivedBottles } from '../pos/ReceivedBottles';
import { PurchaseDialog } from '../purchases/PurchaseControls';
import { Pagination } from '../ui/Pagination';
import { useLPGBrands } from '../../hooks/useBrands';

function CollectBottlesDialog({ saleId, bottles, onClose }: { saleId: string; bottles: SaleBottleData; onClose: () => void }) {
 const { can } = useAuth(); const operation = useCollectBottles(); const inventory = useInventoryBalances();
 const brands = useLPGBrands();
 const obligations = bottles.obligations;
 const [value, setValue] = useState<BottleInput>({ lines: [], note: '' });
 const [cost, setCost] = useState('0');
 const products = (inventory.data ?? []).map(i => ({ item_id: i.item_id, name: `${i.lpg_brands?.brand_name ?? 'Product unavailable'} ${i.size_kg}kg ${i.mouth_size ?? ''}`.trim(), size_kg: Number(i.size_kg), mouth_size: i.mouth_size ?? null }));
 const lines = value.lines.filter(l => l.quantity !== 0); const validation = validateBottles(obligations,products,lines,true,bottles.received);
 const costValid = cost === '' || (/^\d+(\.\d{1,2})?$/.test(cost) && Number(cost) <= 9999999999.99);
 const disabled = operation.isPending || operation.hasPending;
 const save = async (recover = false) => { try {
  await operation.mutateAsync(recover ? undefined : { sale_id: saleId, payload: { ...value, lines, fee: Number(cost) } });
  toast.success(recover ? 'Previous bottle collection confirmed' : 'Bottles collected'); onClose();
 } catch { /* retain draft and original request for recovery */ } };
 return <PurchaseDialog title="Collect bottles" subtitle={`Sale #${saleId.slice(0,8).toUpperCase()} · Record only bottles physically received.`} className="bottle-collection-dialog" busy={operation.isPending} onClose={onClose}>
  <div className="modal-body bottle-editor">
   {operation.hasPending && <div className="finance-recovery" role="alert">A previous bottle collection needs confirmation. Recover its original request before recording another.<button className="btn btn-secondary" disabled={operation.isPending} onClick={() => void save(true)}>Recover bottle collection</button></div>}
   {inventory.isError && <p role="alert" className="payment-error">Products could not be loaded. <button className="btn btn-secondary" onClick={() => void inventory.refetch()}>Retry</button></p>}
   {brands.isError && <p role="alert" className="payment-error">Brand order could not be loaded. <button className="btn btn-secondary" onClick={() => void brands.refetch()}>Retry</button></p>}
   {inventory.isPending && <p role="status">Loading bottles…</p>}
   <ReceivedBottles obligations={obligations} previouslyReceived={bottles.received} products={products} catalog={inventory.data ?? []} brands={brands.data ?? []} value={value} onChange={setValue} disabled={disabled || !inventory.data} collection />
   {can('sales:collect_money') && <div className="bottle-expense">
    <label className="input-group"><span className="input-label">Additional Settlement Cost (Tk, optional)</span><input className="input-field" inputMode="decimal" type="number" min="0" step=".01" value={cost} disabled={disabled} onChange={e => setCost(e.target.value)} /></label>
    <p className="payment-hint">Added to the customer’s amount due. Use Collect payment to receive it, including split or partial payments.</p>
   </div>}
   {operation.error && <p className="payment-error" role="alert">{operation.error.message}</p>}
  </div><div className="modal-footer"><button className="btn btn-secondary" disabled={operation.isPending} onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={disabled || Boolean(validation.error) || !costValid || !inventory.data} onClick={() => void save()}>{operation.isPending ? 'Recording…' : 'Record bottle collection'}</button></div>
 </PurchaseDialog>;
}

export function SaleBottles({ saleId }: { saleId: string }) {
 const { can } = useAuth(); const [page,setPage] = useState(0); const [collect,setCollect] = useState(false);
 const query = useSaleBottles(saleId,page); const data = query.data; const recovery = useCollectBottles();
 const receivedProducts = new Map<string, { name: string; quantity: number; checkout: number; collection: number }>();
 for (const line of data?.actual ?? []) {
  const product = receivedProducts.get(line.item_id) ?? { name: line.name, quantity: 0, checkout: 0, collection: 0 };
  product.quantity += line.quantity; product[line.phase] += line.quantity; receivedProducts.set(line.item_id, product);
 }
 return <section className="bottle-settlement">
  <div className="settlement-heading"><h3>Bottle settlement</h3>{data && can('sales:collect_bottles') && <button disabled={data.outstanding === 0 && !recovery.hasPending} className="btn btn-primary" onClick={() => setCollect(true)}>{recovery.hasPending ? 'Recover bottle collection' : 'Collect bottles'}</button>}</div>
  {query.isPending && <p role="status">Loading bottle settlement…</p>}
  {query.isError && <p role="alert" className="payment-error">Bottle settlement could not be loaded. <button className="btn btn-secondary" onClick={() => void query.refetch()}>Retry</button></p>}
  {data && <>
   <><div className="bottle-summary"><span>Expected <strong>{data.expected}</strong></span><span>Received <strong>{data.received}</strong></span><span>Outstanding <strong>{data.outstanding}</strong></span></div>
    <div className="bottle-comparison">
     <section aria-label="Expected bottles"><h4>Expected bottles <span>{data.expected}</span></h4><ul>
      {data.obligations.map(expected => {
       const received = receivedProducts.get(expected.item_id)?.quantity ?? 0;
       return <li key={expected.item_id}><div><strong>{expected.name}</strong>{received !== expected.expected && <small>{received === 0 ? 'None of this product received' : `${received} of this product received`}</small>}</div><b>{expected.expected}</b></li>;
      })}
     </ul></section>
     <section aria-label="Received bottles"><h4>Received bottles <span>{data.received}</span></h4><ul>
      {[...receivedProducts].map(([id, actual]) => {
       const expected = data.obligations.find(line => line.item_id === id)?.expected ?? 0;
       return <li key={id}><div><strong>{actual.name}</strong><small>{actual.checkout > 0 ? `${actual.checkout} at checkout` : ''}{actual.checkout > 0 && actual.collection > 0 ? ' · ' : ''}{actual.collection > 0 ? `${actual.collection} collected later` : ''}</small>{expected === 0 ? <small>Unexpected product</small> : actual.quantity > expected ? <small>{actual.quantity - expected} above original expectation</small> : null}</div><b>{actual.quantity}</b></li>;
      })}
     </ul>{receivedProducts.size === 0 && <p className="payment-hint">No bottles received yet.</p>}</section>
    </div>
    <p className="payment-hint">{data.outstanding === 0 ? 'Bottle settled. ' : ''}Settlement uses the total count; product differences are for reference.</p>
   </>
   <h3>Transaction history</h3>
   <div className="bottle-history history-list">{data.events.map(event => <article className="bottle-event history-card" key={event.id}>
    <header className="history-heading"><strong>{event.kind === 'sale' ? 'Original sale' : event.kind === 'payment' ? 'Payment received' : event.phase === 'checkout' ? 'Bottles at checkout' : 'Bottle collection'}</strong>{event.amount > 0 && <strong>{event.kind === 'bottles' ? 'Additional Settlement Cost ' : ''}{formatBDT(event.amount)}</strong>}</header>
    <small>{new Date(event.created_at).toLocaleString('en-BD',{ timeZone: 'Asia/Dhaka' })} · {event.actor} · {event.phase === 'checkout' ? 'Checkout' : 'After sale'}</small>
    {event.lines.map((line,index) => <p key={index}>{line.quantity} × {line.received_name}{line.acknowledged ? ' · Product / quantity difference acknowledged' : ''}</p>)}
    {event.expense > 0 && <p>Business expense: {formatBDT(event.expense)} · {event.expense_wallet_name}</p>}
    {event.note && <p>{event.note}</p>}
   </article>)}</div>
   {!data.events.length && <p className="payment-hint">No separately recorded settlement activity.</p>}
   <Pagination page={page} pageSize={10} total={data.event_count} onChange={setPage} label="events" busy={query.isFetching} />
   {collect && <CollectBottlesDialog saleId={saleId} bottles={data} onClose={() => setCollect(false)} />}
  </>}
 </section>;
}
