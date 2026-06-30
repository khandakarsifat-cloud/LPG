import { useState } from 'react';
import { X, Navigation, Truck, FileText, Loader2 } from 'lucide-react';
import { useCreateCustomTransit, useTrucks } from '../../hooks/useLogistics';

interface CreateCustomTransitModalProps {
  open: boolean;
  onClose: () => void;
}

export const CreateCustomTransitModal = ({ open, onClose }: CreateCustomTransitModalProps) => {
  const createTransit = useCreateCustomTransit();
  const { data: trucks = [] } = useTrucks();

  const [truckId, setTruckId] = useState('');
  const [fee, setFee] = useState<number>(0);
  const [notes, setNotes] = useState('');

  const idleTrucks = trucks.filter(t => t.status === 'idle');

  if (!open) return null;

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!truckId) return;

    try {
      await createTransit.mutateAsync({
        truckId,
        fee,
        notes
      });
      onClose();
      setTruckId('');
      setFee(0);
      setNotes('');
    } catch (err: any) {
      alert(`Error creating transit: ${err.message}`);
    }
  };

  return (
    <div className="modal-overlay" onClick={onClose}>
      <div 
        className="modal-content glass-panel" 
        onClick={e => e.stopPropagation()}
        style={{ maxWidth: 'min(92vw, 28.125rem)' }}
      >
        <div className="modal-header">
          <div style={{ display: 'flex', alignItems: 'center', gap: '0.75rem' }}>
            <div className="modal-icon" style={{ background: 'rgba(59,130,246,0.1)', color: 'var(--primary)' }}>
              <Navigation size={18} />
            </div>
            <div>
              <h2 className="modal-title">New Custom Transit</h2>
              <p className="modal-subtitle">Start a transit without a purchase order</p>
            </div>
          </div>
          <button className="modal-close" onClick={onClose}>
            <X size={18} />
          </button>
        </div>

        <form onSubmit={handleSubmit}>
          <div className="modal-body" style={{ display: 'flex', flexDirection: 'column', gap: '1.25rem' }}>
            
            <div className="input-group">
              <label className="input-label">Select Truck <span style={{ color: 'var(--danger)' }}>*</span></label>
              <div className="input-icon-wrapper">
                <Truck size={16} className="input-icon" />
                <select 
                  className="input-field" 
                  value={truckId} 
                  onChange={e => setTruckId(e.target.value)}
                  required
                  style={{ paddingLeft: '2.5rem' }}
                >
                  <option value="">-- Choose an idle truck --</option>
                  {idleTrucks.map(t => (
                    <option key={t.truck_id} value={t.truck_id}>{t.name} ({t.serial_no})</option>
                  ))}
                </select>
              </div>
              {idleTrucks.length === 0 && <span style={{ fontSize: '0.75rem', color: 'var(--warning)' }}>No idle trucks available!</span>}
            </div>

            <div className="input-group">
              <label className="input-label">Transport Fee (Income) (৳)</label>
              <div className="input-icon-wrapper">
                <span className="input-icon" style={{ padding: '0 0.5rem', fontWeight: 600 }}>৳</span>
                <input 
                  type="number"
                  className="input-field" 
                  value={fee || ''} 
                  onChange={e => setFee(parseInt(e.target.value) || 0)}
                  min="0"
                  placeholder="e.g. 5000"
                  style={{ paddingLeft: '2.5rem' }}
                />
              </div>
            </div>

            <div className="input-group">
              <label className="input-label">Destination / Notes</label>
              <div className="input-icon-wrapper">
                <FileText size={16} className="input-icon" style={{ top: '12px', transform: 'none' }} />
                <textarea 
                  className="input-field" 
                  value={notes} 
                  onChange={e => setNotes(e.target.value)}
                  rows={3}
                  placeholder="e.g. Empty trip to warehouse..."
                  style={{ paddingLeft: '2.5rem', resize: 'vertical' }}
                />
              </div>
            </div>

          </div>
          
          <div className="modal-footer">
            <button type="button" className="btn btn-ghost" onClick={onClose} disabled={createTransit.isPending}>
              Cancel
            </button>
            <button type="submit" className="btn btn-primary" disabled={createTransit.isPending || !truckId}>
              {createTransit.isPending ? <><Loader2 size={16} className="spin" /> Creating...</> : 'Start Transit'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
};
