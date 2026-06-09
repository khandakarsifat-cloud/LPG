import { useState } from 'react';
import { format } from 'date-fns';
import { Package, Truck, Calendar, MapPin, Search } from 'lucide-react';
import { usePurchases } from '../../hooks/usePurchases';
import { PURCHASE_STATUS_LABELS, PURCHASE_STATUS_COLORS, PURCHASE_STATUS_BG } from '../../types/purchase';
import { UpdatePurchaseModal } from './UpdatePurchaseModal';
import type { Purchase } from '../../types/purchase';

export const PurchasesList = () => {
  const { data: purchases = [], isLoading } = usePurchases();
  const [selectedPurchase, setSelectedPurchase] = useState<Purchase | null>(null);

  if (isLoading) {
    return (
      <div className="glass-panel" style={{ padding: '3rem', textAlign: 'center', color: 'var(--text-muted)' }}>
        <div className="loader-ring" style={{ margin: '0 auto 1rem' }} />
        Loading purchases...
      </div>
    );
  }

  if (purchases.length === 0) {
    return (
      <div className="glass-panel" style={{ padding: '4rem 2rem', textAlign: 'center' }}>
        <div style={{
          width: '64px', height: '64px', borderRadius: '50%', background: 'rgba(59,130,246,0.1)',
          display: 'flex', alignItems: 'center', justifyContent: 'center', margin: '0 auto 1.5rem', color: 'var(--primary)'
        }}>
          <Package size={32} />
        </div>
        <h3 style={{ fontSize: '1.25rem', fontWeight: 600, marginBottom: '0.5rem' }}>No Purchases Yet</h3>
        <p style={{ color: 'var(--text-muted)', maxWidth: '400px', margin: '0 auto' }}>
          Create a new purchase order to start tracking incoming inventory from gas plants.
        </p>
      </div>
    );
  }

  return (
    <div className="purchases-list">
      <div className="purchases-toolbar">
        <div className="topbar-search" style={{ width: '300px' }}>
          <Search size={16} className="topbar-search-icon" />
          <input type="text" placeholder="Search purchases..." className="input-field topbar-search-input" />
        </div>
      </div>

      <div className="purchases-grid">
        {purchases.map((purchase) => (
          <div 
            key={purchase.purchase_id} 
            className="glass-panel purchase-card"
            onClick={() => setSelectedPurchase(purchase)}
            style={{ cursor: 'pointer' }}
          >
            <div className="purchase-card-header">
              <div className="purchase-card-id">
                <span className="hash">#</span>
                {purchase.purchase_id.slice(0, 8).toUpperCase()}
              </div>
              <div 
                className="purchase-badge" 
                style={{ 
                  backgroundColor: PURCHASE_STATUS_BG[purchase.status],
                  color: PURCHASE_STATUS_COLORS[purchase.status],
                  borderColor: `rgba(${PURCHASE_STATUS_COLORS[purchase.status]}, 0.2)`
                }}
              >
                {PURCHASE_STATUS_LABELS[purchase.status]}
              </div>
            </div>

            <div className="purchase-card-body">
              <div className="purchase-info-row">
                <Calendar size={14} />
                <span>{format(new Date(purchase.created_at), 'MMM d, yyyy • h:mm a')}</span>
              </div>
              <div className="purchase-info-row">
                <MapPin size={14} />
                <span>{purchase.plant_name}</span>
              </div>
              <div className="purchase-info-row">
                <Truck size={14} />
                <span>{purchase.truck_name}</span>
              </div>
            </div>

            <div className="purchase-items-preview">
              <div className="purchase-items-count">
                {purchase.items?.length || 0} Line Items
              </div>
              <div className="purchase-items-list">
                {purchase.items?.slice(0, 3).map((item, idx) => (
                  <div key={item.purchase_item_id || idx} className="purchase-item-pill">
                    <span className="pill-qty">{item.quantity}x</span>
                    <span className="pill-name">{item.brand_name} {item.size_kg}kg ({item.type})</span>
                  </div>
                ))}
                {purchase.items && purchase.items.length > 3 && (
                  <div className="purchase-item-pill more">+{purchase.items.length - 3} more</div>
                )}
              </div>
            </div>

            <div className="purchase-card-footer">
              <div className="purchase-total-label">Total Cost</div>
              <div className="purchase-total-value">৳ {Number(purchase.total_cost).toLocaleString()}</div>
            </div>
          </div>
        ))}
      </div>

      <UpdatePurchaseModal 
        open={selectedPurchase !== null}
        onClose={() => setSelectedPurchase(null)}
        purchase={selectedPurchase}
      />
    </div>
  );
};
