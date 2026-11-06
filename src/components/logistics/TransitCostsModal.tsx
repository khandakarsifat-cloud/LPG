import { useListPage } from '../../hooks/useListPage';
import { Pagination } from '../ui/Pagination';
import { useState } from 'react';
import { Plus, Save, Trash2 } from 'lucide-react';
import toast from 'react-hot-toast';
import { useAuth } from '../../contexts/AuthContext';
import { useUpdateTransitCosts, useTransitionTransit, usePurchaseTransport, useRefundPurchaseTransport } from '../../hooks/useLogistics';
import { PurchaseConfirmation, PurchaseDialog, PurchaseNumber } from '../purchases/PurchaseControls';
import { formatBDT } from '../../lib/formatBDT';
import { transitStatus, type Transit } from '../../types/logistics';
import '../purchases/purchases.css';
import { OperatingPayments } from './OperatingPayments';
import { useVehicleExpenseCategories } from '../../hooks/useVehicleAccounting';
const transitDraft = (transit: Transit) => ({ driverCost: Number(transit.driver_cost), helperCost: Number(transit.helper_cost),
  oilCost: Number(transit.oil_cost), othersCost: Number(transit.others_cost ?? 0), additionalCosts: transit.additional_costs ?? [] });

function PurchaseTransport({transit}:{transit:Transit}) {
 const {can}=useAuth();const query=usePurchaseTransport(transit.transit_id,!!transit.purchase_id);
 const refund=useRefundPurchaseTransport(transit.transit_id);
 const [amount,setAmount]=useState(0);const [review,setReview]=useState(false);
 async function confirmRefund(){
  try{await refund.mutateAsync(refund.hasPending?undefined:amount);setReview(false);setAmount(0);toast.success('Transport refund paid');}
  catch{setReview(false);}
 }
 if(query.error)return <p className="purchase-error" role="alert">{query.error.message}</p>;
 const value=query.data;if(!value)return null;
 return <section className="purchase-section"><h3>Purchase transport payment</h3>
  <dl className="purchase-meta"><div><dt>Paid to Logistics</dt><dd>{formatBDT(value.paid)}</dd></div>
   <div><dt>Refunded to purchase</dt><dd>{formatBDT(value.refunded)}</dd></div></dl>
  {value.can_refund&&can('purchases:cancel')&&can('logistics:pay')&&(value.remaining>0||refund.hasPending)&&<>
   <p className="purchase-hint">Approve the refundable amount, up to {formatBDT(value.remaining)}. Payment returns through the original Cash Register.</p>
   <PurchaseNumber label="Transport refund amount (Tk)" money value={amount} onChange={v=>setAmount(v??0)}/>
   <button type="button" className="btn btn-secondary" disabled={refund.isPending||!refund.hasPending&&(amount<=0||amount>value.remaining)}
    onClick={()=>{if(refund.hasPending)void confirmRefund();else setReview(true);}}>{refund.hasPending?'Recover transport refund':'Approve & pay transport refund'}</button>
  </>}
  {refund.error&&<p className="purchase-error" role="alert">{refund.error.message}</p>}
  {review&&<PurchaseConfirmation title="Approve transport refund?" action="Approve & pay refund" busy={refund.isPending}
   onCancel={()=>setReview(false)} onConfirm={()=>void confirmRefund()}>
   <p>Return {formatBDT(amount)} from Logistics to the purchasing business through Cash Register.</p>
  </PurchaseConfirmation>}
 </section>;
}
export function TransitCostsModal({ open, onClose, transit }: { open: boolean; onClose: () => void; transit: Transit }) {
  return open ? <TransitDetails key={transit.transit_id} onClose={onClose} transit={transit} /> : null;
}
function TransitDetails({ onClose, transit }: { onClose: () => void; transit: Transit }) {
  const { can } = useAuth();
  const cats=useVehicleExpenseCategories();
  const update = useUpdateTransitCosts();
  const transition = useTransitionTransit();
  const clientDue = !transit.purchase_id && transit.status !== 'cancelled' ? Math.max(0, Number(transit.transport_fee) - Number(transit.client_paid)) : 0;
  const [saveReview,setSaveReview]=useState(false);
  const [draft, setDraft] = useState(() => transitDraft(transit));
  const costPages = useListPage(draft.additionalCosts, 6, transit.transit_id);
  const [draftRevision, setDraftRevision] = useState(transit.revision);
  const [baseline, setBaseline] = useState(() => JSON.stringify(transitDraft(transit)));
  const [error, setError] = useState<string | null>(null);
  const [confirm, setConfirm] = useState<'complete' | 'cancel' | null>(null);
  const [confirmRevision, setConfirmRevision] = useState(transit.revision);
  function review(action: 'complete' | 'cancel') {
    if (action === 'complete' && draft.additionalCosts.some(c => !c.name.trim())) { setError('Name each additional cost or remove its row.'); return; }
    setConfirmRevision(dirty ? draftRevision : transit.revision); setConfirm(action);
  }
  const busy = update.isPending || transition.isPending;
  const locked = !!transit.closed_at || !can('logistics:costs');
  const dirty = JSON.stringify(draft) !== baseline;
  const total = ([draft.driverCost, draft.helperCost, draft.oilCost, draft.othersCost, ...draft.additionalCosts.map(c => c.amount)]
    .reduce((sum, n) => sum + Math.round(n * 100), 0)) / 100;
  const driverDue = Math.max(0, Math.round(draft.driverCost * 100) - Math.round(Number(transit.driver_paid) * 100)) / 100;
  const helperDue = Math.max(0, Math.round(draft.helperCost * 100) - Math.round(Number(transit.helper_paid) * 100)) / 100;
  const remainingCost = Math.max(0, Number(transit.total_cost) - Number(transit.driver_cost) - Number(transit.helper_cost));
  const crewOutstanding = (Math.round(driverDue * 100) + Math.round(helperDue * 100)) / 100;
  const expenseDue = Math.max(0, Math.round(total * 100) - Math.round(draft.driverCost * 100) - Math.round(draft.helperCost * 100) - Math.round(Number(transit.operating_paid) * 100)) / 100;
  const outstanding = (Math.round(crewOutstanding * 100) + Math.round(expenseDue * 100)) / 100;
  const paymentDenied = crewOutstanding > 0 && !can('payroll:pay') || (expenseDue + clientDue > 0) && !can('logistics:pay');
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
      await transition.mutateAsync({ transitId: transit.transit_id, revision: confirmRevision, action: confirm,
        costs: confirm === 'complete' && dirty ? { driver_cost: draft.driverCost, helper_cost: draft.helperCost, oil_cost: draft.oilCost, others_cost: draft.othersCost, additional_costs: draft.additionalCosts } : undefined });
      if (confirm === 'complete') setBaseline(JSON.stringify(draft));
      toast.success(confirm === 'complete' ? 'Transit completed; costs paid from Cash Register' : 'Transit cancelled; client refunds can be recorded separately');
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
              <div><dt>Driver</dt><dd>{transit.driver_name || 'Not recorded'}</dd></div><div><dt>Helper</dt><dd>{transit.helper_name || 'Not recorded'}</dd></div><div><dt>Transport charge</dt><dd>{formatBDT(Number(transit.transport_fee))}</dd></div>
            </dl>
            {transit.description && <p className="purchase-hint">{transit.description}</p>}
            {transit.purchase_id && transit.status === 'cancelled' && <p className="purchase-alert">Purchase {transit.purchase_financial_closed_at ? 'financially closed' : `refunds pending: ${formatBDT(Number(transit.purchase_refund_due ?? 0))}`}. Operating expenses remain payable and close independently below.</p>}
          </section>
          {transit.purchase_id&&<PurchaseTransport transit={transit}/>}
          {error && <p role="alert" className="purchase-error">{error}</p>}
          {dirty && draftRevision !== transit.revision && <p className="purchase-alert">Transit costs changed while you were editing. <button type="button" className="btn btn-secondary" onClick={loadSaved}>Reload saved costs</button></p>}
          <p className="purchase-alert">{transit.closed_at ? 'Transit expenses are settled and locked.' : transit.purchase_id && transit.status === 'active' ? 'Receive or cancel this shipment in Purchases first. Then Complete transit pays the remaining crew and operating costs from Cash Register.' : 'Enter the trip costs, then choose Complete transit. Confirm once to save and pay all remaining costs from Cash Register and return the vehicle Home.'}</p>
          {!transit.closed_at && outstanding > 0 && <p className="purchase-alert" role="status">{formatBDT(outstanding)} will be paid from Cash Register when you confirm completion.</p>}
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
          {paymentDenied && !transit.closed_at && <p className="purchase-error" role="alert">Completion needs Payroll payment permission for crew earnings and Logistics payment permission for other costs or client collections.</p>}
          <details className="purchase-section"><summary>Payment history & adjustments</summary>
            <OperatingPayments parent={{transit_id:transit.transit_id}} due={Math.max(0,remainingCost-transit.operating_paid)} locked={dirty||busy} automaticSettlement clientSettlementsOnly={!!transit.closed_at} clientDue={clientDue} clientRefund={transit.status==='cancelled'&&!transit.purchase_id?transit.client_paid:0} clientReceipts={!!transit.closed_at}/>
          </details>
          <dl className="transit-settlement"><div><dt>External transport revenue</dt><dd>{formatBDT(transit.revenue)}</dd></div><div><dt>{dirty ? 'Profit / loss after proposed costs' : 'Recorded transit profit / loss'}</dt><dd>{formatBDT(dirty ? transit.profit + Number(transit.total_cost) - total : transit.profit)}</dd></div><div><dt>Total operating cost</dt><dd>{formatBDT(total)}</dd></div><div><dt>Employee payments recorded</dt><dd>{formatBDT(Number(transit.driver_paid) + Number(transit.helper_paid))}</dd></div><div><dt>Non-employee expenses incurred</dt><dd>{formatBDT(Math.max(0, total - draft.driverCost - draft.helperCost))}</dd></div>{!transit.purchase_id && <><div><dt>Client cash collected (net)</dt><dd>{formatBDT(transit.client_paid)}</dd></div><div><dt>{transit.status==='cancelled'?'Client refund outstanding':'Client receivable'}</dt><dd>{formatBDT(transit.status==='cancelled'?transit.client_paid:Math.max(0,transit.transport_fee-transit.client_paid))}</dd></div></>}</dl>
        </div>
        <div className="modal-footer">
          {!transit.closed_at && can('logistics:transits') && !transit.purchase_id && transit.status !== 'cancelled' && <button type="button" className="btn btn-secondary purchase-danger-action" disabled={busy || dirty} onClick={() => review('cancel')}>Cancel transit</button>}
          <button type="button" className="btn btn-secondary" disabled={busy} onClick={onClose}>Close</button>
          {!locked && <button type="submit" className="btn btn-secondary" disabled={busy || !dirty}><Save size={15} /> Save changes</button>}
          {!transit.closed_at && can('logistics:transits') && !(transit.purchase_id && transit.status === 'active') && <button type="button" className="btn btn-primary" disabled={busy || dirty && draftRevision !== transit.revision || paymentDenied || (transit.status === 'cancelled' && transit.client_paid > 0)} onClick={() => review('complete')}>Complete transit</button>}
          {dirty && <span className="purchase-hint">Completion also saves your cost changes.</span>}
        </div>
      </form>
    </PurchaseDialog>
    {saveReview && <PurchaseConfirmation title="Confirm transit changes" action="Save changes" busy={busy} onCancel={()=>setSaveReview(false)} onConfirm={()=>void save()}><p>Save operating costs totaling <strong>{formatBDT(total)}</strong>?</p><p>Driver earnings: {formatBDT(draft.driverCost)} · Helper earnings: {formatBDT(draft.helperCost)}. Complete transit pays these saved costs from Cash Register after confirmation.</p>{error && <p role="alert" className="purchase-error">{error}</p>}</PurchaseConfirmation>}
    {confirm && <PurchaseConfirmation title={confirm === 'complete' ? 'Complete this transit?' : 'Cancel this transit?'} action={confirm === 'complete' ? 'Pay & complete transit' : 'Confirm cancellation'} busy={busy} confirmDisabled={confirmRevision !== transit.revision} onCancel={() => setConfirm(null)} onConfirm={() => void act()}>
      {confirmRevision !== transit.revision && <p role="alert" className="purchase-error">This transit changed. Go back and review the latest amounts before confirming.</p>}
      {confirm === 'complete' ? <>
        <p>Pay <strong>{formatBDT(outstanding)}</strong> from <strong>Cash Register</strong> and complete this transit?</p>
        <dl className="logistics-facts"><div><dt>Driver · {transit.driver_name || 'None'}</dt><dd>{formatBDT(driverDue)}</dd></div><div><dt>Helper · {transit.helper_name || 'None'}</dt><dd>{formatBDT(helperDue)}</dd></div><div><dt>Other operating costs</dt><dd>{formatBDT(expenseDue)}</dd></div></dl>
        {clientDue > 0 && <p>Also confirm collection of the remaining client fee, <strong>{formatBDT(clientDue)}</strong>, into Cash Register. Net Cash Register change: <strong>{formatBDT(clientDue - outstanding)}</strong>.</p>}
        <p>{transit.status === 'active' ? 'The vehicle returns Home and becomes available for its next journey. Costs and payments will be locked.' : 'The vehicle return stays as recorded. This transit’s costs and payments will be locked.'}</p>
      </> : <p>Cancel earned revenue and release the vehicle. Record any actual client refund separately. Incurred earnings and operating costs remain payable.</p>}
    </PurchaseConfirmation>}

  </>;
}
