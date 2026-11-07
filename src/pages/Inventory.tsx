import { StoveInventory, StoveInventorySummary } from '../components/inventory/StoveInventory';
import { InventoryAdjustmentDialog } from '../components/inventory/InventoryAdjustments';
import { useState } from 'react';
import { Plus, Activity, LayoutGrid, SlidersHorizontal } from 'lucide-react';
import { useInventoryBalances, useInventoryValuation } from '../hooks/useInventory';
import { useLPGBrands } from '../hooks/useBrands';
import { formatBDT } from '../lib/formatBDT';
import { useAuth } from '../contexts/AuthContext';
import { BalancesGrid } from '../components/inventory/BalancesGrid';
import { MovementsFeed } from '../components/inventory/MovementsFeed';
import { AddItemModal } from '../components/inventory/AddItemModal';
import { useSearchParams } from 'react-router-dom';
import { StockAlerts } from '../components/inventory/StockAlerts';

type Tab = 'balances' | 'history' | 'stove' | 'alerts';

export const InventoryPage = () => {
  const [params] = useSearchParams();
  const { data: items = [], isPending, isError } = useInventoryBalances();
  const { can } = useAuth();
  const brands = useLPGBrands();
  const valuation = useInventoryValuation();
  const [adjusting, setAdjusting] = useState(false);

  const [tab, setTab]                 = useState<Tab>(params.get('stock') === 'low' ? 'alerts' : 'balances');
  const [addItemOpen, setAddItemOpen] = useState(false);

  const filledTotal = items.reduce((sum, i) => sum + i.filled_quantity, 0);
  const emptyTotal  = items.reduce((sum, i) => sum + i.empty_quantity, 0);
  const lowFilled   = items.filter(i => i.filled_quantity < i.low_stock_threshold).length;
  const lowEmpty    = items.filter(i => i.empty_quantity < i.low_stock_threshold).length;
  const outFilled   = items.filter(i => i.filled_quantity === 0).length;
  const outEmpty    = items.filter(i => i.empty_quantity === 0).length;
  const activeBrandsCount = brands.data?.filter(brand => brand.is_active).length ?? 0;

  return (
    <div className="inventory-page">
      {/* ── Overview Toolbar: Unified Command Hub Bar ── */}
      <div className="inv-hub-bar inv-overview-toolbar">
        <div className="inv-hub-metrics inv-overview">{tab === 'stove' ? <StoveInventorySummary /> : <>
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
          <div className="inv-hub-module inv-overview-box" title="Products below their configured stock thresholds">
            <span className="inv-hub-label inv-overview-label">
              <span className="inv-hub-dot" style={{ background: 'var(--warning)' }} />
              Below Threshold
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
        </>} </div>

        {can('inventory:create') && (
          <div className="inv-hub-action">
            <button
              className="btn btn-primary inv-hub-btn"
              aria-label="Add Item"
              title="Add Item"
              onClick={() => setAddItemOpen(true)}
            >
              <Plus size={16} strokeWidth={2.5} />
              <span>Add Item</span>
            </button>
          </div>
        )}
      </div>

      {/* ── Valuation Summary ── */}
      <section className="inventory-worth" aria-label="Stock worth">
        <span>Total owned stock worth <strong>{valuation.data ? formatBDT(valuation.data.known_value) : '—'}</strong></span>
        {valuation.data && <small>LPG {formatBDT(valuation.data.lpg_value)} · Stove {formatBDT(valuation.data.stove_value)} · FIFO{valuation.data.reconstructed_products > 0 ? ' · Includes estimated development opening values' : ''}</small>}
        {!!valuation.data?.internal_transport_value && <small>Includes {formatBDT(valuation.data.internal_transport_value)} attributable internal transport and owned bottles in transit.</small>}
        {valuation.error && <button className="btn btn-secondary" onClick={() => void valuation.refetch()}>Retry valuation</button>}
      </section>

      {/* ── Tabs & Actions Row ── */}
      <div className="inv-tabs-bar">
        <div className="inv-tabs" aria-label="Inventory catalogs">
          {([
            { key: 'stove', label: 'Stove Business', icon: LayoutGrid },
            { key: 'balances', label: 'Stock Balances',    icon: LayoutGrid },
            { key: 'history',  label: 'Inventory History',  icon: Activity },
            { key: 'alerts', label: 'Stock Alerts', icon: SlidersHorizontal },
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

        <div className="inv-tabs-actions">
          {can('inventory:adjust') && tab !== 'history' && tab !== 'alerts' && (
            <button
              type="button"
              className="btn btn-secondary inv-tab-action-btn"
              aria-label="Adjustment"
              title="Record stock adjustment"
              onClick={() => setAdjusting(true)}
            >
              <SlidersHorizontal size={14} />
              <span>Adjustment</span>
            </button>
          )}
        </div>
      </div>

      {/* ── Tab Content ── */}
      <div className="inv-tab-content">{tab === 'stove' && <StoveInventory creating={addItemOpen} onCloseCreate={() => setAddItemOpen(false)} />}
        {tab === 'balances' && <BalancesGrid />}

        {tab === 'history' && <MovementsFeed />}
        {tab === 'alerts' && <StockAlerts initiallyLow={params.get('stock') === 'low'} />}
      </div>

      {/* ── Dialogs ── */}
      {adjusting && <InventoryAdjustmentDialog category={tab === 'stove' ? 'stove' : 'lpg'} onClose={() => setAdjusting(false)} />}
      <AddItemModal open={addItemOpen && tab !== 'stove'} onClose={() => setAddItemOpen(false)} />
    </div>
  );
};
