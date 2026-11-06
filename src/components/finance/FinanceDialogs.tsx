import './finance-modals.css';
import { businessLines, businessNames } from '../../types/financial';
import type { BusinessLine } from '../../types/financial';
import { useState } from 'react';
import toast from 'react-hot-toast';
import { PurchaseDialog } from '../purchases/PurchaseControls';
import { useFinanceOperation, useSaveFinanceWallet } from '../../hooks/useFinance';
import { formatBDT } from '../../lib/formatBDT';
import { paymentMethodLabel } from '../../lib/payments';
import type { FinanceWallet, WalletKind } from '../../types/finance';
import { DatePicker } from '../ui/DatePicker';
import { dhakaToday } from '../../lib/businessDate';
import { useAuth } from '../../contexts/AuthContext';

export function WalletDialog({ wallet, onClose }: { wallet?: FinanceWallet; onClose: () => void }) {
  const save = useSaveFinanceWallet(); const [name, setName] = useState(wallet?.name ?? '');
  const [kind, setKind] = useState<WalletKind>(wallet?.kind ?? 'bank'); const [details, setDetails] = useState(wallet?.details ?? '');
  const [active, setActive] = useState(wallet?.is_active ?? true);
  return <PurchaseDialog className="finance-operation-dialog" title={wallet ? 'Manage wallet' : 'Add wallet'} onClose={onClose} busy={save.isPending} compact>
    <form onSubmit={async e => { e.preventDefault(); try { await save.mutateAsync({ wallet_id: wallet?.wallet_id, revision: wallet?.revision, name, kind, details, is_active: active }); toast.success('Wallet saved'); onClose(); } catch { /* inline error */ } }}>
      <div className="modal-body dialog-form">
        <label className="input-group"><span className="input-label">Wallet name</span><input className="input-field" required maxLength={80} value={name} onChange={e => setName(e.target.value)} disabled={save.isPending} /></label>
        <label className="input-group"><span className="input-label">Category</span><select aria-label="Category" className="input-field" value={kind} onChange={e => setKind(e.target.value as WalletKind)} disabled={Boolean(wallet) || save.isPending}>{Object.entries(paymentMethodLabel).map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></label>
        <label className="input-group"><span className="input-label">Details (optional)</span><textarea className="input-field" maxLength={500} placeholder="Bank or account details for your team" value={details} onChange={e => setDetails(e.target.value)} disabled={save.isPending} /></label>
        {wallet && <p className="finance-note">Balance: {formatBDT(Number(wallet.balance))}<br />Historical reconciliation baseline: {formatBDT(Number(wallet.opening_balance))}</p>}
        {wallet?.type === 'custom' && <label className="finance-check"><input type="checkbox" checked={active} onChange={e => setActive(e.target.checked)} disabled={save.isPending || !!wallet && wallet.is_active && Number(wallet.balance) !== 0} />Active wallet</label>}
        <p className="finance-note">Wallet history is retained. A custom wallet can be archived when its balance is zero. Default wallets stay active.</p>
        {save.error && <p className="payment-error" role="alert">{save.error.message}</p>}
      </div><div className="modal-footer"><button type="button" className="btn btn-secondary" disabled={save.isPending} onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={save.isPending || !name.trim()}>{save.isPending ? 'Saving…' : 'Save wallet'}</button></div>
    </form>
  </PurchaseDialog>;
}

export function MoneyDialog({ action, wallets, initialWallet, onClose, onManageRecords }: { action: 'transfer' | 'adjustment'; wallets: FinanceWallet[]; initialWallet?: string; onClose: () => void; onManageRecords?: () => void }) {
  const {can}=useAuth(); const operation = useFinanceOperation(); const active = wallets.filter(w => w.is_active && w.can_use);
  const [walletId, setWalletId] = useState(initialWallet ?? active[0]?.wallet_id ?? '');
  const [business, setBusiness] = useState<BusinessLine>('lpg');
  const [destination, setDestination] = useState(''); const [amount, setAmount] = useState(''); const [direction, setDirection] = useState('add'); const [reason, setReason] = useState('');
  const [classification, setClassification] = useState<'correction' | 'capital'>(can('wallets:adjust')?'correction':'capital'); const [day, setDay] = useState(dhakaToday());
  const source = wallets.find(w => w.wallet_id === walletId);
  const valid = /^\d+(\.\d{1,2})?$/.test(amount) && Number(amount) > 0 && reason.trim().length >= 3 && !!walletId && (action !== 'transfer' || destination && destination !== walletId);
  const recover = async () => { try { await operation.mutateAsync(undefined); toast.success('Previous transaction confirmed'); onClose(); } catch { /* inline */ } };
  return <PurchaseDialog className="finance-operation-dialog" title={action === 'transfer' ? 'Transfer between wallets' : 'Adjust wallet balance'} onClose={onClose} busy={operation.isPending} compact>
    <form onSubmit={async e => { e.preventDefault(); try { await operation.mutateAsync({ action, wallet_id: walletId, ...(action === 'adjustment' ? { business } : {}), ...(action === 'transfer' ? { destination_id: destination } : { classification, date: day }), amount: Number(amount) * (action === 'adjustment' && classification === 'correction' && direction === 'subtract' ? -1 : 1), reason: reason.trim() }); toast.success(action === 'transfer' ? 'Transfer recorded' : 'Adjustment recorded'); onClose(); } catch { /* inline */ } }}>
      <div className="modal-body dialog-form">
        <p className="finance-note">Wallet balance: {source?.can_balance?formatBDT(Number(source.balance)):'Hidden'}</p>
        {operation.hasPending && <div className="finance-recovery" role="alert">An earlier transaction needs confirmation.<button type="button" className="btn btn-secondary" disabled={operation.isPending} onClick={() => void recover()}>Recover transaction</button></div>}
        <label className="input-group"><span className="input-label">{action === 'transfer' ? 'From wallet' : 'Wallet'}</span><select aria-label={action === 'transfer' ? 'From wallet' : 'Wallet'} className="input-field" value={walletId} disabled={operation.isPending} onChange={e => setWalletId(e.target.value)}>{active.map(w => <option key={w.wallet_id} value={w.wallet_id}>{w.name}</option>)}</select></label>
        {action === 'adjustment' && <label className="input-group"><span className="input-label">Source business</span><select className="input-field" aria-label="Source business" value={business} onChange={e => { const b = businessLines.find(b => b === e.target.value); if (b) setBusiness(b); }}>{businessLines.map(b => <option key={b} value={b}>{businessNames[b]}</option>)}</select></label>}
        {action === 'adjustment' && <><label className="input-group"><span className="input-label">Purpose</span><select aria-label="Purpose" className="input-field" value={classification} disabled={operation.isPending} onChange={e => { const v=e.target.value; if(v==='correction'||v==='capital') setClassification(v); }}>{can('wallets:adjust')&&<option value="correction">Balance correction</option>}{can('finance:capital') && <><option value="capital">Capital contribution</option></>}</select></label><DatePicker label="Accounting date" value={day} max={dhakaToday()} onChange={setDay} /></>}
        {action === 'transfer' ? <label className="input-group"><span className="input-label">To wallet</span><select aria-label="To wallet" className="input-field" required value={destination} disabled={operation.isPending} onChange={e => setDestination(e.target.value)}><option value="" disabled>Select destination</option>{active.map(w => <option key={w.wallet_id} value={w.wallet_id}>{w.name}</option>)}</select></label> : classification === 'correction' ? <label className="input-group"><span className="input-label">Adjustment</span><select aria-label="Adjustment" className="input-field" value={direction} disabled={operation.isPending} onChange={e => setDirection(e.target.value)}><option value="add">Increase recorded balance</option><option value="subtract">Decrease recorded balance</option></select></label> : null}
        <label className="input-group"><span className="input-label">Amount (Tk)</span><input className="input-field" inputMode="decimal" value={amount} disabled={operation.isPending} onChange={e => { if (/^\d*(\.\d{0,2})?$/.test(e.target.value)) setAmount(e.target.value); }} /></label>
        <label className="input-group"><span className="input-label">Reason / reference</span><textarea className="input-field" required minLength={3} maxLength={500} value={reason} disabled={operation.isPending} onChange={e => setReason(e.target.value)} /></label>
        {action === 'adjustment' && <><p className="finance-note">Adds one entry to the wallet ledger. Capital contributions include initial funds and later owner investments; they increase capital. Balance corrections do not create trading income. Enter only amounts missing from the recorded balance.</p>{onManageRecords && <button type="button" className="btn btn-secondary" disabled={operation.isPending || operation.hasPending} onClick={onManageRecords}>Other assets & balances</button>}</>}
        {operation.error && <p className="payment-error" role="alert">{operation.error.message}</p>}
      </div><div className="modal-footer"><button type="button" className="btn btn-secondary" disabled={operation.isPending} onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={operation.isPending || operation.hasPending || !valid}>{operation.isPending ? 'Recording…' : action === 'transfer' ? 'Record transfer' : 'Record adjustment'}</button></div>
    </form>
  </PurchaseDialog>;
}
