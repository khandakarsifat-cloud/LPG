import { useState } from 'react';
import { Plus, Activity, LayoutGrid } from 'lucide-react';
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

  const filledTotal = items.reduce((sum, i) => sum + i.filled_quantity, 0);
  const emptyTotal  = items.reduce((sum, i) => sum + i.empty_quantity, 0);
  const lowFilled   = items.filter(i => i.filled_quantity > 0 && i.filled_quantity <= 5).length;
  const lowEmpty    = items.filter(i => i.empty_quantity > 0 && i.empty_quantity <= 5).length;
  const outFilled   = items.filter(i => i.filled_quantity === 0).length;
  const outEmpty    = items.filter(i => i.empty_quantity === 0).length;
  const activeBrandsCount = brands.data?.filter(brand => brand.is_active).length ?? 0;

  return (
    <div className="inventory-page">
      {/* ── Overview Toolbar: Unified Command Hub Bar ── */}
      <div className="inv-hub-bar inv-overview-toolbar">
        <div className="inv-hub-metrics inv-overview">
          {/* Module 1: Total Units */}
          <div className="inv-hub-module inv-overview-box" title="Units on hand">
            <span className="inv-hub-label inv-overview-label">
              <span className="inv-hub-dot" style={{ background: 'var(--primary)' }} />
              Total Units
            </span>
            <div className="inv-hub-values inv-overview-counts">
              <span className="inv-hub-chip" aria-label={`Total Units: ${filledTotal} filled`}>
                <strong className="inv-hub-num inv-overview-filled" style={{ color: 'var(--primary)' }}>
                  {isPending || isError ? '—' : filledTotal.toLocaleString()}
                </strong>
                <span className="inv-hub-caption">filled</span>
              </span>
              <span className="inv-hub-chip" aria-label={`Total Units: ${emptyTotal} empty`}>
                <strong className="inv-hub-num inv-overview-empty" style={{ color: 'var(--warning)' }}>
                  {isPending || isError ? '—' : emptyTotal.toLocaleString()}
                </strong>
                <span className="inv-hub-caption">empty</span>
              </span>
            </div>
          </div>

          {/* Module 2: Low Stock */}
          <div className="inv-hub-module inv-overview-box" title="Products with 1–5 units">
            <span className="inv-hub-label inv-overview-label">
              <span className="inv-hub-dot" style={{ background: 'var(--warning)' }} />
              Low Stock (1–5)
            </span>
            <div className="inv-hub-values inv-overview-counts">
              <span className="inv-hub-chip" aria-label={`Low Stock: ${lowFilled} filled`}>
                <strong className="inv-hub-num inv-overview-filled">{isPending || isError ? '—' : lowFilled.toLocaleString()}</strong>
                <span className="inv-hub-caption">filled</span>
              </span>
              <span className="inv-hub-chip" aria-label={`Low Stock: ${lowEmpty} empty`}>
                <strong className="inv-hub-num inv-overview-empty" style={{ color: 'var(--warning)' }}>{isPending || isError ? '—' : lowEmpty.toLocaleString()}</strong>
                <span className="inv-hub-caption">empty</span>
              </span>
            </div>
          </div>

          {/* Module 3: Out of Stock */}
          <div className="inv-hub-module inv-overview-box" title="Products with zero units">
            <span className="inv-hub-label inv-overview-label">
              <span className="inv-hub-dot" style={{ background: 'var(--danger)' }} />
              Out of Stock
            </span>
            <div className="inv-hub-values inv-overview-counts">
              <span className="inv-hub-chip" aria-label={`Out of Stock: ${outFilled} filled`}>
                <strong className="inv-hub-num inv-overview-filled" style={{ color: outFilled > 0 ? 'var(--danger)' : 'inherit' }}>
                  {isPending || isError ? '—' : outFilled.toLocaleString()}
                </strong>
                <span className="inv-hub-caption">filled</span>
              </span>
              <span className="inv-hub-chip" aria-label={`Out of Stock: ${outEmpty} empty`}>
                <strong className="inv-hub-num inv-overview-empty" style={{ color: outEmpty > 0 ? 'var(--danger)' : 'inherit' }}>
                  {isPending || isError ? '—' : outEmpty.toLocaleString()}
                </strong>
                <span className="inv-hub-caption">empty</span>
              </span>
            </div>
          </div>

          {/* Module 4: Catalog */}
          <div className="inv-hub-module inv-overview-box" title="Registered products and active brands in this business">
            <span className="inv-hub-label inv-overview-label">
              <span className="inv-hub-dot" style={{ background: 'var(--info)' }} />
              Catalog
            </span>
            <div className="inv-hub-values inv-overview-counts inv-catalog-counts">
              <span className="inv-hub-chip" aria-label={`Total items: ${items.length}`} title="Total items">
                <strong className="inv-hub-num">{isPending || isError ? '—' : items.length.toLocaleString()}</strong>
                <span className="inv-hub-caption">SKUs</span>
              </span>
              <span className="inv-hub-chip" aria-label={`Total active brands: ${activeBrandsCount}`} title="Total active brands">
                <strong className="inv-hub-num">{brands.isPending || brands.isError ? '—' : activeBrandsCount.toLocaleString()}</strong>
                <span className="inv-hub-caption">brands</span>
              </span>
            </div>
          </div>
        </div>

        {can('inventory:manage') && (
          <div className="inv-hub-action">
            <button
              className="btn btn-primary inv-hub-btn"
              aria-label="Add Item"
              title="Add Item"
              onClick={() => setAddItemOpen(true)}
            >
              <Plus size={18} strokeWidth={2.5} />
              <span>Add Item</span>
            </button>
          </div>
        )}
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
