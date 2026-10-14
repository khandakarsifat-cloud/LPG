import { useState } from 'react';
import toast from 'react-hot-toast';
import { Truck, CheckCircle2, CreditCard, Save } from 'lucide-react';
import { useAuth } from '../../contexts/AuthContext';
import { useUpdatePurchase, useDispatchPurchase, usePayPurchase } from '../../hooks/usePurchases';
import { purchaseAccess, purchaseDraft, purchaseTotals, validatePurchaseDraft } from '../../lib/purchase';
import { formatBDT } from '../../lib/formatBDT';
import { PurchaseConfirmation, PurchaseDialog } from './PurchaseControls';
import { PurchaseForm } from './PurchaseForm';
import { PurchaseHistory, PurchaseIdentity, PurchaseSummary } from './PurchaseSummary';
import { ReceivePurchaseModal } from './ReceivePurchaseModal';
import type { Purchase } from '../../types/purchase';

export function UpdatePurchaseModal({ open, purchase, onClose }: { open: boolean; purchase: Purchase | null; onClose: () => void }) {
  return open && purchase ? <PurchaseDetails key={purchase.purchase_id} purchase={purchase} onClose={onClose} /> : null;
}

function PurchaseDetails({ purchase, onClose }: { purchase: Purchase; onClose: () => void }) {
  const { can } = useAuth();
  const access = purchaseAccess(purchase, can('purchases:manage'));
  const [draft, setDraft] = useState(() => purchaseDraft(purchase));
  const [error, setError] = useState<string | null>(null);
  const [confirm, setConfirm] = useState<'dispatch' | 'pay' | null>(null);
  const [receiptOpen, setReceiptOpen] = useState(false);
  const update = useUpdatePurchase();
  const dispatch = useDispatchPurchase();
  const pay = usePayPurchase();
  const busy = update.isPending || dispatch.isPending || pay.isPending;
  const dirty = JSON.stringify(draft) !== JSON.stringify(purchaseDraft(purchase));
  const totals = purchaseTotals(draft.items, draft.commission, draft.transport_cost, draft.labour_cost, purchase);
  const outgoing = purchase.items.reduce((sum, item) => sum + item.empty_dispatched, 0);

  async function save() {
    const message = access.products ? validatePurchaseDraft(draft, totals.subtotal)
      : access.financials && draft.commission > totals.subtotal ? 'Commission cannot exceed the product subtotal.' : null;
    setError(message); if (message) return;
    try {
      await update.mutateAsync({ purchase_id: purchase.purchase_id, revision: purchase.revision,
        draft: access.financials ? draft : { notes: draft.notes },
      }); toast.success('Purchase updated'); onClose();
    } catch (cause) { setError(cause instanceof Error ? cause.message : 'Changes could not be saved. Try again.'); }
  }
  async function transition() {
    try {
      const payload = { purchase_id: purchase.purchase_id, revision: purchase.revision };
      if (confirm === 'dispatch') { await dispatch.mutateAsync(payload); toast.success('Truck dispatched'); }
      else { await pay.mutateAsync(payload); toast.success('Full payment recorded'); }
      onClose();
    } catch (cause) { setConfirm(null); setError(cause instanceof Error ? cause.message : 'Action failed. Try again.'); }
  }
  return <>
    <PurchaseDialog title={access.complete ? 'Completed purchase' : 'Purchase details'} subtitle={purchase.plant_name} onClose={onClose} busy={busy}>
      <form onSubmit={event => { event.preventDefault(); void save(); }}>
        <div className="modal-body">
          <PurchaseIdentity purchase={purchase} />
          {error && <p role="alert" className="purchase-error">{error} <button type="button" className="btn btn-ghost" onClick={onClose}>Close and reload</button></p>}
          <p className={`purchase-alert${access.complete ? ' success' : ''}`}>
            {access.complete ? 'Received and Paid. This purchase is complete; inventory, shipment and financial details are locked.'
              : purchase.status === 'created' ? 'Prepare the shipment at your own pace. No inventory has moved. Save your changes before dispatch.'
              : purchase.status === 'in_transit' ? 'The shipment remains In Transit until the truck returns, including its time at the plant. Products and outgoing quantities are locked.'
              : purchase.status === 'received' ? 'Inventory and shipment details are finalized. Settle financial details and record full payment to complete the purchase.'
              : 'This historical purchase was cancelled.'}
          </p>
          {access.editable && access.financials ? <>
            <PurchaseForm draft={draft} onChange={setDraft} companyId={purchase.brand_id} purchase={purchase} />
            {purchase.receipt_notes && <section className="purchase-section"><h3>Receipt notes</h3><p className="purchase-hint">{purchase.receipt_notes}</p></section>}
          </> : <>
            <PurchaseSummary purchase={purchase} showNotes={!access.editable} />
            {access.editable && <section className="purchase-section"><label className="input-label" htmlFor="paid-purchase-notes">Notes</label>
              <textarea id="paid-purchase-notes" className="input-field" rows={2} value={draft.notes} onChange={event => setDraft({ ...draft, notes: event.target.value })} />
              <p className="purchase-hint">Financial values are locked because this purchase is Paid.</p>
            </section>}
          </>}
          <PurchaseHistory purchaseId={purchase.purchase_id} />
        </div>
        <div className="modal-footer">
          {dirty && <span className="purchase-hint purchase-footer-hint">Save changes before dispatch, receipt or payment.</span>}
          <button type="button" className="btn btn-secondary" onClick={onClose} disabled={busy}>Close</button>
          {access.editable && <button type="submit" className="btn btn-secondary" disabled={busy || !dirty}><Save size={15} /> Save changes</button>}
          {access.pay && <button type="button" className="btn btn-secondary" disabled={busy || dirty} onClick={() => setConfirm('pay')}><CreditCard size={15} /> Record full payment</button>}
          {access.dispatch && <button type="button" className="btn btn-primary" disabled={busy || dirty || !purchase.truck_id || !purchase.items.length} onClick={() => setConfirm('dispatch')}><Truck size={15} /> Dispatch truck</button>}
          {access.receive && <button type="button" className="btn btn-primary" disabled={busy || dirty} onClick={() => setReceiptOpen(true)}><CheckCircle2 size={15} /> Receive shipment</button>}
        </div>
      </form>
    </PurchaseDialog>
    {confirm && <PurchaseConfirmation title={confirm === 'dispatch' ? 'Dispatch this truck?' : 'Record full payment?'}
      action={confirm === 'dispatch' ? 'Dispatch truck' : 'Record full payment'} busy={busy} onCancel={() => setConfirm(null)} onConfirm={() => void transition()}>
      {confirm === 'dispatch' ? <>
        <p>Dispatch <strong>{purchase.truck_name}</strong> to <strong>{purchase.plant_name}</strong>. Deduct <strong>{outgoing} empty cylinders</strong> from inventory; no filled cylinders are added yet.</p>
        <p>Truck, products, expected quantities and outgoing empties become locked. The shipment stays In Transit until the truck returns and you record actual receipt.</p>
      </> : <>
        <p>Record company payment of <strong>{formatBDT(Number(purchase.company_payable))}</strong>, plus {formatBDT(Number(purchase.transport_cost) + Number(purchase.labour_cost))} in transport and labour expenses.</p>
        <p>Deduct <strong>{formatBDT(Number(purchase.total_cost))}</strong> from the dealership wallet. All prices, commission and purchase costs become locked. No inventory changes occur.</p>
        {purchase.status === 'in_transit' && <p>Receipt remains pending. Later delivery discrepancies will affect inventory but cannot change this settled amount.</p>}
      </>}
    </PurchaseConfirmation>}
    {receiptOpen && <ReceivePurchaseModal purchase={purchase} onClose={() => setReceiptOpen(false)} onReceived={onClose} />}
  </>;
}
