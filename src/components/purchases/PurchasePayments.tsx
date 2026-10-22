import { useState } from 'react';
import toast from 'react-hot-toast';
import { usePurchaseOperation, usePurchaseSettlement } from '../../hooks/usePurchases';
import { usePaymentWallets } from '../../hooks/useFinance';
import { formatBDT } from '../../lib/formatBDT';
import { paymentDraft, validatePayments } from '../../lib/payments';
import { purchaseDate } from '../../lib/purchase';
import type { PaymentDraft } from '../../types/finance';
import type { Purchase, PurchaseSettlement } from '../../types/purchase';
import { PaymentEntries } from '../pos/PaymentEntries';
import { PurchaseDialog } from './PurchaseControls';
import { Pagination } from '../ui/Pagination';

const purchaseComponentLabel: Record<string, string> = { company: 'Company payment', labour: 'Labour / historical trip charges', transport: 'Transport funding', legacy: 'Historical purchase payment', transport_income: 'Historical Logistics funding reversal' };

export function PurchasePaymentDialog({ purchase, settlement, refund, operation, onClose }: {
  purchase: Purchase; settlement: PurchaseSettlement; refund: boolean;
  operation: ReturnType<typeof usePurchaseOperation>; onClose: () => void;
}) {
  const wallets = usePaymentWallets();
  const [entries, setEntries] = useState<PaymentDraft[]>([]);
  const pending = settlement.obligations.filter(o => o.remaining > 0);
  const [obligationId, setObligationId] = useState(pending[0]?.obligation_id ?? '');
  const obligation = pending.find(o => o.obligation_id === obligationId);
  const internal = obligation?.credit_business === false;
  const availableWallets = internal ? (settlement.internal_wallet ? [settlement.internal_wallet] : []) : wallets.data;
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
    <div className="modal-body finance-form">
      {refund && <label className="input-group"><span className="input-label">Refund obligation</span><select className="input-field" value={obligationId} disabled={busy || operation.hasPending} onChange={e => { setObligationId(e.target.value); setEntries([]); }}>
        {pending.map(o => <option key={o.obligation_id} value={o.obligation_id}>{purchaseComponentLabel[o.component] ?? o.component} · {formatBDT(o.remaining)}</option>)}
      </select></label>}
      {obligation && <>
        <p className="purchase-hint">{obligation.credit_business ? 'Record money actually returned to the selected wallets. A different active wallet may receive the refund.' : 'Reverse historical Logistics funding only. No purchasing wallet receives money because the original purchasing debit was not recorded.'} {obligation.logistics_amount > 0 && 'The corresponding Logistics funding is debited atomically. Incurred truck expenses remain intact.'}</p>
        <details><summary>Original payment references ({obligation.sources.length})</summary>{obligation.sources.map(s => <p className="purchase-hint" key={s.transaction_id}>{s.wallet_name} · {formatBDT(Math.abs(s.amount))} · {s.transaction_id}<br />{s.description}</p>)}</details>
      </>}
      {!refund && <p className="purchase-hint">Transport already funded at dispatch is counted once. Payments settle company payable first, then labour and any historical transport balance. Receiving remains independent.</p>}
      {!internal && wallets.isPending && <p role="status">Loading wallets…</p>}
      {!internal && wallets.error && <p role="alert" className="purchase-error">Wallets could not be loaded. <button type="button" className="btn btn-secondary" onClick={() => void wallets.refetch()}>Retry</button></p>}
      {availableWallets && <><PaymentEntries wallets={availableWallets} entries={entries} onChange={setEntries} total={due} disabled={busy || operation.hasPending} refund={refund} />
        {!entries.length && <button type="button" className="btn btn-secondary" disabled={busy || operation.hasPending || due <= 0} onClick={() => setEntries([paymentDraft(availableWallets, due)])}>{refund ? 'Refund' : 'Pay'} remaining {formatBDT(due)}</button>}</>}
      {operation.hasPending && <p className="purchase-alert">This transaction needs confirmation. <button type="button" className="btn btn-secondary" disabled={busy} onClick={async () => { try { await operation.mutateAsync(undefined); toast.success('Transaction confirmed'); onClose(); } catch { /* inline error */ } }}>Recover transaction</button></p>}
      {operation.error && <p role="alert" className="purchase-error">{operation.error.message}</p>}
    </div>
    <div className="modal-footer"><button type="button" className="btn btn-secondary" disabled={busy} onClick={onClose}>Close</button><button type="button" className="btn btn-primary" disabled={busy || operation.hasPending || !entries.length || Boolean(validation.error) || !availableWallets || due <= 0} onClick={() => void submit()}>{busy ? 'Recording…' : refund ? 'Record refund' : 'Record payment'}</button></div>
  </PurchaseDialog>;
}

export function PurchasePayments({ purchase }: { purchase: Purchase }) {
  const [page, setPage] = useState(0);
  const query = usePurchaseSettlement(purchase.purchase_id, page);
  const data = query.data;
  return <section className="purchase-section settlement-panel" aria-label="Purchase payments and refunds">
    <h3>Payments & refunds</h3>
    {query.isPending && <p role="status">Loading settlement…</p>}
    {query.error && <p role="alert" className="purchase-error">Settlement could not be loaded. <button type="button" className="btn btn-secondary" onClick={() => void query.refetch()}>Retry settlement</button></p>}
    {data && <><dl className="payment-totals"><div><dt>Total payable</dt><dd>{formatBDT(data.total)}</dd></div><div><dt>Amount paid</dt><dd>{formatBDT(data.paid)}</dd></div><div className="payment-due"><dt>{purchase.status === 'cancelled' ? 'Refund remaining' : 'Outstanding'}</dt><dd>{formatBDT(purchase.status === 'cancelled' ? data.refund_due : data.due)}</dd></div></dl>
      {purchase.status === 'cancelled' && <p className="purchase-alert">{data.financial_closed_at ? 'Financially closed: all recorded refund obligations are settled.' : 'Pending refund: normal purchase operations are locked.'} Refunded / reversed: {formatBDT(data.refunded)}. Transit operating costs close separately in Logistics.</p>}
      {data.legacy && <p className="purchase-hint">Historical records are preserved. Any unrecorded payment method remains unknown; refunds are limited to original ledger evidence. Legacy wallet names reflect their label when snapshotting was introduced.</p>}
      {data.obligations.map(o => <div key={o.obligation_id}><div className="settlement-row"><span>{purchaseComponentLabel[o.component] ?? o.component}<small>{formatBDT(o.refunded)} refunded / reversed · {o.credit_business ? 'Return to purchasing business' : 'Logistics reversal only'}</small></span><strong>{formatBDT(o.remaining)} due</strong></div>
        <details><summary>Original payment references ({o.sources.length})</summary>{o.sources.map(s => <p className="purchase-hint" key={s.transaction_id}>{s.wallet_name} · {formatBDT(Math.abs(s.amount))}<br />Ledger: {s.transaction_id}{s.payment_id && ` · Payment: ${s.payment_id}`}<br />{s.description}</p>)}</details>
      </div>)}
      {data.payments.map(p => <div className="settlement-row" key={p.transaction_id}><span>{p.wallet_name}<small>{purchaseDate(p.created_at)} · {p.actor ?? 'Historical actor not recorded'}<br />{p.description}{p.reference && ` · Ref: ${p.reference}`}<br />Ledger: {p.transaction_id}{p.operation_id && ` · Operation: ${p.operation_id}`}</small></span><strong>{p.amount > 0 ? '+' : '−'}{formatBDT(Math.abs(p.amount))}</strong></div>)}
      {!data.payment_count && <p className="purchase-hint">No wallet entries were recorded.</p>}
      <Pagination page={page} pageSize={10} total={data.payment_count} onChange={setPage} busy={query.isFetching} label="purchase wallet entries" />
    </>}
  </section>;
}
