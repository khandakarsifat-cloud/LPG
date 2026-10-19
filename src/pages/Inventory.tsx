import { useState } from 'react';
import { Plus, Activity, LayoutGrid, Droplets, Box, Package, Factory } from 'lucide-react';
import { useInventoryBalances } from '../hooks/useInventory';
import { useLPGBrands } from '../hooks/useBrands';
import { useAuth } from '../contexts/AuthContext';
import { BalancesGrid } from '../components/inventory/BalancesGrid';
import { MovementsFeed } from '../components/inventory/MovementsFeed';
import { AddItemModal } from '../components/inventory/AddItemModal';

type Tab = 'balances' | 'history';

export const InventoryPage = () => {
  const { data: items = [], isPending, isError } = useInventoryBalances();
  const { can } = useAuth();
  const brands = useLPGBrands();

  const [tab, setTab]                 = useState<Tab>('balances');
  const [addItemOpen, setAddItemOpen] = useState(false);

  const summaries = [
    { label: 'Total Units', filled: items.reduce((sum, i) => sum + i.filled_quantity, 0), empty: items.reduce((sum, i) => sum + i.empty_quantity, 0), hint: 'Units on hand' },
    { label: 'Low Stock', filled: items.filter(i => i.filled_quantity > 0 && i.filled_quantity <= 5).length, empty: items.filter(i => i.empty_quantity > 0 && i.empty_quantity <= 5).length, hint: 'Products with 1–5 units' },
    { label: 'Out of Stock', filled: items.filter(i => i.filled_quantity === 0).length, empty: items.filter(i => i.empty_quantity === 0).length, hint: 'Products with zero units' },
  ];

  return (
    <div className="inventory-page">
      {/* ── Stats Row ── */}
      <div className="inv-overview-toolbar">
        <div className="inv-overview">
          {summaries.map(summary => <div className="inv-overview-box" key={summary.label} title={summary.hint}>
            <span className="inv-overview-label">{summary.label}</span>
            <div className="inv-overview-counts">
              <span className="inv-overview-filled" aria-label={`${summary.label}: ${summary.filled} filled`} title="Filled">
                <Droplets size={15} aria-hidden="true" />{isPending || isError ? '—' : summary.filled.toLocaleString()}
              </span>
              <span className="inv-overview-empty" aria-label={`${summary.label}: ${summary.empty} empty`} title="Empty">
                <Box size={15} aria-hidden="true" />{isPending || isError ? '—' : summary.empty.toLocaleString()}
              </span>
            </div>
          </div>)}
          <div className="inv-overview-box" title="Registered products and active brands in this business">
            <span className="inv-overview-label">Items / active brands</span>
            <div className="inv-overview-counts inv-catalog-counts">
              <span aria-label={`Total items: ${items.length}`} title="Total items"><Package size={15} aria-hidden="true" />{isPending || isError ? '—' : items.length.toLocaleString()}</span>
              <span aria-label={`Total active brands: ${brands.data?.filter(brand => brand.is_active).length ?? 0}`} title="Total active brands"><Factory size={15} aria-hidden="true" />{brands.isPending || brands.isError ? '—' : brands.data.filter(brand => brand.is_active).length.toLocaleString()}</span>
            </div>
          </div>
        </div>
        {can('inventory:manage') && <button className="btn btn-primary inv-add-item" aria-label="Add Item" title="Add Item" onClick={() => setAddItemOpen(true)}><Plus size={16} /><span>Add Item</span></button>}
      </div>

      {/* ── Tabs ── */}
      <div className="inv-tabs">
        {([
          { key: 'balances', label: 'Stock Balances',    icon: LayoutGrid },
          { key: 'history',  label: 'Inventory History',  icon: Activity },
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

        {tab === 'history' && <MovementsFeed />}
      </div>

      {/* ── Dialogs ── */}
      <AddItemModal open={addItemOpen} onClose={() => setAddItemOpen(false)} />
    </div>
  );
};
