import { useState } from 'react';
import { Plus, Package, Activity, LayoutGrid, ShieldAlert, ShoppingCart } from 'lucide-react';
import { useItems } from '../hooks/useInventory';
import { BalancesGrid } from '../components/inventory/BalancesGrid';
import { MovementsFeed } from '../components/inventory/MovementsFeed';
import { AddItemModal } from '../components/inventory/AddItemModal';
import { PurchasesList } from '../components/purchases/PurchasesList';
import { CreatePurchaseModal } from '../components/purchases/CreatePurchaseModal';

type Tab = 'balances' | 'history' | 'purchases';

export const InventoryPage = () => {
  const { data: items = [] } = useItems();

  const [tab, setTab]                 = useState<Tab>('balances');
  const [addItemOpen, setAddItemOpen] = useState(false);
  const [purchaseOpen, setPurchaseOpen] = useState(false);

  // Summary stats
  const totalSkus  = items.length;
  const totalUnits = items.reduce((s, item) => s + (item.filled_quantity || 0) + (item.empty_quantity || 0), 0);
  const outOfStock = items.filter((item) => (item.filled_quantity || 0) + (item.empty_quantity || 0) <= 0).length;
  const lowStock   = items.filter((item) => {
    const total = (item.filled_quantity || 0) + (item.empty_quantity || 0);
    return total > 0 && total <= 10;
  }).length;

  return (
    <div className="inventory-page">
      {/* ── Page Header ── */}
      <div className="page-header">
        <div>
          <h1 className="page-title">Inventory Ledger</h1>
          <p className="page-subtitle">
            Immutable event-sourced stock tracking — every movement is permanent.
          </p>
        </div>
        <div style={{ display: 'flex', gap: '0.75rem' }}>
          {tab === 'purchases' ? (
            <button className="btn btn-primary" onClick={() => setPurchaseOpen(true)}>
              <Plus size={16} />
              New Purchase
            </button>
          ) : (
            <button className="btn btn-primary" onClick={() => setAddItemOpen(true)}>
              <Plus size={16} />
              Add Item
            </button>
          )}
        </div>
      </div>

      {/* ── Stats Row ── */}
      <div className="inv-stats-row">
        <div className="glass-panel inv-stat">
          <div className="inv-stat-icon" style={{ background: 'rgba(59,130,246,0.1)', color: 'var(--primary)' }}>
            <Package size={18} />
          </div>
          <div>
            <div className="inv-stat-value">{totalSkus}</div>
            <div className="inv-stat-label">Product SKUs</div>
          </div>
        </div>
        <div className="glass-panel inv-stat">
          <div className="inv-stat-icon" style={{ background: 'rgba(16,185,129,0.1)', color: 'var(--accent)' }}>
            <LayoutGrid size={18} />
          </div>
          <div>
            <div className="inv-stat-value">{totalUnits.toLocaleString()}</div>
            <div className="inv-stat-label">Total Units on Hand</div>
          </div>
        </div>
        <div className="glass-panel inv-stat">
          <div className="inv-stat-icon" style={{ background: 'rgba(245,158,11,0.1)', color: 'var(--warning)' }}>
            <Activity size={18} />
          </div>
          <div>
            <div className="inv-stat-value">{lowStock}</div>
            <div className="inv-stat-label">Low Stock Items</div>
          </div>
        </div>
        <div className="glass-panel inv-stat">
          <div className="inv-stat-icon" style={{ background: 'rgba(239,68,68,0.1)', color: 'var(--danger)' }}>
            <ShieldAlert size={18} />
          </div>
          <div>
            <div className="inv-stat-value">{outOfStock}</div>
            <div className="inv-stat-label">Out of Stock</div>
          </div>
        </div>
      </div>

      {/* ── Tabs ── */}
      <div className="inv-tabs">
        {([
          { key: 'balances', label: 'Stock Balances',    icon: LayoutGrid },
          { key: 'history',  label: 'Movement History',  icon: Activity },
          { key: 'purchases', label: 'Purchases', icon: ShoppingCart },
        ] as { key: Tab; label: string; icon: React.ElementType }[]).map(({ key, label, icon: Icon }) => (
          <button
            key={key}
            className={`inv-tab ${tab === key ? 'inv-tab-active' : ''}`}
            onClick={() => setTab(key)}
          >
            <Icon size={15} />
            {label}
          </button>
        ))}
      </div>

      {/* ── Tab Content ── */}
      <div className="inv-tab-content">
        {tab === 'balances' && <BalancesGrid />}

        {tab === 'history' && (
          <div className="glass-panel" style={{ padding: '1.25rem' }}>
            <div style={{ marginBottom: '1rem', display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
              <h3 style={{ fontWeight: 600 }}>Movement History</h3>
              <span style={{ fontSize: '0.75rem', color: 'var(--text-muted)' }}>
                Immutable — no entries may be deleted
              </span>
            </div>
            <MovementsFeed />
          </div>
        )}

        {tab === 'purchases' && (
          <div className="glass-panel" style={{ padding: '1.25rem' }}>
            <div style={{ marginBottom: '1rem', display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
              <h3 style={{ fontWeight: 600 }}>Purchase Orders</h3>
              <span style={{ fontSize: '0.75rem', color: 'var(--text-muted)' }}>
                Track incoming stock from gas plants
              </span>
            </div>
            <PurchasesList />
          </div>
        )}
      </div>

      {/* ── Dialogs ── */}
      <AddItemModal open={addItemOpen} onClose={() => setAddItemOpen(false)} />
      <CreatePurchaseModal open={purchaseOpen} onClose={() => setPurchaseOpen(false)} />
    </div>
  );
};
