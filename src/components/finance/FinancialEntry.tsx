import './finance-modals.css';
import { useState } from 'react';
import toast from 'react-hot-toast';
import { useFinanceOperation } from '../../hooks/useFinance';
import { useFinancialCatalog } from '../../hooks/useFinancialTypes';
import { useWallets } from '../../hooks/useLogistics';
import { formatBDT } from '../../lib/formatBDT';
import { employeeToday } from '../../lib/employee';
import { PurchaseConfirmation, PurchaseDialog, PurchaseNumber, PurchaseSelect } from '../purchases/PurchaseControls';
import { DatePicker } from '../ui/DatePicker';
import { BusinessAllocationEditor } from './BusinessAllocation';
import { allocationText, validAllocation } from '../../lib/financial';
import { customCategoryOptions } from '../../lib/financial';
import type { BusinessAllocation } from '../../types/financial';
import './finance.css';
import { FinancialTypeSelect } from './FinancialTypeSelect';
import { useAuth } from '../../contexts/AuthContext';

export function FinancialEntryDialog({ onClose }: { onClose: () => void }) {
 const { can } = useAuth();
 const catalog = useFinancialCatalog(); const wallets = useWallets(); const operation = useFinanceOperation();
 const [typeId, setTypeId] = useState(''); const [wallet, setWallet] = useState(''); const [amount, setAmount] = useState(0);
 const [date, setDate] = useState(employeeToday()); const [description, setDescription] = useState(''); const [confirm, setConfirm] = useState(false);
 const [override, setOverride] = useState<BusinessAllocation | null>(null);
 const selected = catalog.data?.types.find(t => t.type_id === typeId); const source = wallets.data?.find(w => w.wallet_id === wallet);
 const allocation = override ?? selected?.allocations ?? {}; const disabled = operation.isPending || operation.hasPending;
 const valid = !!selected?.is_active && !!source?.is_active && amount > 0 && !!date && date <= employeeToday() && !!description.trim() && validAllocation(allocation);
 const category = customCategoryOptions.find(c => c.value === selected?.account)?.label ?? '';
 const incoming = selected?.account === 'other_income' || selected?.account === 'capital';
 async function submit() {
  if (!selected) return;
  try { await operation.mutateAsync({ action: 'financial_entry', type_id: typeId, expected_revision: selected.revision, wallet_id: wallet, amount, date, description: description.trim(), ...(override ? { allocations: override } : {}) }); toast.success('Financial entry recorded'); onClose(); } catch { /* Recovery and error are shown below. */ }
 }
 const notice = <>{operation.error && <p role="alert" className="purchase-error">{operation.error.message}</p>}{operation.hasPending && <div className="purchase-alert">Recover the previous entry before recording another.<button type="button" className="btn btn-secondary" disabled={operation.isPending} onClick={() => void operation.mutateAsync(undefined).then(onClose).catch(() => {})}>Recover entry</button></div>}</>;
 return <><PurchaseDialog title="Financial entry" onClose={onClose} busy={operation.isPending} compact className="finance-entry-dialog"><form onSubmit={e => { e.preventDefault(); if (valid) setConfirm(true); }}><div className="modal-body dialog-form"><fieldset className="spending-fields" disabled={disabled}>
  <FinancialTypeSelect value={typeId} onChange={v => { setTypeId(v); setOverride(null); }} types={(catalog.data?.types ?? []).filter(t => t.origin === 'custom' && t.is_active && (t.account==='capital'?can('finance:capital'):['equipment','other_assets'].includes(t.account??'')?can('finance:assets:manage'):true))} />
  {selected && <><div className="entry-allocation-preview"><strong>{category}</strong><span>{allocationText(allocation)}</span></div><details><summary>Override allocation for this entry</summary><BusinessAllocationEditor value={allocation} onChange={setOverride} disabled={disabled} />{override && <button type="button" className="btn btn-secondary" onClick={() => setOverride(null)}>Use type defaults</button>}</details></>}
  <PurchaseSelect label={incoming ? 'Received into wallet' : 'Paid from wallet'} value={wallet} onChange={setWallet} options={(wallets.data ?? []).filter(w => w.is_active && w.can_use).map(w => ({ value: w.wallet_id, label: w.name }))} />
  <PurchaseNumber label="Amount (Tk)" money value={amount} onChange={v => setAmount(v ?? 0)} />
  <div className="input-group"><span className="input-label">Entry date</span><DatePicker label="Entry date" value={date} max={employeeToday()} onChange={setDate} /></div>
  <label className="input-group"><span className="input-label">Description / asset name</span><textarea required maxLength={1000} rows={2} className="input-field" value={description} onChange={e => setDescription(e.target.value)} /></label></fieldset>
  {(catalog.isPending || wallets.isPending) && <p role="status">Loading types and wallets…</p>}{(catalog.error || wallets.error) && <p role="alert" className="purchase-error">Entry options unavailable. <button type="button" className="btn btn-secondary" onClick={() => { void catalog.refetch(); void wallets.refetch(); }}>Retry</button></p>}{notice}
 </div><div className="modal-footer"><button type="button" className="btn btn-secondary" disabled={operation.isPending} onClick={onClose}>Back</button><button className="btn btn-primary" disabled={disabled || !valid}>Review entry</button></div></form></PurchaseDialog>
 {confirm && <PurchaseConfirmation title="Confirm financial entry" action="Record entry" busy={operation.isPending} confirmDisabled={disabled || !valid} onCancel={() => setConfirm(false)} onConfirm={() => void submit()}><dl className="spending-confirm"><div><dt>Type</dt><dd>{selected?.name}</dd></div><div><dt>Fixed category</dt><dd>{category}</dd></div><div><dt>Business allocation</dt><dd>{allocationText(allocation)}</dd></div><div><dt>Amount</dt><dd>{formatBDT(amount)}</dd></div><div><dt>Wallet</dt><dd>{source?.name}</dd></div><div><dt>Date</dt><dd>{date}</dd></div><div><dt>Description</dt><dd>{description}</dd></div></dl><p>This records money already {incoming ? 'received' : 'paid'} and {incoming ? 'credits' : 'deducts from'} the selected wallet once.</p>{notice}</PurchaseConfirmation>}</>;
}
