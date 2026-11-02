import './finance-modals.css';
import { useState } from 'react';
import { useAuth } from '../../contexts/AuthContext';
import { useFinancialEntry } from '../../hooks/useFinancialTypes';
import { useFinanceOperation } from '../../hooks/useFinance';
import { useWallets } from '../../hooks/useLogistics';
import { dhakaToday } from '../../lib/businessDate';
import { formatBDT } from '../../lib/formatBDT';
import { PurchaseConfirmation, PurchaseDialog, PurchaseNumber, PurchaseSelect } from '../purchases/PurchaseControls';
import { DatePicker } from '../ui/DatePicker';
import { allocationText, financialCategoryLabel } from '../../lib/financial';
import { AccountingHistory } from './AccountingManagement';

export function FinancialEntryDetails({ id, onClose }: { id: string; onClose: () => void }) {
 const q = useFinancialEntry(id); const { can } = useAuth(); const wallets = useWallets(); const op = useFinanceOperation();
 const [returning, setReturning] = useState(false); const [review, setReview] = useState(false); const [amount, setAmount] = useState(0); const [wallet, setWallet] = useState(''); const [date, setDate] = useState(dhakaToday()); const [reason, setReason] = useState(''); const [asset, setAsset] = useState(false);
 const e = q.data; const remaining = e ? e.amount - e.returned : 0;
 const valid = amount > 0 && amount <= remaining && !!wallet && !!reason.trim() && date >= (e?.occurred_on ?? '') && date <= dhakaToday();
 async function record() {
  if (!e) return;
  try { await op.mutateAsync({ action: 'financial_entry', type_id: e.type_id, expected_revision: e.type_revision, reversal_of: e.entry_id, wallet_id: wallet, amount, date, description: reason }); setReturning(false); setReview(false); } catch { setReview(false); }
 }
 if (asset && e?.asset_id) return <AccountingHistory kind="asset" id={e.asset_id} onClose={() => setAsset(false)} />;
 return <PurchaseDialog className="finance-operation-dialog" title="Financial entry" onClose={onClose} busy={op.isPending} compact><div className="modal-body dialog-form">
  {q.isPending && <p role="status">Loading entry…</p>}{q.error && <p role="alert" className="payment-error">{q.error.message}</p>}
  {e && <><h3>{e.type_name}</h3><p>{e.description}</p><dl className="finance-entry-details"><div><dt>Recorded category</dt><dd>{financialCategoryLabel(e.account)}</dd></div><div><dt>Business allocation</dt><dd>{allocationText(e.allocations)}</dd></div><div><dt>Amount</dt><dd>{formatBDT(e.amount)}</dd></div><div><dt>Wallet</dt><dd>{e.wallet_name}</dd></div><div><dt>Accounting date</dt><dd>{e.occurred_on}</dd></div><div><dt>Returned</dt><dd>{formatBDT(e.returned)}</dd></div></dl>
   {e.asset_id && <button className="btn btn-secondary" onClick={() => setAsset(true)}>Asset history</button>}
   {!e.reversal_of && remaining > 0 && can('finance:returns') && !returning && <button className="btn btn-secondary" onClick={() => { setReturning(true); setAmount(remaining); setWallet(e.wallet_id); }}>Record returned funds</button>}
   {returning && <form onSubmit={event => { event.preventDefault(); if (valid) setReview(true); }}><p className="finance-note">Record an actual return of money. It reverses the original category and business allocation, including partial rounding.</p><PurchaseNumber label="Returned amount (Tk)" money value={amount} onChange={v => setAmount(v ?? 0)} /><div className="financial-return-wallet-date"><PurchaseSelect label="Return wallet" value={wallet} onChange={setWallet} options={(wallets.data ?? []).filter(w => w.is_active).map(w => ({ value: w.wallet_id, label: w.name }))} /><div className="input-group"><span className="input-label">Return date</span><DatePicker label="Return date" value={date} min={e.occurred_on} max={dhakaToday()} onChange={setDate} /></div></div><label className="input-group"><span className="input-label">Return reason</span><input required maxLength={1000} className="input-field" value={reason} onChange={event => setReason(event.target.value)} /></label><button className="btn btn-primary" disabled={!valid || op.isPending || op.hasPending}>Review return</button></form>}
  </>}
  {op.error && <p role="alert" className="payment-error">{op.error.message}</p>}{op.hasPending && <button className="btn btn-secondary" onClick={() => void op.mutateAsync(undefined).then(() => setReturning(false)).catch(() => {})}>Recover return</button>}
 </div><div className="modal-footer"><button className="btn btn-secondary" onClick={onClose}>Close</button></div>{review && <PurchaseConfirmation title="Confirm returned funds" action="Record return" onCancel={() => setReview(false)} busy={op.isPending} onConfirm={() => void record()}><p>{e?.type_name} · {formatBDT(amount)} · {date}</p><p>{reason}</p><p>{allocationText(e?.allocations ?? {})}</p></PurchaseConfirmation>}</PurchaseDialog>;
}

