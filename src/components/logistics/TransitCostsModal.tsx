import { useState, useEffect } from 'react';
import { X, Save, Navigation, Loader2, CheckCircle } from 'lucide-react';
import { useUpdateTransitCosts } from '../../hooks/useLogistics';
import type { Transit } from '../../types/logistics';

interface TransitCostsModalProps {
  open: boolean;
  onClose: () => void;
  transit: Transit;
}

export const TransitCostsModal = ({ open, onClose, transit }: TransitCostsModalProps) => {
  const updateTransit = useUpdateTransitCosts();

  const [driverCost, setDriverCost] = useState(0);
  const [helperCost, setHelperCost] = useState(0);
  const [oilCost, setOilCost] = useState(0);
  const [status, setStatus] = useState<string>('active');
  
  // Custom additional costs
  const [additionalCosts, setAdditionalCosts] = useState<{name: string, amount: number}[]>([]);

  const isLocked = transit?.status === 'completed';

  useEffect(() => {
    if (transit && open) {
      setDriverCost(transit.driver_cost || 0);
      setHelperCost(transit.helper_cost || 0);
      setOilCost(transit.oil_cost || 0);
      setStatus(transit.status);
      setAdditionalCosts(transit.additional_costs || []);
    }
  }, [transit, open]);

  if (!open) return null;

  const handleAddCost = () => {
    setAdditionalCosts([...additionalCosts, { name: '', amount: 0 }]);
  };

  const handleUpdateCost = (index: number, field: 'name' | 'amount', value: any) => {
    const newCosts = [...additionalCosts];
    newCosts[index] = { ...newCosts[index], [field]: value };
    setAdditionalCosts(newCosts);
  };

  const handleRemoveCost = (index: number) => {
    setAdditionalCosts(additionalCosts.filter((_, i) => i !== index));
  };

  const calculateTotal = () => {
    return driverCost + helperCost + oilCost + additionalCosts.reduce((sum, c) => sum + c.amount, 0);
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    
    // Validate additional costs
    const validAdditionalCosts = additionalCosts.filter(c => c.name.trim() !== '' && c.amount > 0);

    try {
      await updateTransit.mutateAsync({
        transitId: transit.transit_id,
        driverCost,
        helperCost,
        oilCost,
        additionalCosts: validAdditionalCosts,
        status
      });
      onClose();
    } catch (err: any) {
      alert(`Error updating transit: ${err.message}`);
    }
  };

  return (
    <div className="modal-overlay" onClick={onClose}>
      <div 
        className="modal-content glass-panel" 
        onClick={e => e.stopPropagation()}
        style={{ maxWidth: '600px' }}
      >
        <div className="modal-header">
          <div style={{ display: 'flex', alignItems: 'center', gap: '0.75rem' }}>
            <div className="modal-icon" style={{ background: 'rgba(16,185,129,0.1)', color: 'var(--accent)' }}>
              <Navigation size={18} />
            </div>
            <div>
              <h2 className="modal-title">Transit Costs</h2>
              <p className="modal-subtitle">{transit.truck_name || 'Unknown Truck'} • ID: {transit.transit_id.split('-')[0]}</p>
            </div>
          </div>
          <button className="modal-close" onClick={onClose}>
            <X size={18} />
          </button>
        </div>

        <form onSubmit={handleSubmit}>
          <div className="modal-body" style={{ display: 'flex', flexDirection: 'column', gap: '1.25rem' }}>
            
            {isLocked && (
              <div style={{ padding: '0.75rem', background: 'rgba(245,158,11,0.1)', color: 'var(--warning)', borderRadius: '0.5rem', fontSize: '0.875rem', fontWeight: 600, display: 'flex', alignItems: 'center', gap: '0.5rem' }}>
                <CheckCircle size={16} />
                This transit is completed and locked. Costs cannot be modified.
              </div>
            )}

            <div className="input-group">
              <label className="input-label">Transit Status</label>
              <select 
                className="input-field" 
                value={status} 
                onChange={(e) => setStatus(e.target.value)}
                disabled={isLocked}
              >
                <option value="active">Active (On Duty)</option>
                <option value="completed">Completed (Deduct costs & lock)</option>
                <option value="cancelled">Cancelled</option>
              </select>
            </div>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '1rem' }}>
              <div className="input-group">
                <label className="input-label">Driver Cost (৳)</label>
                <input 
                  type="number" 
                  className="input-field" 
                  value={driverCost || ''} 
                  onChange={(e) => setDriverCost(parseInt(e.target.value) || 0)}
                  min="0"
                  disabled={isLocked}
                />
              </div>
              <div className="input-group">
                <label className="input-label">Helper Cost (৳)</label>
                <input 
                  type="number" 
                  className="input-field" 
                  value={helperCost || ''} 
                  onChange={(e) => setHelperCost(parseInt(e.target.value) || 0)}
                  min="0"
                  disabled={isLocked}
                />
              </div>
              <div className="input-group">
                <label className="input-label">Oil Cost (৳)</label>
                <input 
                  type="number" 
                  className="input-field" 
                  value={oilCost || ''} 
                  onChange={(e) => setOilCost(parseInt(e.target.value) || 0)}
                  min="0"
                  disabled={isLocked}
                />
              </div>
            </div>

            {/* Additional Costs Section */}
            <div>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '0.5rem' }}>
                <label className="input-label" style={{ marginBottom: 0 }}>Additional Costs</label>
                {!isLocked && (
                  <button type="button" onClick={handleAddCost} style={{ background: 'none', border: 'none', color: 'var(--primary)', fontSize: '0.8rem', cursor: 'pointer', fontWeight: 600 }}>
                    + Add Cost
                  </button>
                )}
              </div>
              
              {additionalCosts.length === 0 ? (
                <div style={{ fontSize: '0.8rem', color: 'var(--text-muted)', fontStyle: 'italic', padding: '0.5rem' }}>
                  No additional costs
                </div>
              ) : (
                <div style={{ display: 'flex', flexDirection: 'column', gap: '0.5rem' }}>
                  {additionalCosts.map((cost, idx) => (
                    <div key={idx} style={{ display: 'flex', gap: '0.5rem' }}>
                      <input 
                        type="text" 
                        placeholder="Cost Name (e.g. Toll)" 
                        className="input-field" 
                        value={cost.name}
                        onChange={(e) => handleUpdateCost(idx, 'name', e.target.value)}
                        style={{ flex: 1 }}
                        disabled={isLocked}
                      />
                      <input 
                        type="number" 
                        placeholder="Amount" 
                        className="input-field" 
                        value={cost.amount || ''}
                        onChange={(e) => handleUpdateCost(idx, 'amount', parseInt(e.target.value) || 0)}
                        style={{ width: '120px' }}
                        disabled={isLocked}
                      />
                      {!isLocked && (
                        <button type="button" onClick={() => handleRemoveCost(idx)} style={{ background: 'none', border: 'none', color: 'var(--danger)', padding: '0.5rem', cursor: 'pointer' }}>
                          <X size={16} />
                        </button>
                      )}
                    </div>
                  ))}
                </div>
              )}
            </div>

            <div style={{ padding: '1rem', background: 'var(--bg-secondary)', borderRadius: '0.5rem', display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginTop: '0.5rem' }}>
              <span style={{ fontWeight: 600 }}>Total Cost:</span>
              <span style={{ fontWeight: 700, fontSize: '1.2rem', color: 'var(--danger)' }}>৳ {calculateTotal().toLocaleString()}</span>
            </div>

          </div>
          
          <div className="modal-footer">
            <button type="button" className="btn btn-ghost" onClick={onClose} disabled={updateTransit.isPending}>
              Cancel
            </button>
            {!isLocked && (
              <button type="submit" className="btn btn-primary" disabled={updateTransit.isPending}>
                {updateTransit.isPending ? <><Loader2 size={16} className="spin" /> Saving...</> : <><Save size={16} /> Save Changes</>}
              </button>
            )}
          </div>
        </form>
      </div>
    </div>
  );
};
