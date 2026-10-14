import { useState } from 'react';
import toast from 'react-hot-toast';
import { useCreatePurchase } from '../../hooks/usePurchases';
import { useGasPlants } from '../../hooks/useGasPlants';
import { emptyPurchaseDraft, purchaseTotals, validatePurchaseDraft } from '../../lib/purchase';
import { PurchaseConfirmation, PurchaseDialog, PurchaseSelect } from './PurchaseControls';
import { PurchaseForm } from './PurchaseForm';
import './purchases.css';

export function CreatePurchaseModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  return open ? <CreatePurchase onClose={onClose} /> : null;
}

function CreatePurchase({ onClose }: { onClose: () => void }) {
  const plantsQuery = useGasPlants(true);
  const create = useCreatePurchase();
  const [plantId, setPlantId] = useState('');
  const [draft, setDraft] = useState(emptyPurchaseDraft);
  const [requestId] = useState(() => crypto.randomUUID());
  const [confirm, setConfirm] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const plants = (plantsQuery.data ?? []).filter(plant => plant.brand_id);
  const plant = plants.find(plant => plant.plant_id === plantId);
  const totals = purchaseTotals(draft.items, draft.commission, draft.transport_cost, draft.labour_cost);
  async function submit() {
    try {
      await create.mutateAsync({ ...draft, plant_id: plantId, request_id: requestId });
      toast.success('Purchase created'); onClose();
    } catch (cause) {
      setConfirm(false); setError(cause instanceof Error ? cause.message : 'Purchase could not be created. Try again.');
    }
  }
  return <>
    <PurchaseDialog title="New purchase" subtitle="Start with a plant. Complete the shipment details when ready." onClose={onClose} busy={create.isPending}>
      <form onSubmit={event => {
        event.preventDefault();
        const message = !plant ? 'Select a destination plant with a company.' : validatePurchaseDraft(draft, totals.subtotal);
        setError(message); if (!message) setConfirm(true);
      }}>
        <div className="modal-body">
          {error && <p role="alert" className="purchase-error">{error}</p>}
          <section className="purchase-section"><h3>Destination</h3>
            <PurchaseSelect label="Destination plant" value={plantId} placeholder={plantsQuery.isLoading ? 'Loading plants…' : 'Search plants or companies'}
              options={plants.map(plant => ({ value: plant.plant_id, label: plant.plant_name, description: [plant.brand_name, plant.location].filter(Boolean).join(' · ') }))}
              onChange={id => { setPlantId(id); setDraft(previous => ({ ...previous, items: [], commission: 0 })); setError(null); }} />
            {plant && <dl className="purchase-meta"><div><dt>Company</dt><dd>{plant.brand_name}</dd></div><div><dt>Location</dt><dd>{plant.location || 'Not specified'}</dd></div></dl>}
            <p className="purchase-hint">The plant determines the company. Both are fixed once this purchase is created.</p>
            {plantsQuery.isError && <p role="alert" className="purchase-error">Plants could not be loaded. <button type="button" className="btn btn-ghost" onClick={() => void plantsQuery.refetch()}>Retry</button></p>}
            {!plantsQuery.isLoading && !plants.length && !plantsQuery.isError && <p className="purchase-error">Add an active plant linked to a company in Gas Plants first.</p>}
          </section>
          {plant && <PurchaseForm draft={draft} onChange={setDraft} companyId={plant.brand_id} />}
        </div>
        <div className="modal-footer"><span className="purchase-hint purchase-footer-hint">Created purchases do not move stock or make payments.</span>
          <button type="button" className="btn btn-secondary" disabled={create.isPending} onClick={onClose}>Cancel</button>
          <button type="submit" className="btn btn-primary" disabled={!plant || create.isPending}>Create purchase</button>
        </div>
      </form>
    </PurchaseDialog>
    {confirm && <PurchaseConfirmation title="Create this purchase?" action="Create purchase" busy={create.isPending} onCancel={() => setConfirm(false)} onConfirm={() => void submit()}>
      <p>Create a purchase for <strong>{plant?.plant_name}</strong> ({plant?.brand_name}). The plant and company cannot be changed afterward.</p>
      <p>No inventory or wallet changes occur. Products, truck and costs can be added or edited before dispatch.</p>
    </PurchaseConfirmation>}
  </>;
}
