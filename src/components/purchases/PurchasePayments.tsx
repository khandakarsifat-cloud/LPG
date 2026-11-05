import { useState } from 'react';
import toast from 'react-hot-toast';
import { usePurchaseOperation, usePurchaseSettlement } from '../../hooks/usePurchases';
import { usePaymentWallets } from '../../hooks/useFinance';
import { formatBDT } from '../../lib/formatBDT';
import { paymentDraft, validatePayments } from '../../lib/payments';
import type { PaymentDraft } from '../../types/finance';
import type { Purchase, PurchaseSettlement } from '../../types/purchase';
import { PaymentEntries } from '../pos/PaymentEntries';
import { PurchaseDialog } from './PurchaseControls';


export function PurchasePaymentDialog({ purchase, settlement, refund, operation, onClose }: {
  purchase: Purchase; settlement: PurchaseSettlement; refund: boolean;
  operation: ReturnType<typeof usePurchaseOperation>; onClose: () => void;
}) {
  const wallets = usePaymentWallets();
  const [entries, setEntries] = useState<PaymentDraft[]>([]);
  const pending = settlement.obligations.filter(o => o.remaining > 0);
  const [obligationId, setObligationId] = useState(pending[0]?.obligation_id ?? '');
  const obligation = pending.find(o => o.obligation_id === obligationId);
  const availableWallets = wallets.data;
  const due = refund ? obligation?.remaining ?? 0 : settlement.due;
  const validation = validatePayments(entries, due, availableWallets ?? []);
  const busy = operation.isPending;
  async function submit() {
    try {
      await operation.mutateAsync(refund
        ? { action: 'refund', purchase_id: purchase.purchase_id, obligation_id: obligationId, payments: validation.payments }
        : { action: 'payment', purchase_id: purchase.purchase_id, payments: validation.payments });
      toast.success(refund ? 'Refund recorded' : 'Payment recorded'); onClose();
    } catch { /* Keep the form and original request available for recovery. */ }
  }
  return <PurchaseDialog title={refund ? 'Record purchase refund' : 'Pay purchase'} subtitle={`#${purchase.purchase_id.slice(0, 8).toUpperCase()} · ${purchase.plant_name}`} compact onClose={onClose} busy={busy}>
    <div className="modal-body dialog-form">
      {refund && <label className="input-group"><span className="input-label">Refund obligation</span><select className="input-field" value={obligationId} disabled={busy || operation.hasPending} onChange={e => { setObligationId(e.target.value); setEntries([]); }}>
        {pending.map(o => <option key={o.obligation_id} value={o.obligation_id}>Purchase payment · {formatBDT(o.remaining)}</option>)}
      </select></label>}
      {obligation && <>
        <p className="purchase-hint">Record money actually returned to the selected wallets. Incurred transit costs remain payable separately.</p>
        <details><summary>Original payment references ({obligation.sources.length})</summary>{obligation.sources.map(s => <p className="purchase-hint" key={s.transaction_id}>{s.wallet_name} · {formatBDT(Math.abs(s.amount))} · {s.transaction_id}<br />{s.description}</p>)}</details>
      </>}
      {!refund && <p className="purchase-hint">Payments settle the purchase company payable and labour. Transport is allocated to transit revenue and never automatically moves wallet money.</p>}
      {wallets.isPending && <p role="status">Loading wallets…</p>}
      {wallets.error && <p role="alert" className="purchase-error">Wallets could not be loaded. <button type="button" className="btn btn-secondary" onClick={() => void wallets.refetch()}>Retry</button></p>}
      {availableWallets && <><PaymentEntries wallets={availableWallets} entries={entries} onChange={setEntries} total={due} disabled={busy || operation.hasPending} refund={refund} />
        {!entries.length && <button type="button" className="btn btn-secondary" disabled={busy || operation.hasPending || due <= 0} onClick={() => setEntries([paymentDraft(availableWallets, due)])}>{refund ? 'Refund' : 'Pay'} remaining {formatBDT(due)}</button>}</>}
      {operation.hasPending && <p className="purchase-alert">This transaction needs confirmation. <button type="button" className="btn btn-secondary" disabled={busy} onClick={async () => { try { await operation.mutateAsync(undefined); toast.success('Transaction confirmed'); onClose(); } catch { /* inline error */ } }}>Recover transaction</button></p>}
      {operation.error && <p role="alert" className="purchase-error">{operation.error.message}</p>}
    </div>
    <div className="modal-footer"><button type="button" className="btn btn-secondary" disabled={busy} onClick={onClose}>Close</button><button type="button" className="btn btn-primary" disabled={busy || operation.hasPending || !entries.length || Boolean(validation.error) || !availableWallets || due <= 0} onClick={() => void submit()}>{busy ? 'Recording…' : refund ? 'Record refund' : 'Record payment'}</button></div>
  </PurchaseDialog>;
}

export function PurchaseSettlementSummary({ purchase }: { purchase: Purchase }) {
  const query = usePurchaseSettlement(purchase.purchase_id);
  const data = query.data;
  return <section className="purchase-section settlement-panel" aria-label="Purchase settlement summary">
    <h3>Payment summary</h3>
    {query.isPending && <p role="status">Loading settlement…</p>}
    {query.error && <p role="alert" className="purchase-error">Settlement could not be loaded. <button type="button" className="btn btn-secondary" onClick={() => void query.refetch()}>Retry settlement</button></p>}
    {data && <><dl className="payment-totals"><div><dt>Gross payable</dt><dd>{formatBDT(data.total)}</dd></div><div><dt>Commission rebate {purchase.status === 'created' ? 'planned' : 'applied'}</dt><dd>{formatBDT(data.rebate_applied || (purchase.status === 'created' ? data.rebate_amount : 0))}</dd></div><div><dt>Wallet payments</dt><dd>{formatBDT(data.paid)}</dd></div><div className="payment-due"><dt>{purchase.status === 'cancelled' ? 'Refund remaining' : 'Outstanding'}</dt><dd>{formatBDT(purchase.status === 'cancelled' ? data.refund_due : data.due)}</dd></div></dl>
      {data.company_credit > 0 && <p className="purchase-hint">Available company rebate credit: {formatBDT(data.company_credit)}. The next rebate used with this company consumes existing credit first.</p>}
      {purchase.status === 'cancelled' && <p className="purchase-alert">{data.financial_closed_at ? 'Financially closed: all recorded refund obligations are settled.' : 'Pending refund: normal purchase operations are locked.'} Refunded / reversed: {formatBDT(data.refunded)}. Complete the transit separately in Logistics after paying crew earnings.</p>}
      {data.obligations.map(o => <div key={o.obligation_id}><div className="settlement-row history-card"><span>Purchase payment<small>{formatBDT(o.refunded)} refunded / reversed · Return to business</small></span><strong>{formatBDT(o.remaining)} due</strong></div>
        <details><summary>Original payment references ({o.sources.length})</summary>{o.sources.map(s => <p className="purchase-hint" key={s.transaction_id}>{s.wallet_name} · {formatBDT(Math.abs(s.amount))}<br />Ledger: {s.transaction_id}{s.payment_id && ` · Payment: ${s.payment_id}`}<br />{s.description}</p>)}</details>
      </div>)}
    </>}
  </section>;
}
