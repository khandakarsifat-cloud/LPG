import { useState, useEffect } from 'react';
import { X, Save, CheckCircle, Loader2 } from 'lucide-react';
import { useUpdatePurchase, useCompletePurchase } from '../../hooks/usePurchases';
import type { Purchase } from '../../types/purchase';

interface UpdatePurchaseModalProps {
  open: boolean;
  onClose: () => void;
  purchase: Purchase | null;
}

export const UpdatePurchaseModal = ({ open, onClose, purchase }: UpdatePurchaseModalProps) => {
  const updatePurchase = useUpdatePurchase();
  const completePurchase = useCompletePurchase();

  const [transportCost, setTransportCost] = useState(0);
  const [labourCost, setLabourCost] = useState(0);
  const [notes, setNotes] = useState('');
  const [itemsData, setItemsData] = useState<{item_id: string, unit_price: number, quantity: number}[]>([]);

  const isLocked = purchase?.status === 'received' || purchase?.status === 'cancelled';

  useEffect(() => {
    if (purchase && open) {
      // eslint-disable-next-line react-hooks/set-state-in-effect
      setTransportCost(Number(purchase.transport_cost) || 0);
      setLabourCost(Number(purchase.labour_cost) || 0);
      setNotes(purchase.notes || '');
      
      if (purchase.items) {
        setItemsData(purchase.items.map(i => ({
          item_id: i.item_id,
          unit_price: Number(i.unit_price) || 0,
          quantity: Number(i.quantity) || 0
        })));
      }
    }
  }, [purchase, open]);

  if (!open || !purchase) return null;

  const handleUpdateItem = (itemId: string, field: 'unit_price' | 'quantity', value: number) => {
    setItemsData(prev => prev.map(p => p.item_id === itemId ? { ...p, [field]: value } : p));
  };

  const handleSave = async (e: React.FormEvent) => {
    e.preventDefault();
    if (isLocked) return;

    try {
      await updatePurchase.mutateAsync({
        purchase_id: purchase.purchase_id,
        transport_cost: transportCost,
        labour_cost: labourCost,
        notes: notes,
        items: itemsData
      });
      onClose();
    } catch (err: unknown) {
      alert(`Error updating purchase: ${err instanceof Error ? err.message : 'Unknown error'}`);
    }
  };

  const handleComplete = async () => {
    if (isLocked) return;
    
    // First save any pending changes
    try {
      await updatePurchase.mutateAsync({
        purchase_id: purchase.purchase_id,
        transport_cost: transportCost,
        labour_cost: labourCost,
        notes: notes,
        items: itemsData
      });

      if (window.confirm('Are you sure you want to mark this purchase as completed? This will deduct the total cost from the Dealership Wallet, add the filled bottles to your inventory, and lock the purchase details.')) {
        await completePurchase.mutateAsync(purchase.purchase_id);
        onClose();
      }
    } catch (err: unknown) {
      alert(`Error completing purchase: ${err instanceof Error ? err.message : 'Unknown error'}`);
    }
  };

  return (
    <div className="modal-overlay" onClick={onClose}>
      <div 
        className="modal-content glass-panel" 
        onClick={e => e.stopPropagation()}
        style={{ maxWidth: 'min(92vw, 37.5rem)' }}
      >
        <div className="modal-header">
          <h2 className="modal-title">Purchase #{purchase.purchase_id.slice(0, 8).toUpperCase()}</h2>
          <button className="modal-close" onClick={onClose}><X size={20} /></button>
        </div>

        <form onSubmit={handleSave}>
          <div className="modal-body" style={{ display: 'flex', flexDirection: 'column', gap: '1.25rem' }}>
            
            {isLocked && (
              <div style={{ padding: '0.75rem', background: 'rgba(16,185,129,0.1)', color: 'var(--accent)', borderRadius: '0.5rem', fontSize: '0.875rem', fontWeight: 600, display: 'flex', alignItems: 'center', gap: '0.5rem' }}>
                <CheckCircle size={16} />
                This purchase is completed and locked.
              </div>
            )}

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '1rem' }}>
              <div className="input-group">
                <label className="input-label">Transport Cost (Tk)</label>
                <input 
                  type="number" 
                  className="input-field" 
                  value={transportCost || ''} 
                  onChange={(e) => setTransportCost(parseInt(e.target.value) || 0)}
                  min="0"
                  disabled={isLocked}
                />
              </div>
              <div className="input-group">
                <label className="input-label">Labour Cost (Tk)</label>
                <input 
                  type="number" 
                  className="input-field" 
                  value={labourCost || ''} 
                  onChange={(e) => setLabourCost(parseInt(e.target.value) || 0)}
                  min="0"
                  disabled={isLocked}
                />
              </div>
            </div>

            <div className="input-group">
              <label className="input-label">Line Items</label>
              <div style={{ display: 'flex', flexDirection: 'column', gap: '0.5rem' }}>
                {purchase.items?.map((item) => {
                  const currentItem = itemsData.find(p => p.item_id === item.item_id);
                  const currentPrice = currentItem?.unit_price ?? 0;
                  const currentQty = currentItem?.quantity ?? 0;

                  return (
                    <div key={item.item_id} style={{ display: 'flex', alignItems: 'center', gap: '1rem', background: 'var(--bg-secondary)', padding: '0.75rem', borderRadius: '0.5rem' }}>
                      <div style={{ flex: 1 }}>
                        <div style={{ fontSize: '0.875rem', fontWeight: 600 }}>{item.brand_name} {item.size_kg}kg ({item.type})</div>
                      </div>
                      
                      <div style={{ width: 'clamp(5rem, 8vw, 6.25rem)' }}>
                        <div className="input-icon-wrapper">
                          <input 
                            type="number"
                            className="input-field"
                            value={currentQty || ''}
                            onChange={(e) => handleUpdateItem(item.item_id, 'quantity', parseInt(e.target.value) || 0)}
                            min="1"
                            disabled={isLocked}
                            title="Quantity"
                          />
                        </div>
                      </div>

                      <div style={{ width: 'clamp(5.5rem, 9vw, 7.5rem)' }}>
                        <div className="input-icon-wrapper">
                          <span className="input-icon" style={{ padding: '0 0.5rem' }}>Tk</span>
                          <input 
                            type="number"
                            className="input-field"
                            value={currentPrice || ''}
                            onChange={(e) => handleUpdateItem(item.item_id, 'unit_price', parseInt(e.target.value) || 0)}
                            min="0"
                            style={{ paddingLeft: '2rem' }}
                            disabled={isLocked}
                            title="Unit Price"
                          />
                        </div>
                      </div>

                      <div style={{ width: 'clamp(5rem, 8vw, 6.25rem)', textAlign: 'right', fontWeight: 600 }}>
                        Tk {(currentPrice * currentQty).toLocaleString()}
                      </div>
                    </div>
                  );
                })}
              </div>
            </div>

            <div className="input-group">
              <label className="input-label">Notes</label>
              <textarea 
                className="input-field" 
                rows={2} 
                value={notes} 
                onChange={(e) => setNotes(e.target.value)}
                disabled={isLocked}
              />
            </div>

          </div>

          <div className="modal-footer" style={{ justifyContent: 'space-between' }}>
            {!isLocked ? (
              <button 
                type="button" 
                className="btn btn-primary" 
                style={{ background: 'var(--accent)' }} 
                onClick={handleComplete}
                disabled={updatePurchase.isPending || completePurchase.isPending}
              >
                {completePurchase.isPending ? <Loader2 size={16} className="spin" /> : <CheckCircle size={16} />}
                Mark as Completed
              </button>
            ) : (
              <div />
            )}

            <div style={{ display: 'flex', gap: '0.75rem' }}>
              <button type="button" className="btn btn-ghost" onClick={onClose} disabled={updatePurchase.isPending}>
                {isLocked ? 'Close' : 'Cancel'}
              </button>
              {!isLocked && (
                <button type="submit" className="btn btn-primary" disabled={updatePurchase.isPending}>
                  {updatePurchase.isPending ? <Loader2 size={16} className="spin" /> : <Save size={16} />}
                  Save Changes
                </button>
              )}
            </div>
          </div>
        </form>
      </div>
    </div>
  );
};
