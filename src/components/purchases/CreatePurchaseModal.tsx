import { useState } from 'react';
import { X, Plus, Trash2, Truck, Factory, Package } from 'lucide-react';
import { useCreatePurchase } from '../../hooks/usePurchases';
import { useItems } from '../../hooks/useInventory';
import { useTrucks } from '../../hooks/useLogistics';
import { useGasPlants } from '../../hooks/useGasPlants';
import type { PurchaseType, CreatePurchaseItemPayload } from '../../types/purchase';

interface CreatePurchaseModalProps {
  open: boolean;
  onClose: () => void;
}

export const CreatePurchaseModal = ({ open, onClose }: CreatePurchaseModalProps) => {
  const { data: items = [] } = useItems();
  const { data: trucks = [] } = useTrucks();
  const { data: gasPlants = [] } = useGasPlants(true); // Active only
  
  const createPurchase = useCreatePurchase();

  const [truckId, setTruckId] = useState('');
  const [plantId, setPlantId] = useState('');
  const [transportCost, setTransportCost] = useState('');
  const [labourCost, setLabourCost] = useState('');
  const [notes, setNotes] = useState('');

  const [lineItems, setLineItems] = useState<CreatePurchaseItemPayload[]>([]);
  
  const idleTrucks = trucks.filter(t => t.status === 'idle');

  if (!open) return null;

  const handleAddItem = () => {
    setLineItems([
      ...lineItems,
      { item_id: '', type: 'refill', quantity: 0, unit_price: 0 }
    ]);
  };

  const handleRemoveItem = (index: number) => {
    setLineItems(lineItems.filter((_, i) => i !== index));
  };

  const handleItemChange = <K extends keyof CreatePurchaseItemPayload>(
    index: number,
    field: K,
    value: CreatePurchaseItemPayload[K],
  ) => {
    const newItems = [...lineItems];
    newItems[index] = { ...newItems[index], [field]: value };
    setLineItems(newItems);
  };

  const calculateSubtotal = () => {
    return lineItems.reduce((sum, item) => sum + (item.quantity * item.unit_price), 0);
  };

  const calculateTotal = () => {
    const subtotal = calculateSubtotal();
    const tCost = parseFloat(transportCost) || 0;
    const lCost = parseFloat(labourCost) || 0;
    return subtotal + tCost + lCost;
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!truckId || !plantId || lineItems.length === 0) return;

    // Validate quantities for refills
    for (const line of lineItems) {
      if (line.type === 'refill') {
        const item = items.find(i => i.item_id === line.item_id);
        if (!item || line.quantity > (item.empty_quantity || 0)) {
          alert(`Insufficient empty stock for selected item. Max available: ${item?.empty_quantity || 0}`);
          return;
        }
      }
      if (line.quantity <= 0 || line.unit_price < 0) {
        alert('Quantities must be greater than 0, and prices cannot be negative.');
        return;
      }
    }

    try {
      await createPurchase.mutateAsync({
        truck_id: truckId,
        plant_id: plantId,
        transport_cost: parseFloat(transportCost) || 0,
        labour_cost: parseFloat(labourCost) || 0,
        notes,
        items: lineItems
      });
      onClose();
    } catch (error: unknown) {
      alert(`Error creating purchase: ${error instanceof Error ? error.message : 'Unknown error'}`);
    }
  };

  return (
    <div className="modal-overlay">
      <div className="modal-content glass-panel" style={{ maxWidth: 'min(94vw, 56.25rem)', width: '100%', maxHeight: 'min(90dvh, 56rem)', display: 'flex', flexDirection: 'column' }}>
        <div className="modal-header">
          <h2 className="modal-title">Create Purchase Order</h2>
          <button className="modal-close" onClick={onClose}>
            <X size={20} />
          </button>
        </div>

        <form onSubmit={handleSubmit} style={{ overflowY: 'auto', padding: '1.5rem', display: 'flex', flexDirection: 'column', gap: '2rem' }}>
          
          {/* Vehicle & Destination Section */}
          <section className="form-section">
            <h3 className="form-section-title">Logistics Details</h3>
            <div className="form-grid">
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
                <label className="input-label">Destination Plant <span style={{ color: 'var(--danger)' }}>*</span></label>
                <div className="input-icon-wrapper">
                  <Factory size={16} className="input-icon" />
                  <select 
                    className="input-field" 
                    value={plantId} 
                    onChange={e => setPlantId(e.target.value)}
                    required
                    style={{ paddingLeft: '2.5rem' }}
                  >
                    <option value="">-- Choose destination --</option>
                    {gasPlants.map(gp => (
                      <option key={gp.plant_id} value={gp.plant_id}>{gp.plant_name} {gp.brand_name ? `(${gp.brand_name})` : ''}</option>
                    ))}
                  </select>
                </div>
              </div>
            </div>
          </section>

          {/* Line Items Section */}
          <section className="form-section">
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '1rem' }}>
              <h3 className="form-section-title" style={{ margin: 0 }}>Line Items</h3>
              <button type="button" className="btn btn-ghost" onClick={handleAddItem} style={{ fontSize: '0.8rem', color: 'var(--primary)' }}>
                <Plus size={14} /> Add Product
              </button>
            </div>

            {lineItems.length === 0 ? (
              <div style={{ textAlign: 'center', padding: '2rem', background: 'rgba(255,255,255,0.02)', borderRadius: 'var(--radius-md)', border: '1px dashed var(--border-color)' }}>
                <Package size={24} style={{ margin: '0 auto 0.5rem', color: 'var(--text-muted)' }} />
                <p style={{ color: 'var(--text-muted)', fontSize: '0.875rem' }}>No products added to this purchase yet.</p>
              </div>
            ) : (
              <div className="line-items-container">
                {lineItems.map((line, index) => {
                  const selectedItem = items.find(i => i.item_id === line.item_id);
                  const maxQty = selectedItem ? (selectedItem.empty_quantity || 0) : 0;
                  
                  return (
                    <div key={index} className="line-item-row glass-panel">
                      <div className="line-item-grid">
                        <div className="input-group" style={{ marginBottom: 0 }}>
                          <label className="input-label">Product</label>
                          <select 
                            className="input-field" 
                            value={line.item_id}
                            onChange={(e) => handleItemChange(index, 'item_id', e.target.value)}
                            required
                          >
                            <option value="">Select product...</option>
                            {items.map(item => (
                              <option key={item.item_id} value={item.item_id}>
                                {item.lpg_brands?.brand_name || item.brand} {item.size_kg}kg
                              </option>
                            ))}
                          </select>
                        </div>

                        <div className="input-group" style={{ marginBottom: 0 }}>
                          <label className="input-label">Purchase Type</label>
                          <select 
                            className="input-field" 
                            value={line.type}
                            onChange={(e) => handleItemChange(index, 'type', e.target.value as PurchaseType)}
                          >
                            <option value="refill">Refill (Exchange)</option>
                            <option value="package">Package (New Filled)</option>
                          </select>
                        </div>

                        <div className="input-group" style={{ marginBottom: 0 }}>
                          <label className="input-label">
                            Quantity 
                            {line.type === 'refill' && selectedItem && (
                              <span style={{ fontSize: '0.7rem', color: 'var(--warning)', marginLeft: '0.5rem' }}>(Max: {maxQty})</span>
                            )}
                          </label>
                          <input 
                            type="number" 
                            className="input-field" 
                            value={line.quantity || ''}
                            onChange={(e) => handleItemChange(index, 'quantity', parseInt(e.target.value) || 0)}
                            min="1"
                            max={line.type === 'refill' ? maxQty : undefined}
                            required
                          />
                        </div>

                        <div className="input-group" style={{ marginBottom: 0 }}>
                          <label className="input-label">Unit Price (Tk)</label>
                          <input 
                            type="number" 
                            className="input-field" 
                            value={line.unit_price || ''}
                            onChange={(e) => handleItemChange(index, 'unit_price', parseFloat(e.target.value) || 0)}
                            min="0"
                            step="0.01"
                            required
                          />
                        </div>

                        <div className="line-item-total">
                          <label className="input-label">Line Total</label>
                          <div className="line-total-value">
                            Tk {((line.quantity || 0) * (line.unit_price || 0)).toLocaleString()}
                          </div>
                        </div>

                        <button type="button" className="btn-remove-line" onClick={() => handleRemoveItem(index)}>
                          <Trash2 size={16} />
                        </button>
                      </div>
                    </div>
                  );
                })}
              </div>
            )}
          </section>

          {/* Costs & Summary Section */}
          <section className="form-section summary-section glass-panel">
            <div className="summary-grid">
              <div className="cost-inputs">
                <h3 className="form-section-title">Additional Costs</h3>
                <div className="input-group">
                  <label className="input-label">Transport Cost (Tk) - <i>Optional</i></label>
                  <input 
                    type="number" 
                    className="input-field" 
                    value={transportCost}
                    onChange={(e) => setTransportCost(e.target.value)}
                    min="0"
                    step="0.01"
                  />
                </div>
                <div className="input-group">
                  <label className="input-label">Labour Cost (Tk) - <i>Optional</i></label>
                  <input 
                    type="number" 
                    className="input-field" 
                    value={labourCost}
                    onChange={(e) => setLabourCost(e.target.value)}
                    min="0"
                    step="0.01"
                  />
                </div>
                <div className="input-group">
                  <label className="input-label">Notes</label>
                  <textarea 
                    className="input-field" 
                    rows={2}
                    value={notes}
                    onChange={(e) => setNotes(e.target.value)}
                  />
                </div>
              </div>

              <div className="totals-display">
                <div className="total-row">
                  <span>Subtotal (Items)</span>
                  <span>Tk {calculateSubtotal().toLocaleString()}</span>
                </div>
                <div className="total-row">
                  <span>Transport Cost</span>
                  <span>Tk {(parseFloat(transportCost) || 0).toLocaleString()}</span>
                </div>
                <div className="total-row">
                  <span>Labour Cost</span>
                  <span>Tk {(parseFloat(labourCost) || 0).toLocaleString()}</span>
                </div>
                <div className="total-divider"></div>
                <div className="total-row grand-total">
                  <span>Grand Total</span>
                  <span>Tk {calculateTotal().toLocaleString()}</span>
                </div>
              </div>
            </div>
          </section>

          <div className="modal-footer" style={{ marginTop: '1rem', paddingTop: '1.5rem', borderTop: '1px solid var(--border-color)', display: 'flex', justifyContent: 'flex-end', gap: '1rem' }}>
            <button type="button" className="btn btn-ghost" onClick={onClose} disabled={createPurchase.isPending}>
              Cancel
            </button>
            <button type="submit" className="btn btn-primary" disabled={createPurchase.isPending || lineItems.length === 0 || !truckId || !plantId}>
              {createPurchase.isPending ? 'Creating...' : 'Create Purchase Order'}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
};
