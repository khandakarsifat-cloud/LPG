import { useState } from 'react';
import { Plus, ShieldAlert, Package, Activity, LayoutGrid } from 'lucide-react';
import { useInventoryBalances, useItems } from '../hooks/useInventory';
import { BalancesGrid } from '../components/inventory/BalancesGrid';
import { MovementsFeed } from '../components/inventory/MovementsFeed';
import { AddItemDialog } from '../components/inventory/AddItemDialog';
import { AdjustmentModal } from '../components/inventory/AdjustmentModal';
import { ITEM_TYPE_LABELS, type ItemType } from '../types/inventory';

type Tab = 'balances' | 'items' | 'history';

export const InventoryPage = () => {
  const { data: balances = [] } = useInventoryBalances();
  const { data: items = [] } = useItems();

  const [tab, setTab] = useState<Tab>('balances');
  const [addItemOpen, setAddItemOpen]     = useState(false);
  const [adjustOpen, setAdjustOpen]       = useState(false);

  // Summary stats
  const totalItems    = items.length;
  const totalUnits    = balances.reduce((s, b) => s + b.current_quantity, 0);
  const outOfStock    = balances.filter((b) => b.current_quantity <= 0).length;
  const lowStock      = balances.filter((b) => b.current_quantity > 0 && b.current_quantity <= 10).length;

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
          <button
            className="btn btn-ghost"
            style={{ border: '1px solid var(--warning)', color: 'var(--warning)' }}
            onClick={() => setAdjustOpen(true)}
          >
            <ShieldAlert size={16} />
            Stock Adjustment
          </button>
          <button className="btn btn-primary" onClick={() => setAddItemOpen(true)}>
            <Plus size={16} />
            Add Item
          </button>
        </div>
      </div>

      {/* ── Stats Row ── */}
      <div className="inv-stats-row">
        <div className="glass-panel inv-stat">
          <div className="inv-stat-icon" style={{ background: 'rgba(59,130,246,0.1)', color: 'var(--primary)' }}>
            <Package size={18} />
          </div>
          <div>
            <div className="inv-stat-value">{totalItems}</div>
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
          { key: 'balances', label: 'Stock Balances', icon: LayoutGrid },
          { key: 'items',    label: 'Item Registry',  icon: Package },
          { key: 'history',  label: 'Movement History', icon: Activity },
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

        {tab === 'items' && (
          <div className="glass-panel">
            {items.length === 0 ? (
              <div className="empty-state" style={{ padding: '3rem' }}>
                <Package size={36} style={{ color: 'var(--text-muted)', opacity: 0.4 }} />
                <p style={{ color: 'var(--text-muted)' }}>No items created yet.</p>
                <button className="btn btn-primary" onClick={() => setAddItemOpen(true)}>
                  <Plus size={15} /> Add First Item
                </button>
              </div>
            ) : (
              <table className="data-table">
                <thead>
                  <tr>
                    <th>Brand</th>
                    <th>Size (KG)</th>
                    <th>Classification</th>
                    <th>Current Stock</th>
                    <th>Created</th>
                  </tr>
                </thead>
                <tbody>
                  {items.map((item) => {
                    const balance = balances.find((b) => b.item_id === item.item_id);
                    const qty = balance?.current_quantity ?? 0;
                    return (
                      <tr key={item.item_id}>
                        <td className="td-strong">{item.brand}</td>
                        <td>{item.size_kg} kg</td>
                        <td>
                          <span className="type-badge">
                            {ITEM_TYPE_LABELS[item.type as ItemType]}
                          </span>
                        </td>
                        <td>
                          <span style={{
                            fontWeight: 600,
                            color: qty <= 0 ? 'var(--danger)' : qty <= 10 ? 'var(--warning)' : 'var(--accent)',
                          }}>
                            {qty.toLocaleString()} units
                          </span>
                        </td>
                        <td style={{ color: 'var(--text-muted)', fontSize: '0.8rem' }}>
                          {new Date(item.created_at).toLocaleDateString()}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            )}
          </div>
        )}

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
      </div>

      {/* ── Dialogs ── */}
      <AddItemDialog open={addItemOpen} onClose={() => setAddItemOpen(false)} />
      <AdjustmentModal open={adjustOpen} onClose={() => setAdjustOpen(false)} />
    </div>
  );
};
