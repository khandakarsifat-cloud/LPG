import { useState } from 'react';
import toast from 'react-hot-toast';
import { useCreateCustomTransit, useTrucks } from '../../hooks/useLogistics';
import { PurchaseDialog, PurchaseNumber, PurchaseSelect } from '../purchases/PurchaseControls';
import '../purchases/purchases.css';

export function CreateCustomTransitModal({ open, onClose }: { open: boolean; onClose: () => void }) {
  return open ? <CustomTransitForm onClose={onClose} /> : null;
}
function CustomTransitForm({ onClose }: { onClose: () => void }) {
  const create = useCreateCustomTransit();
  const trucks = useTrucks();
  const [truckId, setTruckId] = useState('');
  const [clientName, setClientName] = useState('');
  const [destination, setDestination] = useState('');
  const [description, setDescription] = useState('');
  const [fee, setFee] = useState(0);
  const [error, setError] = useState<string | null>(null);
  async function submit() {
    if (!truckId || !clientName.trim()) { setError('Client name and truck are required.'); return; }
    try {
      await create.mutateAsync({ truckId, clientName: clientName.trim(), destination, description, fee });
      toast.success('Transit started'); onClose();
    } catch (cause) { setError(cause instanceof Error ? cause.message : 'Transit could not be created.'); }
  }
  return <PurchaseDialog title="New custom transit" subtitle="Client trip" onClose={onClose} busy={create.isPending} compact>
    <form onSubmit={e => { e.preventDefault(); void submit(); }}><div className="modal-body">
      <p className="purchase-alert">Starting the transit reserves the truck and adds the client fee to the logistics wallet.</p>
      {error && <p role="alert" className="purchase-error">{error}</p>}
      <section className="purchase-section transit-create-fields">
        <label className="input-group"><span className="input-label">Client name *</span><input required className="input-field" value={clientName} onChange={e => setClientName(e.target.value)} /></label>
        <PurchaseSelect label="Truck *" value={truckId} onChange={setTruckId} placeholder={trucks.isLoading ? 'Loading trucks…' : 'Choose an idle truck'} options={(trucks.data ?? []).filter(t => t.status === 'idle').map(t => ({ value: t.truck_id, label: t.name, description: t.serial_no }))} />
        {trucks.isError && <p className="purchase-error">Trucks could not be loaded. <button type="button" className="btn btn-ghost" onClick={() => void trucks.refetch()}>Retry</button></p>}
        <label className="input-group"><span className="input-label">Destination</span><input className="input-field" value={destination} onChange={e => setDestination(e.target.value)} /></label>
        <label className="input-group"><span className="input-label">Description</span><textarea rows={2} className="input-field" value={description} onChange={e => setDescription(e.target.value)} /></label>
        <PurchaseNumber label="Client transport fee (Tk)" value={fee} money onChange={value => setFee(value ?? 0)} />
      </section>
    </div><div className="modal-footer"><button type="button" className="btn btn-secondary" disabled={create.isPending} onClick={onClose}>Go back</button><button type="submit" className="btn btn-primary" disabled={create.isPending || !truckId || !clientName.trim()}>{create.isPending ? 'Starting…' : 'Start transit'}</button></div></form>
  </PurchaseDialog>;
}
