import { useState } from 'react';
import toast from 'react-hot-toast';
import { useReceivePurchase } from '../../hooks/usePurchases';
import { PurchaseConfirmation, PurchaseDialog, PurchaseNumber } from './PurchaseControls';
import { formatBDT } from '../../lib/formatBDT';
import type { Purchase } from '../../types/purchase';

export function ReceivePurchaseModal({ purchase, onClose, onReceived }: { purchase: Purchase; onClose: () => void; onReceived: () => void }) {
  const receive = useReceivePurchase();
  const [quantities, setQuantities] = useState<(number | null)[]>(() => purchase.items.map(item => item.quantity));
  const [notes, setNotes] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [confirm, setConfirm] = useState(false);
  const refill = purchase.items.reduce((sum, item, index) => sum + (item.type === 'refill' ? quantities[index] ?? 0 : 0), 0);
  const newCylinders = purchase.items.reduce((sum, item, index) => sum + (item.type === 'package' ? quantities[index] ?? 0 : 0), 0);
  const discrepancy = purchase.items.some((item, index) => quantities[index] !== item.quantity);
  const actualSubtotal = purchase.items.reduce((sum, item, index) => sum + (quantities[index] ?? 0) * Math.round(Number(item.unit_price) * 100), 0) / 100;
  async function submit() {
    try {
      await receive.mutateAsync({ purchase_id: purchase.purchase_id, revision: purchase.revision, receipt_notes: notes,
        items: purchase.items.map((item, index) => ({ purchase_item_id: item.purchase_item_id, received_quantity: quantities[index] ?? 0 })),
      });
      toast.success('Shipment received'); onReceived();
    } catch (cause) { setConfirm(false); setError(cause instanceof Error ? cause.message : 'Receipt failed. Try again.'); }
  }
  return <>
    <PurchaseDialog title="Receive shipment" subtitle={`${purchase.plant_name} · ${purchase.truck_name}`} onClose={onClose} busy={receive.isPending}>
      <form onSubmit={event => {
        event.preventDefault();
        const message = quantities.some(q => q === null || !Number.isInteger(q) || q < 0) ? 'Enter the actual quantity for every product, including zero where nothing arrived.'
          : discrepancy && !notes.trim() ? 'Explain the quantity discrepancy in receipt notes.'
          : purchase.payment_status === 'unpaid' && Number(purchase.commission) > actualSubtotal ? 'Commission exceeds the actual product subtotal. Go back and adjust commission before receiving.' : null;
        setError(message); if (!message) setConfirm(true);
      }}>
        <div className="modal-body purchase-receipt-body">
          <p className="purchase-alert">Record receipt after the truck has returned. Only actual filled cylinders will be added to inventory. The shipment and its saved operating costs will be finalized.</p>
          {error && <p role="alert" className="purchase-error">{error}</p>}
          <button type="button" className="btn btn-secondary" onClick={() => setQuantities(purchase.items.map(item => item.quantity))}>Reset to expected</button>
          {purchase.items.map((item, index) => <div key={item.purchase_item_id} className="purchase-receipt-row">
            <div><strong>{item.brand_name} {item.size_kg} kg {item.mouth_size}</strong><small>{item.type === 'refill' ? 'Refill' : 'New cylinders'} · Expected {item.quantity} · Empties sent {item.empty_dispatched}</small></div>
            <PurchaseNumber label={`Received ${item.type === 'refill' ? 'refills' : 'new cylinders'}`} value={quantities[index] ?? null}
              onChange={n => setQuantities(current => current.map((q, i) => i === index ? n : q))} />
          </div>)}
          <section className="purchase-section"><label className="input-label" htmlFor="receipt-notes">Receipt notes {discrepancy ? '(required for discrepancies)' : '(optional)'}</label>
            <textarea id="receipt-notes" className="input-field" rows={2} value={notes} onChange={event => setNotes(event.target.value)} placeholder="Explain missing or extra cylinders…" />
          </section>
          <p className="purchase-hint">{purchase.payment_status === 'paid'
            ? `The paid total of ${formatBDT(Number(purchase.total_cost))} remains unchanged, even if actual quantities differ.`
            : 'The actual quantities become the billing basis. Prices and commission remain editable until payment.'}</p>
        </div>
        <div className="modal-footer"><button type="button" className="btn btn-secondary" onClick={onClose} disabled={receive.isPending}>Go back</button>
          <button type="submit" className="btn btn-primary" disabled={receive.isPending}>Receive shipment</button></div>
      </form>
    </PurchaseDialog>
    {confirm && <PurchaseConfirmation title="Finalize this receipt?" action="Receive shipment" busy={receive.isPending} onCancel={() => setConfirm(false)} onConfirm={() => void submit()}>
      <p>Add <strong>{refill} refilled</strong> and <strong>{newCylinders} new filled cylinders</strong> to inventory. No empty-cylinder stock is added or refunded.</p>
      <p>Finalize this shipment, deduct {formatBDT(Number(purchase.operating_cost ?? 0))} in saved operating expenses from the logistics wallet, and release the truck. The actual quantities and shipment costs cannot be changed afterward.</p>
      <p>{purchase.payment_status === 'paid' ? 'The purchase will be fully completed and locked.' : 'Payment remains Unpaid. Financial details can be finalized before full payment.'}</p>
    </PurchaseConfirmation>}
  </>;
}
