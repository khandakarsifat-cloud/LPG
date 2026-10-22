import { useState } from 'react';
import toast from 'react-hot-toast';
import { useAuth } from '../../contexts/AuthContext';
import { useFinanceOperation, usePaymentWallets, useSaleSettlement } from '../../hooks/useFinance';
import { formatBDT } from '../../lib/formatBDT';
import { paymentDraft, validatePayments } from '../../lib/payments';
import type { PaymentDraft } from '../../types/finance';
import { PaymentEntries } from '../pos/PaymentEntries';
import { PurchaseDialog } from '../purchases/PurchaseControls';
import { Pagination } from '../ui/Pagination';
import '../pos/payments.css';

export function CollectPaymentDialog({ saleId, due, onClose }: { saleId: string; due: number; onClose: () => void }) {
  const wallets = usePaymentWallets(); const operation = useFinanceOperation(); const [entries, setEntries] = useState<PaymentDraft[]>([]);
  const validation = validatePayments(entries, due, wallets.data ?? []);
  return <PurchaseDialog title={`Collect payment · #${saleId.slice(0, 8).toUpperCase()}`} subtitle="Only the received amount is credited to the selected wallets." compact onClose={onClose} busy={operation.isPending}>
    <div className="modal-body finance-form">
      {wallets.isPending && <p role="status">Loading wallets…</p>}{wallets.error && <p role="alert" className="payment-error">Wallets could not be loaded. <button className="btn btn-secondary" onClick={() => void wallets.refetch()}>Retry</button></p>}
      {wallets.data && <><PaymentEntries wallets={wallets.data} total={due} entries={entries} onChange={setEntries} disabled={operation.isPending || operation.hasPending} />{!entries.length && <button className="btn btn-secondary" disabled={operation.isPending || operation.hasPending} onClick={() => setEntries([paymentDraft(wallets.data, due)])}>Pay remaining {formatBDT(due)}</button>}</>}
      {operation.hasPending && <div className="finance-recovery" role="alert">A previous financial transaction needs confirmation.<button className="btn btn-secondary" disabled={operation.isPending} onClick={async () => { try { await operation.mutateAsync(undefined); toast.success('Previous transaction confirmed'); onClose(); } catch { /* inline */ } }}>Recover transaction</button></div>}
      {operation.error && <p role="alert" className="payment-error">{operation.error.message}</p>}
    </div><div className="modal-footer"><button className="btn btn-secondary" disabled={operation.isPending} onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={operation.isPending || operation.hasPending || Boolean(validation.error) || !entries.length || !wallets.data} onClick={async () => { try { await operation.mutateAsync({ action: 'collection', sale_id: saleId, payments: validation.payments }); toast.success('Payment received'); onClose(); } catch { /* inline */ } }}>{operation.isPending ? 'Recording…' : 'Record payment'}</button></div>
  </PurchaseDialog>;
}

export function SalePayments({ saleId }: { saleId: string }) {
  const { can } = useAuth(); const [page, setPage] = useState(0); const query = useSaleSettlement(saleId, page); const [collect, setCollect] = useState(false); const data = query.data;
  return <section className="settlement-panel">
    <div className="settlement-heading"><h3>Payments</h3>{data && data.due > 0 && can('finance:manage') && <button className="btn btn-primary" onClick={() => setCollect(true)}>Collect payment</button>}</div>
    {query.isPending && <p role="status">Loading payments…</p>}{query.error && <p role="alert" className="payment-error">Payments could not be loaded. <button className="btn btn-secondary" onClick={() => void query.refetch()}>Retry</button></p>}
    {data && <><dl className="payment-totals"><div><dt>Sale total</dt><dd>{formatBDT(data.total)}</dd></div><div><dt>Total paid</dt><dd>{formatBDT(data.paid)}</dd></div><div className={data.due > 0 ? 'payment-due' : ''}><dt>{data.due > 0 ? 'Remaining due' : 'Fully paid'}</dt><dd>{formatBDT(data.due)}</dd></div></dl>
      {!data.tracking && <p className="payment-hint">Historical sale recorded as fully paid. Payment methods were not recorded.</p>}
      {data.payments.map(p => <div className="settlement-row" key={p.payment_id}><span>{p.wallet_name}<small>{new Date(p.created_at).toLocaleString('en-BD', { timeZone: 'Asia/Dhaka' })} · {p.phase === 'checkout' ? 'At checkout' : 'Collection'}{p.reference && ` · ${p.reference}`}</small></span><strong>{formatBDT(p.amount)}</strong></div>)}
      <Pagination page={page} pageSize={10} total={data.payment_count} onChange={setPage} label="payments" busy={query.isFetching} />
      {collect && <CollectPaymentDialog saleId={saleId} due={data.due} onClose={() => setCollect(false)} />}
    </>}
  </section>;
}
