import { useListPage } from '../../hooks/useListPage';
import { Pagination } from '../ui/Pagination';
import { useState } from 'react';
import { Plus, Save, Trash2 } from 'lucide-react';
import toast from 'react-hot-toast';
import { useAuth } from '../../contexts/AuthContext';
import { useUpdateTransitCosts, useTransitionTransit } from '../../hooks/useLogistics';
import { PurchaseConfirmation, PurchaseDialog, PurchaseNumber } from '../purchases/PurchaseControls';
import { formatBDT } from '../../lib/formatBDT';
import { transitStatus, type Transit } from '../../types/logistics';
import '../purchases/purchases.css';
import { OperatingPayments } from './OperatingPayments';
import { useVehicleExpenseCategories } from '../../hooks/useVehicleAccounting';
import { useTransitPayroll } from '../../hooks/useEmployees';
import { TransitEmployeePayButton } from '../employees/TransitEmployeePayments';
const transitDraft = (transit: Transit) => ({ driverCost: Number(transit.driver_cost), helperCost: Number(transit.helper_cost),
  oilCost: Number(transit.oil_cost), othersCost: Number(transit.others_cost ?? 0), additionalCosts: transit.additional_costs ?? [] });
export function TransitCostsModal({ open, onClose, transit }: { open: boolean; onClose: () => void; transit: Transit }) {
  return open ? <TransitDetails key={transit.transit_id} onClose={onClose} transit={transit} /> : null;
}
function TransitDetails({ onClose, transit }: { onClose: () => void; transit: Transit }) {
  const { can } = useAuth();
  const cats=useVehicleExpenseCategories();
  const update = useUpdateTransitCosts();
  const transition = useTransitionTransit();
  const payroll = useTransitPayroll(transit.transit_id);
  const remainingCost = Math.max(0, Number(transit.total_cost) - Number(transit.driver_cost) - Number(transit.helper_cost));
  const crewOutstanding = Math.max(0, Number(transit.driver_cost) - (payroll.data?.driver_paid ?? 0)) + Math.max(0, Number(transit.helper_cost) - (payroll.data?.helper_paid ?? 0));
  const outstanding=crewOutstanding+Math.max(0,remainingCost-Number(transit.operating_paid));
  const [saveReview,setSaveReview]=useState(false);
  const [draft, setDraft] = useState(() => transitDraft(transit));
  const costPages = useListPage(draft.additionalCosts, 6, transit.transit_id);
  const [draftRevision, setDraftRevision] = useState(transit.revision);
  const [baseline, setBaseline] = useState(() => JSON.stringify(transitDraft(transit)));
  const [error, setError] = useState<string | null>(null);
  const [confirm, setConfirm] = useState<'complete' | 'cancel' | 'return' | null>(null);
  const busy = update.isPending || transition.isPending;
  const locked = !!transit.closed_at || !can('logistics:manage');
  const dirty = JSON.stringify(draft) !== baseline;
  const total = ([draft.driverCost, draft.helperCost, draft.oilCost, draft.othersCost, ...draft.additionalCosts.map(c => c.amount)]
    .reduce((sum, n) => sum + Math.round(n * 100), 0)) / 100;
  const label = transitStatus(transit);
  function loadSaved() {
    const saved = transitDraft(transit);
    setDraft(saved); setBaseline(JSON.stringify(saved)); setDraftRevision(transit.revision); setError(null);
  }
  if (draftRevision !== transit.revision && !dirty) loadSaved();
  async function save() {
    setError(null);
    if (draft.additionalCosts.some(c => !c.name.trim())) { setError('Name each additional cost or remove its row.'); return; }
    try {
      await update.mutateAsync({ transitId: transit.transit_id, revision: draftRevision, ...draft });
      setBaseline(JSON.stringify(draft));
      toast.success('Transit costs saved'); setSaveReview(false);
    } catch (cause) { setError(cause instanceof Error ? cause.message : 'Costs could not be saved.'); }
  }
  async function act() {
    if (!confirm) return;
    try {
      await transition.mutateAsync({ transitId: transit.transit_id, revision: transit.revision, action: confirm });
      toast.success(confirm === 'complete' ? 'Transit completed' : confirm === 'cancel' ? 'Transit cancelled; client refunds can be recorded separately' : 'Vehicle returned Home');
      setConfirm(null); setError(null);
    } catch (cause) { setConfirm(null); setError(cause instanceof Error ? cause.message : 'Action failed.'); }
  }
  return <>
    <PurchaseDialog title="Transit details" subtitle={`${transit.vehicle_name ?? 'Vehicle'} · ${transit.purchase_id ? 'Purchase shipment' : 'Custom transit'}`} onClose={onClose} busy={busy}>
      <form onSubmit={e => { e.preventDefault(); if (e.target !== e.currentTarget) return; setSaveReview(true); }}>
        <div className="modal-body">
          <section className="purchase-section transit-identity">
            <div className="purchase-statuses"><span className={`purchase-badge ${transit.status === 'active' ? 'payment-unpaid' : 'payment-paid'}`}>{label}</span>
              <span className="purchase-badge transit-cost-state">{transit.closed_at ? 'Settled' : 'Awaiting completion'}</span></div>
            <dl className="purchase-meta">
              <div><dt>Client</dt><dd>{transit.client_name || 'Not recorded'}</dd></div>
              <div><dt>Destination</dt><dd>{transit.destination || 'Not recorded'}</dd></div>
              <div><dt>Driver</dt><dd>{transit.driver_name || 'Not recorded'}</dd></div><div><dt>Helper</dt><dd>{transit.helper_name || 'Not recorded'}</dd></div><div><dt>{transit.purchase_id ? 'Purchase transport allocation' : 'Transport fee'}</dt><dd>{formatBDT(Number(transit.transport_fee))}</dd></div>
            </dl>
            {transit.description && <p className="purchase-hint">{transit.description}</p>}
            {transit.purchase_id && transit.status === 'cancelled' && <p className="purchase-alert">Purchase {transit.purchase_financial_closed_at ? 'financially closed' : `refunds pending: ${formatBDT(Number(transit.purchase_refund_due ?? 0))}`}. Operating expenses remain payable and close independently below.</p>}
          </section>
          {error && <p role="alert" className="purchase-error">{error}</p>}
          {dirty && draftRevision !== transit.revision && <p className="purchase-alert">Transit costs changed while you were editing. <button type="button" className="btn btn-secondary" onClick={loadSaved}>Reload saved costs</button></p>}
          <p className="purchase-alert">{transit.closed_at ? 'Transit expenses are settled and locked.' : transit.purchase_id && transit.status === 'active' ? 'Receive or cancel this shipment in Purchases. Save earnings and pay its recorded crew here.' : 'Save crew earnings, record payments, then complete the transit. Returning the vehicle Home releases it for another journey while earnings remain payable.'}</p>
          {!transit.closed_at && outstanding > 0 && <p className="purchase-alert" role="status">Complete transit is unavailable: {formatBDT(outstanding)} in transit obligations remains unpaid.</p>}
          <section className="purchase-section"><h3>Operating costs</h3>
            <fieldset className="transit-cost-fields" disabled={locked || busy}>
              {(['driverCost', 'helperCost', 'oilCost', 'othersCost'] as const).map((key, index) =>
                <PurchaseNumber key={key} label={`${['Driver earnings', 'Helper earnings', 'Oil cost', 'Other costs'][index]} (Tk)`} money value={draft[key]}
                  onChange={value => setDraft({ ...draft, [key]: value ?? 0 })} />)}
            </fieldset>
            <div className="purchase-section-heading"><h3>Additional costs</h3>
              {!locked && <button type="button" className="btn btn-ghost" disabled={busy} onClick={() => { costPages.setPage(Math.floor(draft.additionalCosts.length / costPages.pageSize)); setDraft({ ...draft, additionalCosts: [...draft.additionalCosts, { name: cats.data?.find(c=>c.is_active)?.name??'', category_id:cats.data?.find(c=>c.is_active)?.category_id, amount: 0 }] }); }}><Plus size={14} /> Add cost</button>}
            </div>
            {!draft.additionalCosts.length && <p className="purchase-hint">No additional costs.</p>}
            {costPages.entries.map((cost, localIndex) => { const index = costPages.page * costPages.pageSize + localIndex; return <fieldset key={index} className="transit-additional-row" disabled={locked || busy}>
              <label className="input-group"><span className="input-label">Expense category</span><select className="input-field" value={cost.category_id??cost.name} onChange={e=>{const category=cats.data?.find(c=>c.category_id===e.target.value);if(category)setDraft({...draft,additionalCosts:draft.additionalCosts.map((c,i)=>i===index?{...c,category_id:category.category_id,name:category.name}:c)});}}>{!cost.category_id&&<option value={cost.name}>{cost.name||'Choose a category'}</option>}{cats.data?.filter(c=>c.is_active||c.category_id===cost.category_id).map(c=><option key={c.category_id} value={c.category_id}>{c.name}</option>)}</select></label>
              <PurchaseNumber label="Amount (Tk)" money value={cost.amount} onChange={value => setDraft({ ...draft, additionalCosts: draft.additionalCosts.map((c, i) => i === index ? { ...c, amount: value ?? 0 } : c) })} />
              {!locked && <button type="button" className="btn btn-ghost purchase-danger-action" aria-label={`Remove cost ${index + 1}`} onClick={() => setDraft({ ...draft, additionalCosts: draft.additionalCosts.filter((_, i) => i !== index) })}><Trash2 size={15} /></button>}
            </fieldset>; })}
            <Pagination {...costPages} onChange={costPages.setPage} label="additional costs" />
          </section>
          <section className="purchase-section"><h3>Transit earnings & payments</h3>{payroll.isPending && <p role="status">Loading earnings…</p>}{payroll.error && <p className="purchase-error" role="alert">Earnings unavailable. <button type="button" className="btn btn-secondary" onClick={() => void payroll.refetch()}>Retry</button></p>}{payroll.data && <><dl className="logistics-facts"><div><dt>Driver paid / remaining</dt><dd>{formatBDT(payroll.data.driver_paid)} / {formatBDT(Math.max(0, Number(transit.driver_cost)-payroll.data.driver_paid))}</dd></div><div><dt>Helper paid / remaining</dt><dd>{formatBDT(payroll.data.helper_paid)} / {formatBDT(Math.max(0, Number(transit.helper_cost)-payroll.data.helper_paid))}</dd></div></dl><TransitEmployeePayButton transit={transit} paid={payroll.data} disabled={dirty || busy} /></>}</section>
          <OperatingPayments parent={{transit_id:transit.transit_id}} due={Math.max(0,remainingCost-transit.operating_paid)} locked={locked||dirty||busy} clientDue={transit.purchase_id?undefined:Math.max(0,transit.transport_fee-transit.client_paid)} clientRefund={transit.purchase_id?0:transit.client_paid} clientReceipts={transit.status!=='cancelled'}/>
          <dl className="transit-settlement"><div><dt>External transport revenue</dt><dd>{formatBDT(transit.revenue)}</dd></div><div><dt>{dirty ? 'Profit / loss after proposed costs' : 'Recorded transit profit / loss'}</dt><dd>{formatBDT(dirty ? transit.profit + Number(transit.total_cost) - total : transit.profit)}</dd></div><div><dt>Total operating cost</dt><dd>{formatBDT(total)}</dd></div><div><dt>Employee payments recorded</dt><dd>{payroll.data ? formatBDT(payroll.data.paid) : '…'}</dd></div><div><dt>Non-employee expenses incurred</dt><dd>{formatBDT(Math.max(0, total - draft.driverCost - draft.helperCost))}</dd></div>{!transit.purchase_id && <><div><dt>Client cash collected (net)</dt><dd>{formatBDT(transit.client_paid)}</dd></div><div><dt>{transit.status==='cancelled'?'Client refund outstanding':'Client receivable'}</dt><dd>{formatBDT(transit.status==='cancelled'?transit.client_paid:Math.max(0,transit.transport_fee-transit.client_paid))}</dd></div></>}</dl>
        </div>
        <div className="modal-footer">
          {!locked && !transit.purchase_id && transit.status !== 'cancelled' && <button type="button" className="btn btn-secondary purchase-danger-action" disabled={busy || dirty} onClick={() => setConfirm('cancel')}>Cancel transit</button>}
          <button type="button" className="btn btn-secondary" disabled={busy} onClick={onClose}>Close</button>
          {!locked && <button type="submit" className="btn btn-secondary" disabled={busy || !dirty}><Save size={15} /> Save changes</button>}
          {!locked && transit.status === 'active' && !transit.purchase_id && <button type="button" className="btn btn-secondary" disabled={busy || dirty} onClick={() => setConfirm('return')}>Return vehicle Home</button>}
          {!locked && !(transit.purchase_id && transit.status === 'active') && <button type="button" className="btn btn-primary" disabled={busy || dirty || !payroll.data || (outstanding > 0 || transit.status === 'cancelled' && transit.client_paid > 0)} onClick={() => setConfirm('complete')}>Complete transit</button>}
          {dirty && <span className="purchase-hint">Save costs before continuing.</span>}
        </div>
      </form>
    </PurchaseDialog>
    {saveReview && <PurchaseConfirmation title="Confirm transit changes" action="Save changes" busy={busy} onCancel={()=>setSaveReview(false)} onConfirm={()=>void save()}><p>Save operating costs totaling <strong>{formatBDT(total)}</strong>?</p><p>Driver earnings: {formatBDT(draft.driverCost)} · Helper earnings: {formatBDT(draft.helperCost)}. Saving records earnings due; payment is recorded separately.</p>{error && <p role="alert" className="purchase-error">{error}</p>}</PurchaseConfirmation>}
    {confirm && <PurchaseConfirmation title={confirm === 'complete' ? 'Complete this transit?' : confirm === 'cancel' ? 'Cancel this transit?' : 'Return vehicle Home?'} action="Confirm" busy={busy} onCancel={() => setConfirm(null)} onConfirm={() => void act()}>
      {confirm === 'complete' ? <p>All transit obligations are settled. Complete the transit and lock its costs and payments. Completion creates no wallet transaction.</p> : confirm === 'cancel' ? <p>Cancel earned revenue and release the vehicle. Record any actual client refund separately. Incurred earnings and operating costs remain payable.</p> : <p>Release the vehicle for its next journey. This transit remains open for earnings, payments and completion.</p>}
    </PurchaseConfirmation>}
  </>;
}
