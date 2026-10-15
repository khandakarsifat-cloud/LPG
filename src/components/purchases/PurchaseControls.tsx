import { useEffect, useId, useRef, useState, type ReactNode } from 'react';
import { createPortal } from 'react-dom';
import { X } from 'lucide-react';
import { formatBDNumber, formatBDQty, formatBDT } from '../../lib/formatBDT';
import type { Purchase, PurchaseDraft } from '../../types/purchase';
import { PURCHASE_STATUS_BG, PURCHASE_STATUS_COLORS, PURCHASE_STATUS_LABELS } from '../../types/purchase';

export function PurchaseDialog({ title, subtitle, children, onClose, busy = false, compact = false }: {
  title: string; subtitle?: string; children: ReactNode; onClose: () => void; busy?: boolean; compact?: boolean;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  const titleId = useId();
  useEffect(() => {
    const dialog = ref.current;
    dialog?.showModal();
    const previous = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    return () => { dialog?.close(); document.body.style.overflow = previous; };
  }, []);
  return createPortal(<dialog ref={ref} className={`purchase-dialog${compact ? ' purchase-dialog-compact' : ''}`}
    aria-labelledby={titleId} onCancel={event => { event.preventDefault(); if (!busy) onClose(); }}>
    <div className="modal-header">
      <div><h2 id={titleId} className="modal-title">{title}</h2>{subtitle && <p className="modal-subtitle">{subtitle}</p>}</div>
      <button type="button" className="modal-close" aria-label="Close dialog" onClick={onClose} disabled={busy}><X size={20} /></button>
    </div>
    {children}
  </dialog>, document.body);
}

export function PurchaseConfirmation({ title, children, action, busy, onCancel, onConfirm }: {
  title: string; children: ReactNode; action: string; busy: boolean; onCancel: () => void; onConfirm: () => void;
}) {
  return <PurchaseDialog title={title} onClose={onCancel} busy={busy} compact>
    <div className="modal-body purchase-confirmation">{children}</div>
    <div className="modal-footer">
      <button className="btn btn-secondary" disabled={busy} onClick={onCancel}>Go back</button>
      <button className="btn btn-primary" disabled={busy} onClick={onConfirm}>{busy ? 'Saving…' : action}</button>
    </div>
  </PurchaseDialog>;
}

export interface SelectionOption { value: string; label: string; description?: string }

// Native selects keep fixed options non-editable and provide keyboard/typeahead support.
export function PurchaseSelect({ label, value, options, placeholder = 'Select…', onChange }: {
  label: string; value: string; options: SelectionOption[]; placeholder?: string; onChange: (value: string) => void;
}) {
  const id = useId();
  return <div className="purchase-select input-group">
    <label className="input-label" htmlFor={id}>{label}</label>
    <select id={id} className="input-field" value={value} onChange={event => onChange(event.target.value)}>
      {!options.some(option => option.value === '') && !options.some(option => option.value === value) && <option value="" disabled>{placeholder}</option>}
      {options.map(option => <option key={option.value} value={option.value}>
        {option.label}{option.description ? ` — ${option.description}` : ''}
      </option>)}
    </select>
  </div>;
}

export function PurchaseNumber({ label, value, onChange, money = false, hint }: {
  label: string; value: number | null; onChange: (value: number | null) => void; money?: boolean; hint?: string;
}) {
  const id = useId();
  const [text, setText] = useState<string | null>(null);
  return <div className="input-group">
    <label className="input-label" htmlFor={id}>{label}</label>
    <input id={id} className="input-field purchase-number" type="text" inputMode={money ? 'decimal' : 'numeric'}
      autoComplete="off" placeholder={money ? '0.00' : '0'} value={text ?? (value === null ? '' : money ? formatBDNumber(value) : formatBDQty(value))}
      onFocus={event => event.currentTarget.select()}
      onBlur={() => setText(null)} onChange={event => {
        const next = event.target.value.replaceAll(',', '');
        if ((money ? /^\d*(\.\d{0,2})?$/ : /^\d*$/).test(next)) {
          setText(next); onChange(next === '' || next === '.' ? null : Number(next));
        }
      }} />
    {hint && <span className="purchase-hint">{hint}</span>}
  </div>;
}

export function PurchaseStatuses({ purchase }: { purchase: Pick<Purchase, 'status' | 'payment_status'> }) {
  return <div className="purchase-statuses">
    <span className="purchase-badge" style={{ background: PURCHASE_STATUS_BG[purchase.status], color: PURCHASE_STATUS_COLORS[purchase.status] }}>
      {PURCHASE_STATUS_LABELS[purchase.status]}</span>
    <span className={`purchase-badge payment-${purchase.payment_status}`}>{purchase.payment_status === 'paid' ? 'Paid' : 'Unpaid'}</span>
  </div>;
}

export function PurchaseFinancials({ draft, totals, onChange }: {
  draft: PurchaseDraft; totals: { subtotal: number; company_payable: number; total_cost: number };
  onChange?: (draft: PurchaseDraft) => void;
}) {
  return <section className="purchase-section"><h3>Financial breakdown</h3>
    <div className="purchase-financial-grid">
      {onChange && <div className="purchase-cost-fields">
        <PurchaseNumber label="Commission (Tk)" value={draft.commission} money onChange={n => onChange({ ...draft, commission: n ?? 0 })} hint="Company discount" />
        <PurchaseNumber label="Transport cost (Tk)" value={draft.transport_cost} money onChange={n => onChange({ ...draft, transport_cost: n ?? 0 })} />
        <PurchaseNumber label="Labour cost (Tk)" value={draft.labour_cost} money onChange={n => onChange({ ...draft, labour_cost: n ?? 0 })} />
      </div>}
      <dl className="purchase-totals">
        <div><dt>Product subtotal</dt><dd>{formatBDT(totals.subtotal)}</dd></div>
        <div><dt>Commission</dt><dd>− {formatBDT(draft.commission)}</dd></div>
        <div className="purchase-payable"><dt>Company payable</dt><dd>{formatBDT(totals.company_payable)}</dd></div>
        <div><dt>Transport cost</dt><dd>{formatBDT(draft.transport_cost)}</dd></div>
        <div><dt>Labour cost</dt><dd>{formatBDT(draft.labour_cost)}</dd></div>
        <div className="purchase-total"><dt>Total purchase cost</dt><dd>{formatBDT(totals.total_cost)}</dd></div>
      </dl>
    </div>
  </section>;
}
