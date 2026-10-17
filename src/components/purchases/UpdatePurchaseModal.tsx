import { useState } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import toast from 'react-hot-toast';
import { Truck, CheckCircle2, CreditCard, Save } from 'lucide-react';
import { useAuth } from '../../contexts/AuthContext';
import { useUpdatePurchase, useDispatchPurchase, usePayPurchase, useReceivePurchase, useCancelPurchase, purchaseKeys } from '../../hooks/usePurchases';
import { useItems } from '../../hooks/useInventory';
import { purchaseAccess, purchaseDraft, purchaseTotals, validatePurchaseDraft, purchaseEmptyShortages, PurchaseStockError, type EmptyShortage } from '../../lib/purchase';
import { formatBDT } from '../../lib/formatBDT';
import { PurchaseConfirmation, PurchaseDialog } from './PurchaseControls';
import { PurchaseForm } from './PurchaseForm';
import { PurchaseHistory, PurchaseIdentity, PurchaseSummary } from './PurchaseSummary';
import { PurchaseStockWarning } from './PurchaseStockWarning';
import type { Purchase } from '../../types/purchase';

export function UpdatePurchaseModal({ open, purchase, onClose }: { open: boolean; purchase: Purchase | null; onClose: () => void }) {
  return open && purchase ? <PurchaseDetails key={purchase.purchase_id} purchase={purchase} onClose={onClose} /> : null;
}

function PurchaseDetails({ purchase, onClose }: { purchase: Purchase; onClose: () => void }) {
  const { can } = useAuth();
  const qc = useQueryClient();
  const itemsQuery = useItems();
  const access = purchaseAccess(purchase, can('purchases:manage'));
  const [draft, setDraft] = useState(() => purchaseDraft(purchase));
  const [draftRevision, setDraftRevision] = useState(purchase.revision);
  const [baseline, setBaseline] = useState(() => JSON.stringify(purchaseDraft(purchase)));
  const [error, setError] = useState<string | null>(null);
  const [confirm, setConfirm] = useState<'dispatch' | 'pay' | 'receive' | 'cancel' | null>(null);
  const [shortages, setShortages] = useState<EmptyShortage[]>([]);
  const update = useUpdatePurchase();
  const dispatch = useDispatchPurchase();
  const pay = usePayPurchase();
  const receive = useReceivePurchase();
  const cancel = useCancelPurchase();
  const [checking, setChecking] = useState(false);
  const busy = checking || update.isPending || dispatch.isPending || pay.isPending || receive.isPending || cancel.isPending;
  const dirty = JSON.stringify(draft) !== baseline
    || access.products && purchase.items.some(item => item.empty_dispatched !== (item.type === 'refill' ? item.quantity : 0));
  const totals = purchaseTotals(draft.items, draft.commission, draft.transport_cost, draft.labour_cost, purchase);
  const outgoing = purchase.items.reduce((sum, item) => sum + item.empty_dispatched, 0);
  function loadSaved() {
    const saved = purchaseDraft(purchase);
    setDraft(saved); setBaseline(JSON.stringify(saved)); setDraftRevision(purchase.revision); setError(null);
  }
  // Refresh clean forms after transitions/polling; preserve a dirty form's revision.
  if (draftRevision !== purchase.revision && !dirty) loadSaved();

  function handleError(cause: unknown) {
    if (cause instanceof PurchaseStockError) setShortages(cause.shortages);
    else setError(cause instanceof Error ? cause.message : 'Action failed. Try again.');
  }
  async function checkEmpties() {
    setChecking(true);
    try {
      const fresh = await itemsQuery.refetch();
      if (fresh.isError) throw new Error('Empty stock could not be checked. Try again.');
      const missing = purchaseEmptyShortages(draft.items, fresh.data ?? []);
      setShortages(missing);
      return missing.length === 0;
    } finally { setChecking(false); }
  }

  async function save() {
    const message = access.products ? validatePurchaseDraft(draft, totals.subtotal)
      : access.financials && draft.commission > totals.subtotal ? 'Commission cannot exceed the product subtotal.' : null;
    setError(message); if (message) return;
    try {
      if (access.products && !await checkEmpties()) return;
      await update.mutateAsync({ purchase_id: purchase.purchase_id, revision: draftRevision,
        draft: access.financials ? draft : { notes: draft.notes },
      });
      const saved = qc.getQueryData<Purchase[]>(purchaseKeys.purchases)?.find(p => p.purchase_id === purchase.purchase_id);
      if (saved) {
        const next = purchaseDraft(saved);
        setDraft(next); setBaseline(JSON.stringify(next)); setDraftRevision(saved.revision);
      }
      toast.success('Purchase updated');
    } catch (cause) { handleError(cause); }
  }
  async function transition() {
    try {
      const payload = { purchase_id: purchase.purchase_id, revision: purchase.revision };
      setError(null);
      if (confirm === 'dispatch') {
        if (!await checkEmpties()) { setConfirm(null); return; }
        await dispatch.mutateAsync(payload); toast.success('Truck dispatched');
      } else if (confirm === 'receive') { await receive.mutateAsync(payload); toast.success('Shipment received'); }
      else if (confirm === 'cancel') { await cancel.mutateAsync(payload); toast.success('Purchase cancelled'); }
      else { await pay.mutateAsync(payload); toast.success('Full payment recorded'); }
      setConfirm(null);
    } catch (cause) { setConfirm(null); handleError(cause); }
  }
  return <>
    <PurchaseDialog title={access.complete ? 'Completed purchase' : 'Purchase details'} subtitle={purchase.plant_name} onClose={onClose} busy={busy}>
      <form onSubmit={event => { event.preventDefault(); void save(); }}>
        <div className="modal-body">
          <PurchaseIdentity purchase={purchase} />
          {error && <p role="alert" className="purchase-error">{error}</p>}
          {dirty && draftRevision !== purchase.revision && <p className="purchase-alert">This purchase changed while you were editing. Your edits are still here. <button type="button" className="btn btn-secondary" onClick={loadSaved}>Reload saved purchase</button></p>}
          <p className={`purchase-alert${access.complete ? ' success' : ''}`}>
            {access.complete ? 'Received and Paid. This purchase is complete; inventory, shipment and financial details are locked.'
              : purchase.status === 'created' ? 'Prepare the shipment at your own pace. No inventory has moved. Save your changes before dispatch.'
              : purchase.status === 'in_transit' ? 'The shipment remains In Transit until the truck returns, including its time at the plant. Products and outgoing quantities are locked.'
              : purchase.status === 'received' ? 'Inventory and shipment details are finalized. Settle financial details and record full payment to complete the purchase.'
              : 'This purchase was cancelled. Recorded stock and purchase payments were reversed.'}
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
          <PurchaseHistory purchase={purchase} />
        </div>
        <div className="modal-footer purchase-details-footer">
          {access.cancel && <button type="button" className="btn btn-secondary purchase-danger-action" disabled={busy} onClick={() => setConfirm('cancel')}>Cancel purchase</button>}
          {dirty ? <span className="purchase-hint purchase-footer-hint" role="status">Save changes before dispatch, receipt or payment.</span>
            : access.dispatch && (!purchase.truck_id || !purchase.items.length) && <span className="purchase-hint purchase-footer-hint">Assign a truck and add at least one product to dispatch.</span>}
          <button type="button" className="btn btn-secondary" onClick={onClose} disabled={busy}>Close</button>
          {access.editable && <button type="submit" className={`btn ${dirty ? 'btn-primary' : 'btn-secondary'}`} disabled={busy || !dirty}><Save size={15} /> {update.isPending ? 'Saving…' : 'Save changes'}</button>}
          {access.pay && <button type="button" className="btn btn-secondary" disabled={busy || dirty} onClick={() => setConfirm('pay')}><CreditCard size={15} /> Record full payment</button>}
          {access.dispatch && <button type="button" className="btn btn-primary" disabled={busy || dirty || !purchase.truck_id || !purchase.items.length} onClick={() => setConfirm('dispatch')}><Truck size={15} /> Dispatch truck</button>}
          {access.receive && <button type="button" className="btn btn-primary" disabled={busy || dirty} onClick={() => setConfirm('receive')}><CheckCircle2 size={15} /> Receive shipment</button>}
        </div>
      </form>
    </PurchaseDialog>
    {confirm && <PurchaseConfirmation title={{ dispatch: 'Dispatch this truck?', pay: 'Record full payment?', receive: 'Receive this shipment?', cancel: 'Cancel this purchase?' }[confirm]}
      action={confirm === 'cancel' ? 'Okay, cancel purchase' : confirm === 'receive' ? 'Receive shipment' : confirm === 'dispatch' ? 'Dispatch truck' : 'Record full payment'} busy={busy} onCancel={() => setConfirm(null)} onConfirm={() => void transition()}>
      {confirm === 'dispatch' ? <>
        <p>Dispatch <strong>{purchase.truck_name}</strong> to <strong>{purchase.plant_name}</strong>. Deduct <strong>{outgoing} empty cylinders</strong> from inventory; no filled cylinders are added yet.</p>
        <p>Transfer {formatBDT(Number(purchase.transport_cost))} from the dealership wallet to logistics. This fee is counted once toward the purchase total.</p>
        <p>Truck, products and expected quantities become locked until receipt.</p>
      </> : confirm === 'receive' ? <>
        <p>Receive all saved expected quantities from <strong>{purchase.plant_name}</strong>.</p>
        <ul>{purchase.items.map(item => <li key={item.purchase_item_id}>{item.brand_name} {item.size_kg} kg {item.mouth_size}: <strong>{item.quantity} {item.type === 'refill' ? 'refills' : 'new cylinders'}</strong></li>)}</ul>
        <p>Add these filled cylinders to stock, complete the transit and free the truck. Transit costs remain editable in Logistics until you close the transit.</p>
      </> : confirm === 'cancel' ? <>
        <p>Cancel this {purchase.status === 'created' ? 'draft' : 'purchase'} and release its truck. Unsaved edits will be discarded.</p>
        <p>{purchase.status === 'created' ? 'No inventory or payments have moved.' : 'Return dispatched empties, remove any received filled cylinders, and refund recorded purchase payments to the dealership wallet. The logistics transport fee will be reversed.'}</p>
        <p>Cancellation requires enough stock to reverse the receipt. Incurred transit expenses remain separate. This action cannot be undone.</p>
      </> : <>
        <p>Record company payment of <strong>{formatBDT(Number(purchase.company_payable))}</strong>, plus {formatBDT(Number(purchase.transport_cost) + Number(purchase.labour_cost))} in transport and labour expenses.</p>
        <p>Settle the purchase total of <strong>{formatBDT(Number(purchase.total_cost))}</strong>, counting any transport fee already transferred. All prices, commission and purchase costs become locked. No inventory changes occur.</p>
      </>}
    </PurchaseConfirmation>}
    {shortages.length > 0 && <PurchaseStockWarning shortages={shortages} onClose={() => setShortages([])} />}
  </>;
}
