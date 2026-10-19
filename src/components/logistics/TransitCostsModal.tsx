import { useListPage } from '../../hooks/useListPage';
import { Pagination } from '../ui/Pagination';
import { useState } from 'react';
import { Plus, Save, Trash2 } from 'lucide-react';
import toast from 'react-hot-toast';
import { useAuth } from '../../contexts/AuthContext';
import { useUpdateTransitCosts, useTransitionTransit } from '../../hooks/useLogistics';
import { PurchaseConfirmation, PurchaseDialog, PurchaseNumber } from '../purchases/PurchaseControls';
import { formatBDT } from '../../lib/formatBDT';
import type { Transit } from '../../types/logistics';
import '../purchases/purchases.css';

const transitDraft = (transit: Transit) => ({ driverCost: Number(transit.driver_cost), helperCost: Number(transit.helper_cost),
  oilCost: Number(transit.oil_cost), othersCost: Number(transit.others_cost ?? 0), additionalCosts: transit.additional_costs ?? [] });

export function TransitCostsModal({ open, onClose, transit }: { open: boolean; onClose: () => void; transit: Transit }) {
  return open ? <TransitDetails key={transit.transit_id} onClose={onClose} transit={transit} /> : null;
}

function TransitDetails({ onClose, transit }: { onClose: () => void; transit: Transit }) {
  const { can } = useAuth();
  const update = useUpdateTransitCosts();
  const transition = useTransitionTransit();
  const [draft, setDraft] = useState(() => transitDraft(transit));
  const costPages = useListPage(draft.additionalCosts, 6, transit.transit_id);
  const [draftRevision, setDraftRevision] = useState(transit.revision);
  const [baseline, setBaseline] = useState(() => JSON.stringify(transitDraft(transit)));
  const [error, setError] = useState<string | null>(null);
  const [confirm, setConfirm] = useState<'complete' | 'cancel' | 'close' | null>(null);
  const busy = update.isPending || transition.isPending;
  const locked = !!transit.closed_at || !can('logistics:manage');
  const dirty = JSON.stringify(draft) !== baseline;
  const total = ([draft.driverCost, draft.helperCost, draft.oilCost, draft.othersCost, ...draft.additionalCosts.map(c => c.amount)]
    .reduce((sum, n) => sum + Math.round(n * 100), 0)) / 100;
  const label = transit.status === 'cancelled' ? 'Cancelled' : transit.status === 'active' ? 'In transit' : 'Completed';
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
      toast.success('Transit costs saved');
    } catch (cause) { setError(cause instanceof Error ? cause.message : 'Costs could not be saved.'); }
  }
  async function act() {
    if (!confirm) return;
    try {
      await transition.mutateAsync({ transitId: transit.transit_id, revision: transit.revision, action: confirm });
      toast.success(confirm === 'close' ? 'Transit closed' : confirm === 'cancel' ? 'Transit cancelled; client fee refunded' : 'Transit completed; truck is free');
      setConfirm(null); setError(null);
    } catch (cause) { setConfirm(null); setError(cause instanceof Error ? cause.message : 'Action failed.'); }
  }
  return <>
    <PurchaseDialog title="Transit details" subtitle={`${transit.truck_name ?? 'Truck'} · ${transit.purchase_id ? 'Purchase shipment' : 'Custom transit'}`} onClose={onClose} busy={busy}>
      <form onSubmit={e => { e.preventDefault(); void save(); }}>
        <div className="modal-body">
          <section className="purchase-section transit-identity">
            <div className="purchase-statuses"><span className={`purchase-badge ${transit.status === 'active' ? 'payment-unpaid' : 'payment-paid'}`}>{label}</span>
              <span className="purchase-badge transit-cost-state">{transit.closed_at ? 'Costs closed' : 'Costs open'}</span></div>
            <dl className="purchase-meta">
              <div><dt>Client</dt><dd>{transit.client_name || 'Not recorded'}</dd></div>
              <div><dt>Destination</dt><dd>{transit.destination || 'Not recorded'}</dd></div>
              <div><dt>Transport fee</dt><dd>{formatBDT(Number(transit.transport_fee))}</dd></div>
            </dl>
            {transit.description && <p className="purchase-hint">{transit.description}</p>}
          </section>
          {error && <p role="alert" className="purchase-error">{error}</p>}
          {dirty && draftRevision !== transit.revision && <p className="purchase-alert">Transit costs changed while you were editing. <button type="button" className="btn btn-secondary" onClick={loadSaved}>Reload saved costs</button></p>}
          <p className={`purchase-alert${transit.status !== 'active' ? ' success' : ''}`}>
            {transit.closed_at ? 'Transit expenses are settled and locked.' : transit.purchase_id && transit.status === 'active'
              ? 'Receive or cancel this shipment in Purchases. You can prepare operating costs here.'
              : transit.status === 'active' ? 'Complete the trip to free the truck. Save costs, then close the transit to settle expenses.'
              : 'The truck is free. Adjust and save costs before closing this transit.'}
          </p>
          <section className="purchase-section"><h3>Operating costs</h3>
            <fieldset className="transit-cost-fields" disabled={locked || busy}>
              {(['driverCost', 'helperCost', 'oilCost', 'othersCost'] as const).map((key, index) =>
                <PurchaseNumber key={key} label={`${['Driver', 'Helper', 'Oil', 'Others'][index]} cost (Tk)`} money value={draft[key]}
                  onChange={value => setDraft({ ...draft, [key]: value ?? 0 })} />)}
            </fieldset>
            <div className="purchase-section-heading"><h3>Additional costs</h3>
              {!locked && <button type="button" className="btn btn-ghost" disabled={busy} onClick={() => { costPages.setPage(Math.floor(draft.additionalCosts.length / costPages.pageSize)); setDraft({ ...draft, additionalCosts: [...draft.additionalCosts, { name: '', amount: 0 }] }); }}><Plus size={14} /> Add cost</button>}
            </div>
            {!draft.additionalCosts.length && <p className="purchase-hint">No additional costs.</p>}
            {costPages.entries.map((cost, localIndex) => { const index = costPages.page * costPages.pageSize + localIndex; return <fieldset key={index} className="transit-additional-row" disabled={locked || busy}>
              <label className="input-group"><span className="input-label">Cost name</span><input className="input-field" value={cost.name} onChange={e => setDraft({ ...draft, additionalCosts: draft.additionalCosts.map((c, i) => i === index ? { ...c, name: e.target.value } : c) })} /></label>
              <PurchaseNumber label="Amount (Tk)" money value={cost.amount} onChange={value => setDraft({ ...draft, additionalCosts: draft.additionalCosts.map((c, i) => i === index ? { ...c, amount: value ?? 0 } : c) })} />
              {!locked && <button type="button" className="btn btn-ghost purchase-danger-action" aria-label={`Remove cost ${index + 1}`} onClick={() => setDraft({ ...draft, additionalCosts: draft.additionalCosts.filter((_, i) => i !== index) })}><Trash2 size={15} /></button>}
            </fieldset>; })}
            <Pagination {...costPages} onChange={costPages.setPage} label="additional costs" />
          </section>
          <dl className="transit-settlement"><div><dt>Total operating cost</dt><dd>{formatBDT(total)}</dd></div><div><dt>{transit.closed_at ? 'Settled from logistics' : 'Deducted when transit is closed'}</dt></div></dl>
        </div>
        <div className="modal-footer">
          {!locked && !transit.purchase_id && transit.status !== 'cancelled' && <button type="button" className="btn btn-secondary purchase-danger-action" disabled={busy || dirty} onClick={() => setConfirm('cancel')}>Cancel transit</button>}
          <button type="button" className="btn btn-secondary" disabled={busy} onClick={onClose}>Close</button>
          {!locked && <button type="submit" className="btn btn-secondary" disabled={busy || !dirty}><Save size={15} /> Save changes</button>}
          {!locked && transit.status === 'active' && !transit.purchase_id && <button type="button" className="btn btn-primary" disabled={busy || dirty} onClick={() => setConfirm('complete')}>Complete transit</button>}
          {!locked && transit.status !== 'active' && <button type="button" className="btn btn-primary" disabled={busy || dirty} onClick={() => setConfirm('close')}>Close transit</button>}
          {dirty && <span className="purchase-hint">Save costs before continuing.</span>}
        </div>
      </form>
    </PurchaseDialog>
    {confirm && <PurchaseConfirmation title={confirm === 'close' ? 'Close this transit?' : confirm === 'cancel' ? 'Cancel this transit?' : 'Complete this transit?'} action="Okay" busy={busy} onCancel={() => setConfirm(null)} onConfirm={() => void act()}>
      {confirm === 'close' ? <p>Deduct <strong>{formatBDT(Number(transit.total_cost))}</strong> from the logistics wallet and lock these costs. This happens once.</p>
        : confirm === 'cancel' ? <><p>Refund the full client fee of <strong>{formatBDT(Number(transit.transport_fee))}</strong> from the logistics wallet and free the truck.</p><p>Any incurred costs remain open for review and closure.</p></>
        : <p>Mark the trip completed and free the truck. Costs remain editable until you close the transit.</p>}
    </PurchaseConfirmation>}
  </>;
}
