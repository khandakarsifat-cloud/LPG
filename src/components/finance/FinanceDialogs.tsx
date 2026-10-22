import { useState } from 'react';
import toast from 'react-hot-toast';
import { PurchaseDialog } from '../purchases/PurchaseControls';
import { useFinanceOperation, useSaveFinanceWallet } from '../../hooks/useFinance';
import { formatBDT } from '../../lib/formatBDT';
import { paymentMethodLabel } from '../../lib/payments';
import type { FinanceWallet, WalletKind } from '../../types/finance';

export function WalletDialog({ wallet, onClose }: { wallet?: FinanceWallet; onClose: () => void }) {
  const save = useSaveFinanceWallet(); const [name, setName] = useState(wallet?.name ?? '');
  const [kind, setKind] = useState<WalletKind>(wallet?.kind ?? 'bank'); const [details, setDetails] = useState(wallet?.details ?? '');
  const [active, setActive] = useState(wallet?.is_active ?? true);
  return <PurchaseDialog title={wallet ? 'Manage wallet' : 'Add wallet'} onClose={onClose} busy={save.isPending} compact>
    <form onSubmit={async e => { e.preventDefault(); try { await save.mutateAsync({ wallet_id: wallet?.wallet_id, revision: wallet?.revision, name, kind, details, is_active: active }); toast.success('Wallet saved'); onClose(); } catch { /* inline error */ } }}>
      <div className="modal-body finance-form">
        <label className="input-group"><span className="input-label">Wallet name</span><input className="input-field" required maxLength={80} value={name} onChange={e => setName(e.target.value)} disabled={save.isPending} /></label>
        <label className="input-group"><span className="input-label">Category</span><select aria-label="Category" className="input-field" value={kind} onChange={e => setKind(e.target.value as WalletKind)} disabled={Boolean(wallet) || save.isPending}>{Object.entries(paymentMethodLabel).filter(([value]) => value !== 'logistics' || wallet?.kind === 'logistics').map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></label>
        <label className="input-group"><span className="input-label">Details (optional)</span><textarea className="input-field" maxLength={500} placeholder="Bank or account details for your team" value={details} onChange={e => setDetails(e.target.value)} disabled={save.isPending} /></label>
        {wallet && <p className="finance-note">Balance: {formatBDT(Number(wallet.balance))}<br />Historical reconciliation baseline: {formatBDT(Number(wallet.opening_balance))}</p>}
        {wallet?.type === 'custom' && <label className="finance-check"><input type="checkbox" checked={active} onChange={e => setActive(e.target.checked)} disabled={save.isPending} />Active wallet</label>}
        <p className="finance-note">Wallet history is retained. Custom wallets with a zero balance can be archived. Default wallets stay active.</p>
        {save.error && <p className="payment-error" role="alert">{save.error.message}</p>}
      </div><div className="modal-footer"><button type="button" className="btn btn-secondary" disabled={save.isPending} onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={save.isPending || !name.trim()}>{save.isPending ? 'Saving…' : 'Save wallet'}</button></div>
    </form>
  </PurchaseDialog>;
}

export function MoneyDialog({ action, wallets, initialWallet, onClose }: { action: 'transfer' | 'adjustment'; wallets: FinanceWallet[]; initialWallet?: string; onClose: () => void }) {
  const operation = useFinanceOperation(); const active = wallets.filter(w => w.is_active);
  const [walletId, setWalletId] = useState(initialWallet ?? active[0]?.wallet_id ?? '');
  const [destination, setDestination] = useState(''); const [amount, setAmount] = useState(''); const [direction, setDirection] = useState('add'); const [reason, setReason] = useState('');
  const source = wallets.find(w => w.wallet_id === walletId);
  const valid = /^\d+(\.\d{1,2})?$/.test(amount) && Number(amount) > 0 && reason.trim().length >= 3 && (action !== 'transfer' || destination && destination !== walletId);
  const recover = async () => { try { await operation.mutateAsync(undefined); toast.success('Previous transaction confirmed'); onClose(); } catch { /* inline */ } };
  return <PurchaseDialog title={action === 'transfer' ? 'Transfer between wallets' : 'Adjust wallet balance'} onClose={onClose} busy={operation.isPending} compact>
    <form onSubmit={async e => { e.preventDefault(); try { await operation.mutateAsync({ action, wallet_id: walletId, ...(action === 'transfer' ? { destination_id: destination } : {}), amount: Number(amount) * (action === 'adjustment' && direction === 'subtract' ? -1 : 1), reason: reason.trim() }); toast.success(action === 'transfer' ? 'Transfer recorded' : 'Adjustment recorded'); onClose(); } catch { /* inline */ } }}>
      <div className="modal-body finance-form">
        {operation.hasPending && <div className="finance-recovery" role="alert">An earlier transaction needs confirmation.<button type="button" className="btn btn-secondary" disabled={operation.isPending} onClick={() => void recover()}>Recover transaction</button></div>}
        <label className="input-group"><span className="input-label">{action === 'transfer' ? 'From wallet' : 'Wallet'}</span><select aria-label={action === 'transfer' ? 'From wallet' : 'Wallet'} className="input-field" value={walletId} disabled={operation.isPending} onChange={e => setWalletId(e.target.value)}>{active.map(w => <option key={w.wallet_id} value={w.wallet_id}>{w.name}</option>)}</select></label>
        <p className="finance-note">Current balance: {formatBDT(Number(source?.balance ?? 0))}</p>
        {action === 'transfer' ? <label className="input-group"><span className="input-label">To wallet</span><select aria-label="To wallet" className="input-field" required value={destination} disabled={operation.isPending} onChange={e => setDestination(e.target.value)}><option value="" disabled>Select destination</option>{active.filter(w => w.wallet_id !== walletId).map(w => <option key={w.wallet_id} value={w.wallet_id}>{w.name}</option>)}</select></label> : <label className="input-group"><span className="input-label">Adjustment</span><select className="input-field" value={direction} disabled={operation.isPending} onChange={e => setDirection(e.target.value)}><option value="add">Add funds / opening balance</option><option value="subtract">Remove funds / correction</option></select></label>}
        <label className="input-group"><span className="input-label">Amount (Tk)</span><input className="input-field" inputMode="decimal" value={amount} disabled={operation.isPending} onChange={e => { if (/^\d*(\.\d{0,2})?$/.test(e.target.value)) setAmount(e.target.value); }} /></label>
        <label className="input-group"><span className="input-label">Reason / reference</span><textarea className="input-field" required minLength={3} maxLength={500} value={reason} disabled={operation.isPending} onChange={e => setReason(e.target.value)} /></label>
        {action === 'adjustment' && <p className="finance-note">Creates an attributed ledger entry. To correct an earlier entry, include its reference and record the opposite amount.</p>}
        {operation.error && <p className="payment-error" role="alert">{operation.error.message}</p>}
      </div><div className="modal-footer"><button type="button" className="btn btn-secondary" disabled={operation.isPending} onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={operation.isPending || operation.hasPending || !valid}>{operation.isPending ? 'Recording…' : action === 'transfer' ? 'Record transfer' : 'Record adjustment'}</button></div>
    </form>
  </PurchaseDialog>;
}
