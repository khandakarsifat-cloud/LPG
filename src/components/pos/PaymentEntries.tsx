import { Plus, Trash2 } from 'lucide-react';
import { paymentDraft, paymentMethodLabel, validatePayments } from '../../lib/payments';
import { formatBDT } from '../../lib/formatBDT';
import type { PaymentDraft, PaymentWallet } from '../../types/finance';
import './payments.css';

export function PaymentEntries({ entries, onChange, wallets, total, disabled = false, refund = false }: {
  entries: PaymentDraft[]; onChange: (entries: PaymentDraft[]) => void; wallets: PaymentWallet[]; total: number; disabled?: boolean;
  refund?: boolean;
}) {
  const validation = validatePayments(entries, total, wallets);
  const update = (id: string, change: Partial<PaymentDraft>) => onChange(entries.map(entry => entry.id === id ? { ...entry, ...change } : entry));
  const system = wallets.filter(w => w.type !== 'custom'); const custom = wallets.filter(w => w.type === 'custom');
  return <div className="payment-editor">
    {entries.map((entry, index) => <div className="payment-entry" key={entry.id}>
      <label className="payment-wallet"><span>Wallet</span><select className="input-field" aria-label={`Payment ${index + 1} wallet`} value={entry.wallet_id} disabled={disabled} onChange={e => update(entry.id, { wallet_id: e.target.value })}>
        <option value="" disabled>Select wallet</option>
        {system.map(w => <option key={w.wallet_id} value={w.wallet_id}>{paymentMethodLabel[w.kind]} · {w.name}</option>)}
        {custom.length > 0 && <optgroup label="Other wallets">{custom.map(w => <option key={w.wallet_id} value={w.wallet_id}>{w.name} ({paymentMethodLabel[w.kind]})</option>)}</optgroup>}
      </select></label>
      <label className="payment-amount"><span>Amount (Tk)</span><input className="input-field" aria-label={`Payment ${index + 1} amount`} inputMode="decimal" value={entry.amount} disabled={disabled} onChange={e => { if (/^\d*(\.\d{0,2})?$/.test(e.target.value)) update(entry.id, { amount: e.target.value }); }} /></label>
      <button type="button" className="btn btn-ghost payment-remove" aria-label={`Remove payment ${index + 1}`} disabled={disabled} onClick={() => onChange(entries.filter(p => p.id !== entry.id))}><Trash2 size={16} /></button>
      {wallets.find(w => w.wallet_id === entry.wallet_id)?.kind !== 'cash' && <input className="input-field payment-reference" aria-label={`Payment ${index + 1} reference`} placeholder="Transaction reference (optional)" maxLength={200} value={entry.reference} disabled={disabled} onChange={e => update(entry.id, { reference: e.target.value })} />}
    </div>)}
    {!entries.length && <p className="payment-hint">{refund ? 'Add the refund amounts actually received.' : 'No payment now. The full amount remains due.'}</p>}
    <div className="payment-actions"><button type="button" className="btn btn-secondary" disabled={disabled || !wallets.length || entries.length >= 20} onClick={() => onChange([...entries, paymentDraft(wallets, Math.max(0, validation.due))])}><Plus size={14} />{refund ? 'Add refund' : 'Add payment'}</button>{entries.length > 0 && <button type="button" className="btn btn-ghost" disabled={disabled} onClick={() => onChange([])}>{refund ? 'Clear amounts' : 'No payment now'}</button>}</div>
    <dl className="payment-totals"><div><dt>Total</dt><dd>{formatBDT(total)}</dd></div><div><dt>{refund ? 'Refund now' : 'Paid'}</dt><dd>{formatBDT(validation.paid)}</dd></div><div className={validation.due > 0 ? 'payment-due' : ''}><dt>Remaining due</dt><dd>{formatBDT(Math.max(0, validation.due))}</dd></div></dl>
    {validation.error && <p className="payment-error" role="alert">{validation.error}</p>}
  </div>;
}
