import { validAllocation } from '../../lib/financial';
import { businessLines, businessNames } from '../../types/financial';
import type { BusinessAllocation } from '../../types/financial';
import './business-allocation.css';

export function BusinessAllocationEditor({ value, onChange, disabled = false }: { value: BusinessAllocation; onChange: (value: BusinessAllocation) => void; disabled?: boolean }) {
 const total = Object.values(value).reduce((sum, n) => sum + n, 0);
 return <fieldset className="business-allocation" disabled={disabled}><legend>Business allocation</legend><div>{businessLines.map(b => <label className="input-group" key={b}><span className="input-label">{businessNames[b]} (%)</span><input className="input-field" inputMode="decimal" value={value[b] ?? ''} onChange={e => {
  if (!/^\d*(\.\d{0,4})?$/.test(e.target.value)) return;
  const next = { ...value }; if (!e.target.value || Number(e.target.value) === 0) delete next[b]; else next[b] = Number(e.target.value); onChange(next);
 }} /></label>)}</div><p className={validAllocation(value) ? 'finance-note' : 'payment-error'} role="status">Total: {Number(total.toFixed(4))}% · Must equal 100%.</p></fieldset>;
}
