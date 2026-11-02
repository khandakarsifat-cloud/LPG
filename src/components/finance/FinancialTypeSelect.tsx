import { useId, useRef, useState } from 'react';
import { Check, ChevronDown } from 'lucide-react';
import { allocationText, financialCategoryLabel } from '../../lib/financial';
import type { FinancialType } from '../../types/financial';

export function FinancialTypeSelect({ value, types, onChange }: {
 value: string; types: FinancialType[]; onChange: (value: string) => void;
}) {
 const id = useId(); const trigger = useRef<HTMLButtonElement>(null);
 const [open, setOpen] = useState(false);
 const selected = types.find(type => type.type_id === value);
 const content = (type: FinancialType) => <span className="financial-type-content"><span className="financial-type-heading"><strong>{type.name}</strong><span>{financialCategoryLabel(type.account ?? '')}</span></span><span className="financial-type-split">{allocationText(type.allocations)}</span></span>;
 function focusOption(index: number) {
  document.getElementById(`${id}-option-${index}`)?.focus();
 }
 return <div className="input-group financial-type-select" onBlur={event => { if (!event.currentTarget.contains(event.relatedTarget)) setOpen(false); }} onKeyDown={event => {
  if (event.key === 'Escape' && open) { event.preventDefault(); event.stopPropagation(); setOpen(false); trigger.current?.focus(); }
 }}>
  <label className="input-label" id={`${id}-label`} htmlFor={id}>Type</label>
  <button ref={trigger} id={id} type="button" className="input-field financial-type-trigger" aria-labelledby={`${id}-label ${id}-value`} aria-haspopup="listbox" aria-expanded={open} aria-controls={open ? `${id}-options` : undefined} onClick={() => setOpen(!open)} onKeyDown={event => {
   if (event.key === 'ArrowDown' || event.key === 'ArrowUp') { event.preventDefault(); setOpen(true); requestAnimationFrame(() => focusOption(Math.max(0, types.findIndex(type => type.type_id === value)))); }
  }}><span id={`${id}-value`}>{selected ? content(selected) : 'Select…'}</span><ChevronDown size={18} aria-hidden="true" /></button>
  {open && <div id={`${id}-options`} role="listbox" aria-labelledby={`${id}-label`} className="financial-type-options" onKeyDown={event => {
   const index = types.findIndex((_, i) => `${id}-option-${i}` === document.activeElement?.id);
   let next: number;
   if (event.key === 'ArrowDown') next = (index + 1) % types.length;
   else if (event.key === 'ArrowUp') next = (index - 1 + types.length) % types.length;
   else if (event.key === 'Home') next = 0;
   else if (event.key === 'End') next = types.length - 1;
   else return;
   event.preventDefault(); focusOption(next);
  }}>{types.map((type, index) => <button key={type.type_id} id={`${id}-option-${index}`} type="button" role="option" aria-selected={value === type.type_id} className="financial-type-option" onClick={() => { onChange(type.type_id); setOpen(false); trigger.current?.focus(); }}>{content(type)}{value === type.type_id && <Check size={18} aria-hidden="true" />}</button>)}{types.length === 0 && <p className="finance-note">No active financial types.</p>}</div>}
 </div>;
}

