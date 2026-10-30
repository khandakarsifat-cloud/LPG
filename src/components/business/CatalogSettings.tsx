import { useState } from 'react';
import { Pencil, Plus } from 'lucide-react';
import { useBusinessCatalogs, useSaveBusinessCatalog, type BusinessRole, type BusinessWeight } from '../../hooks/useBusinessSettings';
import { PurchaseConfirmation, PurchaseDialog } from '../purchases/PurchaseControls';
import { Pagination } from '../ui/Pagination';

export function CatalogSettings({ kind }: { kind: 'role' | 'weight' }) {
 const query = useBusinessCatalogs(); const [edit, setEdit] = useState<BusinessRole | BusinessWeight | 'new' | null>(null); const [page, setPage] = useState(0);
 const records = kind === 'role' ? query.data?.roles ?? [] : query.data?.weights ?? [];
 const title = kind === 'role' ? 'Employee roles' : 'Cylinder weights';
 return <section className="settings-section"><header className="settings-section-heading"><div><h2>{title}</h2><p>{kind === 'role' ? 'Job titles for your business. These do not grant application access.' : 'Weight options used when adding inventory products. Existing products keep their weights.'}</p></div><button className="btn btn-primary" onClick={() => setEdit('new')}><Plus size={14} />{kind === 'role' ? 'Add role' : 'Add weight'}</button></header>
  {query.isPending && <p role="status">Loading {title.toLowerCase()}…</p>}{query.isError && <p role="alert" className="purchase-error">Catalog unavailable. <button className="btn btn-secondary" onClick={() => void query.refetch()}>Retry</button></p>}
  <div className="settings-card settings-catalog">{records.slice(page * 12, (page + 1) * 12).map(item => { const role = 'name' in item; return <article className="settings-catalog-row" key={role ? item.id : item.size_kg}><div><strong>{role ? item.name : `${item.size_kg} kg`}</strong><small>{item.assigned} {kind === 'role' ? 'employees' : 'products'}{role && item.system ? ' · Predefined' : ''}{!item.active ? ' · Disabled' : ''}</small></div>{(!role || !item.system) && <button className="btn btn-secondary" aria-label={`Edit ${role ? item.name : `${item.size_kg} kg`}`} onClick={() => setEdit(item)}><Pencil size={13} />Edit</button>}</article>; })}
   {!query.isPending && !records.length && <p>No options configured.</p>}
   <Pagination page={page} pageSize={12} total={records.length} onChange={setPage} label={title.toLowerCase()} />
  </div>
  {edit && <CatalogEditor kind={kind} item={edit === 'new' ? undefined : edit} onClose={() => setEdit(null)} />}
 </section>;
}
function CatalogEditor({ kind, item, onClose }: { kind: 'role' | 'weight'; item?: BusinessRole | BusinessWeight; onClose: () => void }) {
 const [name, setName] = useState(item ? 'name' in item ? item.name : String(item.size_kg) : ''); const [active, setActive] = useState(item?.active ?? true); const [removing, setRemoving] = useState(false); const operation = useSaveBusinessCatalog();
 const id = item ? 'name' in item ? item.id : String(item.size_kg) : null;
 const save = (remove = false) => operation.mutate({ kind, id, name, active, remove }, { onSuccess: onClose });
 return <PurchaseDialog title={`${item ? 'Edit' : 'Add'} ${kind === 'role' ? 'employee role' : 'weight'}`} onClose={onClose} busy={operation.isPending} compact>
  <form onSubmit={event => { event.preventDefault(); save(); }}><div className="modal-body attendance-form"><label>{kind === 'role' ? 'Role name' : 'Weight (kg)'}<input className="input-field" required maxLength={120} inputMode={kind === 'weight' ? 'decimal' : undefined} disabled={kind === 'weight' && !!item} value={name} onChange={event => setName(event.target.value)} /></label>
   <label className="attendance-check"><input type="checkbox" checked={active} onChange={event => setActive(event.target.checked)} />Available for new {kind === 'role' ? 'employee assignments' : 'products'}</label>
   {!!item?.assigned && <p className="employee-hint">Used by {item.assigned} {kind === 'role' ? 'employees' : 'products'}. Disable it to hide it from new selections; existing records are preserved.</p>}
   {operation.isError && <p role="alert" className="purchase-error">{operation.error.message}</p>}
  </div><div className="modal-footer">{item && <button type="button" className="btn btn-ghost" disabled={!!item.assigned || operation.isPending} onClick={() => setRemoving(true)}>Remove</button>}<button type="button" className="btn btn-secondary" disabled={operation.isPending} onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={operation.isPending || !name.trim()}>Save {kind}</button></div></form>
  {removing && <PurchaseConfirmation title={`Remove ${kind}?`} action="Remove" busy={operation.isPending} onCancel={() => setRemoving(false)} onConfirm={() => save(true)}><p>Remove <strong>{name}{kind === 'weight' ? ' kg' : ''}</strong> from this business?</p>{operation.isError && <p role="alert">{operation.error.message}</p>}</PurchaseConfirmation>}
 </PurchaseDialog>;
}
