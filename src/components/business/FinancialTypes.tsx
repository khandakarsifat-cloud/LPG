import { useState } from 'react';
import { useFinancialCatalog, useSaveFinancialType } from '../../hooks/useFinancialTypes';
import type { BusinessAllocation, FinancialType } from '../../types/financial';
import { PurchaseDialog, PurchaseSelect } from '../purchases/PurchaseControls';
import { BusinessAllocationEditor } from '../finance/BusinessAllocation';
import { allocationText, validAllocation, customCategoryOptions } from '../../lib/financial';

export function FinancialTypes() {
 const query = useFinancialCatalog(); const [editing, setEditing] = useState<FinancialType | 'new' | null>(null);
 return <section className="settings-section"><header className="settings-section-heading"><div><h2>Financial types</h2><p>Types identify activity. Fixed accounting categories determine its effect. Saved percentages allocate the amount automatically.</p></div><button className="btn btn-primary" onClick={() => setEditing('new')}>Add custom type</button></header>
  {query.isPending && <p role="status">Loading types…</p>}{query.error && <p role="alert" className="purchase-error">{query.error.message}<button className="btn btn-secondary" onClick={() => void query.refetch()}>Retry</button></p>}
  {query.data?.types.filter(t => t.origin === 'custom').map(t => <article className="settings-card spending-category" key={t.type_id}><div><strong>{t.name}</strong><p>{customCategoryOptions.find(c => c.value === t.account)?.label}{!t.is_active ? ' · Inactive' : ''}</p><small>{allocationText(t.allocations)}</small></div><button className="btn btn-secondary" onClick={() => setEditing(t)}>Edit {t.name}</button></article>)}
  <details className="settings-card"><summary>System types & fixed categories</summary><p className="finance-note">System operations assign their categories, businesses and source records automatically.</p>{query.data?.types.filter(t => t.origin === 'system').map(t => <p key={t.type_id}><strong>{t.name}</strong></p>)}<h3>Fixed accounting categories</h3>{customCategoryOptions.map(c => <p key={c.value}>{c.label}</p>)}</details>
  {editing && <TypeForm type={editing === 'new' ? undefined : editing} onClose={() => setEditing(null)} />}
 </section>;
}
function TypeForm({ type, onClose }: { type?: FinancialType; onClose: () => void }) {
 const [name, setName] = useState(type?.name ?? ''); const [account, setAccount] = useState(type?.account ?? 'operating_expense');
 const [allocations, setAllocations] = useState<BusinessAllocation>(type?.allocations ?? { lpg: 100 }); const [active, setActive] = useState(type?.is_active ?? true); const save = useSaveFinancialType();
 return <PurchaseDialog title={type ? 'Edit financial type' : 'Add custom financial type'} onClose={onClose} busy={save.isPending} compact><form onSubmit={e => { e.preventDefault(); void save.mutateAsync({ type_id: type?.type_id, revision: type?.revision, name, account, allocations, is_active: active }).then(onClose).catch(() => {}); }}><div className="modal-body dialog-form"><label className="input-group"><span className="input-label">Type name</span><input required maxLength={80} className="input-field" value={name} onChange={e => setName(e.target.value)} /></label>
  <PurchaseSelect label="Fixed accounting category" value={account} onChange={setAccount} options={customCategoryOptions} />
  <BusinessAllocationEditor value={allocations} onChange={setAllocations} disabled={save.isPending} />
  {type && <label><input type="checkbox" checked={active} onChange={e => setActive(e.target.checked)} /> Active for new entries</label>}
  <p className="finance-note">Changes apply to new transactions. Recorded category, name and business allocations stay with each historical entry.</p>{save.error && <p role="alert" className="purchase-error">{save.error.message}</p>}
 </div><div className="modal-footer"><button type="button" className="btn btn-secondary" disabled={save.isPending} onClick={onClose}>Back</button><button className="btn btn-primary" disabled={save.isPending || !name.trim() || !validAllocation(allocations)}>Save type</button></div></form></PurchaseDialog>;
}
