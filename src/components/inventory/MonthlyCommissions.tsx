import type { MonthlyCommission, ProductInventory } from '../../types/inventory';
import { OperationalPrices } from './OperationalPrices';
import './product-details.css';
import { useState } from 'react';
import toast from 'react-hot-toast';
import { useMonthlyCommissions, useSetMonthlyCommission } from '../../hooks/useMonthlyCommissions';
import { dhakaToday } from '../../lib/businessDate';
import { formatBDT } from '../../lib/formatBDT';
import { Pagination } from '../ui/Pagination';
import { PurchaseDialog } from '../purchases/PurchaseControls';

export function MonthlyCommissions({ itemId, data, disabled }: { itemId: string; data: ProductInventory; disabled: boolean }) {
 const currentMonth = dhakaToday().slice(0, 7); const active = data.commission;
 const [month, setMonth] = useState(currentMonth); const [page, setPage] = useState(0); const [editing, setEditing] = useState<string | null>(null);
 const [historyOpen, setHistoryOpen] = useState(false);
 const q = useMonthlyCommissions(itemId, month, page);
 const monthLabel = (value: string) => new Date(`${value.slice(0, 7)}-01T12:00:00`).toLocaleDateString('en-BD', { month: 'long', year: 'numeric' });
 const canManage = data.can_manage_prices;
 return <section className="product-section monthly-commissions product-costing"><div className="product-section-heading"><h3>Commission & buying prices</h3><span className="product-approx">{active ? monthLabel(active.month) : 'Commission not set'}</span></div>
  <div className="commission-rates"><div><span>Package commission / unit</span><strong>{active ? formatBDT(active.package_rate) : 'Not set'}</strong></div><div><span>Refill commission / unit</span><strong>{active ? formatBDT(active.refill_rate) : 'Not set'}</strong></div><div className="commission-rate-action"><small>{active?.source === 'manual' ? 'Custom rates' : active ? 'Automatic · invoice prices' : ''}</small>{canManage && <button className="btn btn-secondary" disabled={disabled} onClick={() => { setMonth(currentMonth); setPage(0); setEditing(currentMonth); }}>Set monthly rates</button>}</div></div>
  <OperationalPrices itemId={itemId} data={data} disabled={disabled} />
  <details className="operational-price-history commission-history-panel" onToggle={e => setHistoryOpen(e.currentTarget.open)}><summary>Commission history</summary>
   {historyOpen && <><div className="commission-history-controls"><label className="input-group"><span className="input-label">History month</span><input aria-label="Commission month" className="input-field" type="month" value={month} max={currentMonth} onChange={e => { if (e.target.value) { setMonth(e.target.value); setPage(0); } }} /></label>{canManage && <button className="btn btn-secondary" disabled={!q.data || disabled} onClick={() => setEditing(month)}>Edit selected month</button>}</div>
    {q.isPending && <p role="status">Loading commission history…</p>}{q.error && <p className="payment-error" role="alert">{q.error.message}<button className="btn btn-secondary" onClick={() => void q.refetch()}>Retry</button></p>}
    {q.data && <><div className="commission-history">{q.data.entries.map(e => <article key={e.history_id}><header><strong>{e.source === 'manual' ? 'Custom rates' : 'Automatic rates'}</strong><time>{new Date(e.modified_at).toLocaleString('en-BD', { timeZone: 'Asia/Dhaka', dateStyle: 'medium', timeStyle: 'short' })}</time></header><div><span>Package <b>{formatBDT(e.package_rate)}</b></span><span>Refill <b>{formatBDT(e.refill_rate)}</b></span></div><small>{e.actor}</small></article>)}</div>{q.data.total === 0 && <p className="finance-note">No commission changes for this month.</p>}<Pagination page={page} pageSize={10} total={q.data.total} onChange={setPage} label="commission changes" /></>}
   </>}
  </details>
  {editing && (q.isPending || month !== editing) && <p role="status">Loading saved rates…</p>}
  {editing && q.error && <p role="alert" className="payment-error">{q.error.message}<button className="btn btn-secondary" onClick={() => void q.refetch()}>Retry</button></p>}
  {editing && month === editing && q.data && <CommissionForm key={`${editing}`} itemId={itemId} month={editing} current={q.data.current ?? (editing === currentMonth ? active : null)} expectedVersion={q.data.current?.revision ?? 0} onClose={() => setEditing(null)} onReload={async () => { const r = await q.refetch(); return r.data?.current ?? null; }} />}
 </section>;
}
function CommissionForm({ itemId, month, current, expectedVersion, onClose, onReload }: { itemId: string; month: string; current: MonthlyCommission | null; expectedVersion: number; onClose: () => void; onReload: () => Promise<MonthlyCommission | null> }) {
 const [packageRate, setPackage] = useState(current ? String(current.package_rate) : ''); const [refillRate, setRefill] = useState(current ? String(current.refill_rate) : '');
 const [version, setVersion] = useState(expectedVersion); const save = useSetMonthlyCommission();
 const valid = [packageRate, refillRate].every(s => s !== '' && Number.isFinite(Number(s)) && Number(s) >= 0 && Number(s) < 10000000000);
 return <PurchaseDialog title="Set monthly commission" subtitle={new Date(`${month}-01T12:00:00`).toLocaleDateString('en-BD', { month: 'long', year: 'numeric' })} onClose={onClose} busy={save.isPending} compact className="commission-dialog"><form onSubmit={async e => { e.preventDefault(); if (!valid) return; try { await save.mutateAsync({ item_id: itemId, month: `${month}-01`, package_rate: Number(packageRate), refill_rate: Number(refillRate), expected_revision: version }); toast.success('Monthly commission saved'); onClose(); } catch { /* Preserve uncertain-result recovery. */ } }}>
  <div className="modal-body dialog-form"><div className="commission-fields">{([{ label: 'Package commission (Tk)', value: packageRate, set: setPackage }, { label: 'Refill commission (Tk)', value: refillRate, set: setRefill }]).map(f => <label className="input-group" key={f.label}><span className="input-label">{f.label}</span><input className="input-field" inputMode="decimal" required value={f.value} disabled={save.isPending || save.hasPending} onChange={e => { if (/^\d*(\.\d{0,6})?$/.test(e.target.value)) f.set(e.target.value); }} /></label>)}</div>
   <p className="finance-note">Replaces this month’s rates and records the change in history.</p>{save.error && <p className="payment-error" role="alert">{save.error.message}</p>}{save.hasPending && <button type="button" className="btn btn-secondary" disabled={save.isPending} onClick={() => void save.mutateAsync(undefined).then(onClose).catch(() => {})}>Recover commission save</button>}
  </div><div className="modal-footer"><button type="button" className="btn btn-secondary" disabled={save.isPending} onClick={onClose}>Cancel</button><button type="button" className="btn btn-ghost" disabled={save.isPending || save.hasPending} onClick={() => void onReload().then(r => { setVersion(r?.revision ?? 0); setPackage(r ? String(r.package_rate) : ''); setRefill(r ? String(r.refill_rate) : ''); })}>Reload saved rates</button><button className="btn btn-primary" disabled={!valid || save.isPending || save.hasPending}>Save monthly rates</button></div>
 </form></PurchaseDialog>;
}
