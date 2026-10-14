import { useEffect, useId, useRef, useState, type ReactNode } from 'react';
import { createPortal } from 'react-dom';
import { ChevronDown, Check, X } from 'lucide-react';
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

// Searchable combobox: arrow/Home/End navigation, Enter selection, Escape close,
// labelled listbox and active descendant. No extra component library needed.
export function PurchaseSelect({ label, value, options, placeholder = 'Select…', onChange }: {
  label: string; value: string; options: SelectionOption[]; placeholder?: string; onChange: (value: string) => void;
}) {
  const id = useId();
  const root = useRef<HTMLDivElement>(null);
  const [open, setOpen] = useState(false);
  const [search, setSearch] = useState('');
  const [active, setActive] = useState(0);
  const selected = options.find(option => option.value === value);
  const matches = options.filter(option => `${option.label} ${option.description ?? ''}`.toLowerCase().includes(search.toLowerCase()));
  const select = (option: SelectionOption) => { onChange(option.value); setOpen(false); setSearch(''); };
  useEffect(() => {
    if (open) root.current?.querySelector('[aria-selected="true"]')?.scrollIntoView({ block: 'nearest' });
  }, [active, open]);
  return <div ref={root} className="purchase-select input-group" onBlur={event => {
    if (!event.currentTarget.contains(event.relatedTarget)) { setOpen(false); setSearch(''); }
  }}>
    <label className="input-label" htmlFor={id}>{label}</label>
    <div className="purchase-select-control">
      <input id={id} className="input-field" role="combobox" aria-autocomplete="list" aria-expanded={open}
        aria-controls={`${id}-options`} aria-activedescendant={open && matches.length ? `${id}-option-${Math.min(active, matches.length - 1)}` : undefined}
        autoComplete="off" placeholder={placeholder} value={open ? search : selected?.label ?? ''}
        onFocus={() => { setSearch(''); setActive(0); setOpen(true); }}
        onChange={event => { setSearch(event.target.value); setActive(0); setOpen(true); }}
        onKeyDown={event => {
          if (event.key === 'Escape' && open) { event.preventDefault(); event.stopPropagation(); setOpen(false); }
          else if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
            event.preventDefault(); setOpen(true);
            setActive(index => Math.max(0, Math.min(matches.length - 1, index + (event.key === 'ArrowDown' ? 1 : -1))));
          } else if (event.key === 'Home' && open) { event.preventDefault(); setActive(0); }
          else if (event.key === 'End' && open) { event.preventDefault(); setActive(Math.max(0, matches.length - 1)); }
          else if (event.key === 'Enter') { event.preventDefault(); if (open && matches[active]) select(matches[active]); }
        }} />
      <ChevronDown size={16} aria-hidden="true" />
    </div>
    {open && <div id={`${id}-options`} role="listbox" aria-label={label} className="purchase-select-menu">
      {matches.length ? matches.map((option, index) => <div key={option.value} id={`${id}-option-${index}`}
        role="option" aria-selected={index === active} className={`purchase-select-option${index === active ? ' active' : ''}`}
        onMouseDown={event => event.preventDefault()} onClick={() => select(option)} onMouseMove={() => setActive(index)}>
        <div><strong>{option.label}</strong>{option.description && <small>{option.description}</small>}</div>
        {value === option.value && <Check size={16} aria-label="Selected" />}
      </div>) : <p className="purchase-hint">No matching options.</p>}
    </div>}
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
