import { useRef, useState } from 'react';
import { Activity, ShoppingBag, Truck, Droplets, Box, Package, RotateCcw, ChevronLeft, ChevronRight, RefreshCw, CalendarDays } from 'lucide-react';
import { useInventoryBalances, useInventoryHistory } from '../../hooks/useInventory';
import { useLPGBrands } from '../../hooks/useBrands';
import { usePurchases } from '../../hooks/usePurchases';
import { useAuth } from '../../contexts/AuthContext';
import { inventoryMovementActions, inventoryMovementSource, type InventoryHistorySource } from '../../lib/inventoryMovement';
import { PurchaseDialog, PurchaseSelect } from '../purchases/PurchaseControls';
import { UpdatePurchaseModal } from '../purchases/UpdatePurchaseModal';
import { TransactionDetailsModal } from '../transactions/TransactionDetailsModal';
import { InventoryProductPicker } from './InventoryProductPicker';
import { DatePicker } from '../ui/DatePicker';
import '../purchases/purchases.css';
import './inventory.css';

export const MovementsFeed = () => {
  const { can } = useAuth();
  const [filters, setFilters] = useState<{ source: InventoryHistorySource; itemIds: string[] | null; page: number; from: string; to: string }>({ source: 'all', itemIds: null, page: 0, from: '', to: '' });
  const [pickerOpen, setPickerOpen] = useState(false);
  const [timelineOpen, setTimelineOpen] = useState(false);
  const [timeline, setTimeline] = useState({ from: '', to: '' });
  const [detail, setDetail] = useState<{ kind: 'sale' | 'purchase'; id: string } | null>(null);
  const opener = useRef<HTMLButtonElement | null>(null);
  const history = useInventoryHistory(filters);
  const items = useInventoryBalances();
  const brands = useLPGBrands();
  const canReadPurchases = can('purchases:view') || can('purchases:manage');
  const canReadSales = can('sales:view') || can('receipts:print') || can('dashboard:view');
  const purchaseIds = [...new Set([...(history.data?.entries ?? []).flatMap(movement => {
    const ref = inventoryMovementSource(movement);
    return ref.kind === 'purchase' && ref.id ? [ref.id] : [];
  }), ...(detail?.kind === 'purchase' ? [detail.id] : [])])].sort();
  const purchases = usePurchases({ ids: purchaseIds, enabled: canReadPurchases });
  const selectedPurchase = detail?.kind === 'purchase' ? purchases.data?.find(purchase => purchase.purchase_id === detail.id) : null;
  const hasFilters = filters.source !== 'all' || filters.itemIds !== null || Boolean(filters.from || filters.to);
  const reset = () => setFilters({ source: 'all', itemIds: null, page: 0, from: '', to: '' });
  const shortDate = (value: string) => value ? new Date(`${value}T12:00:00Z`).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', timeZone: 'Asia/Dhaka' }) : '';
  const timelineLabel = filters.from || filters.to ? `${shortDate(filters.from) || 'Start'} – ${shortDate(filters.to) || 'Today'}` : 'All dates';
  const closeDetail = () => { setDetail(null); requestAnimationFrame(() => opener.current?.focus()); };

  return <div className="inv-history">
    <div className="inv-history-toolbar filter-toolbar" data-filtered={hasFilters} aria-label="Inventory history filters">
      <PurchaseSelect label="Activity" value={filters.source} options={[{ value: 'all', label: 'All activity' }, { value: 'purchase', label: 'Purchase' }, { value: 'sale', label: 'Sale' }]}
        onChange={value => setFilters(previous => ({ ...previous, source: value === 'sale' ? 'sale' : value === 'purchase' ? 'purchase' : 'all', page: 0 }))} />
      <div className="input-group inv-product-filter"><span className="input-label">Products</span>
        <button className="btn btn-secondary" aria-label="Select products" onClick={() => setPickerOpen(true)} disabled={items.isPending || items.isError || brands.isPending || brands.isError}>
          <Package size={14} /><span>Products</span><span className="inv-filter-count">{filters.itemIds === null ? 'All' : filters.itemIds.length}</span></button></div>
      <div className="input-group inv-timeline-filter"><span className="input-label">Timeline</span>
        <button className="btn btn-secondary" aria-label="Filter inventory history dates" title={filters.from || filters.to ? `${filters.from || 'Start'} to ${filters.to || 'Today'}` : 'All dates'}
          data-filtered={Boolean(filters.from || filters.to)} onClick={() => { setTimeline({ from: filters.from, to: filters.to }); setTimelineOpen(true); }}>
          <CalendarDays size={14} /><span>{timelineLabel}</span></button></div>
    </div>
    {(items.isError || brands.isError) && <p className="product-error" role="alert">Product selection could not be loaded.
      <button className="btn btn-ghost" onClick={() => { void items.refetch(); void brands.refetch(); }}>Retry products</button></p>}
    {canReadPurchases && purchases.isError && <p className="product-error" role="alert">Purchase names and details could not be loaded.
      <button className="btn btn-ghost" onClick={() => void purchases.refetch()}>Retry purchases</button></p>}
    <div className="inv-history-heading"><h3>Inventory history</h3><div className="inv-history-actions-bar">
      <button className="btn btn-ghost inv-clear-filters" onClick={reset} disabled={!hasFilters}><RotateCcw size={14} />Clear filters</button>
      <button className="btn btn-ghost" disabled={history.isFetching} onClick={() => { void history.refetch(); if (canReadPurchases) void purchases.refetch(); }}>
        <RefreshCw size={13} className={history.isFetching ? 'spin' : ''} />Refresh</button></div></div>
    {history.isSuccess && <nav className="inv-history-pagination" aria-label="Inventory history pages">
      <button className="btn btn-secondary" disabled={filters.page === 0 || history.isFetching} onClick={() => setFilters(previous => ({ ...previous, page: previous.page - 1 }))}><ChevronLeft size={15} />Previous</button>
      <span>Page {filters.page + 1}</span><button className="btn btn-secondary" disabled={!history.data.hasMore || history.isFetching} onClick={() => setFilters(previous => ({ ...previous, page: previous.page + 1 }))}>Next<ChevronRight size={15} /></button></nav>}
    {history.isPending && <div role="status" className="inv-history-empty">Loading inventory history…</div>}
    {history.isError && <div role="alert" className="product-error">Inventory history could not be loaded.
      <button className="btn btn-secondary" onClick={() => void history.refetch()}>Retry history</button></div>}
    {history.isSuccess && !history.data.entries.length && <div className="inv-history-empty"><Activity size={26} />
      <p>{hasFilters ? 'No inventory history matches these filters.' : 'No inventory history yet.'}</p>
      {hasFilters && <button className="btn btn-secondary" onClick={reset}>Clear filters</button>}</div>}
    {history.isSuccess && <div className="movements-feed">{history.data.entries.map(movement => {
      const ref = inventoryMovementSource(movement);
      const purchase = ref.kind === 'purchase' ? purchases.data?.find(entry => entry.purchase_id === ref.id) : null;
      const name = ref.kind === 'sale' ? movement.saleCustomer : purchase?.plant_name ?? null;
      const actions = inventoryMovementActions(movement, ref.kind, name);
      const readable = ref.kind === 'sale' ? canReadSales : ref.kind === 'purchase' && canReadPurchases;
      const item = movement.items;
      const reference = ref.id ? `#${ref.id.slice(0, 8).toUpperCase()}` : null;
      const created = new Date(movement.created_at);
      const Icon = ref.kind === 'sale' ? ShoppingBag : ref.kind === 'purchase' ? Truck : Activity;
      return <article className="movement-row inv-history-row" key={movement.movement_id}>
        <div className={`movement-icon inv-history-icon inv-history-icon-${ref.kind ?? 'other'}`}><Icon size={18} /></div>
        <div className="movement-info">
          <div className="movement-item-name">{item ? `${item.lpg_brands?.brand_name ?? item.brand} ${item.size_kg} kg${item.mouth_size ? ` · ${item.mouth_size}` : ''}` : 'Product unavailable'}</div>
          <div className="inv-history-actions">{actions.map((action, index) => <p key={index}>{action}{reference && <> {' '}{readable && ref.id && ref.kind
            ? <button className="inv-history-reference" title={`${ref.kind === 'sale' ? 'POS sale' : 'Purchase'} ${ref.id}`} onClick={event => {
              opener.current = event.currentTarget;
              if (ref.id && ref.kind) setDetail({ kind: ref.kind, id: ref.id });
            }}>{reference}</button>
            : <span className="inv-history-reference-text" title="You do not have access to these transaction details">{reference}</span>}</>}</p>)}</div>
          <div className="inv-history-meta"><time dateTime={movement.created_at} title={created.toLocaleString('en-BD', { timeZone: 'Asia/Dhaka' })}>
            {created.toLocaleDateString('en-BD', { timeZone: 'Asia/Dhaka', day: 'numeric', month: 'short', year: 'numeric' })} · {created.toLocaleTimeString('en-BD', { timeZone: 'Asia/Dhaka', hour: 'numeric', minute: '2-digit' })}</time>
            {movement.user_profiles?.email && <span>by {movement.user_profiles.email.split('@')[0]}</span>}</div>
        </div>
        <div className="inv-history-quantities">{([{ value: movement.filled_quantity_change, label: 'Filled', icon: Droplets }, { value: movement.empty_quantity_change, label: 'Empty', icon: Box }]).filter(entry => entry.value !== 0).map(({ value, label, icon: QuantityIcon }) =>
          <span key={label} className={value > 0 ? 'inv-quantity-in' : 'inv-quantity-out'} aria-label={`${value > 0 ? '+' : ''}${value} ${label.toLowerCase()}`} title={label}>
            <QuantityIcon size={14} aria-hidden="true" />{value > 0 ? '+' : ''}{value.toLocaleString()}</span>)}</div>
      </article>;
    })}</div>}
    {timelineOpen && <PurchaseDialog title="Inventory history dates" subtitle="Include transactions from both selected dates, Bangladesh time." onClose={() => setTimelineOpen(false)} compact>
      <div className="modal-body inv-timeline-fields">
        <div className="input-group"><label className="input-label" htmlFor="inventory-history-from">From</label><DatePicker id="inventory-history-from" label="From" value={timeline.from} max={timeline.to || undefined} onChange={from => setTimeline(previous => ({ ...previous, from }))} /></div>
        <div className="input-group"><label className="input-label" htmlFor="inventory-history-to">To</label><DatePicker id="inventory-history-to" label="To" value={timeline.to} min={timeline.from || undefined} onChange={to => setTimeline(previous => ({ ...previous, to }))} /></div>
      </div>
      <div className="modal-footer"><button className="btn btn-secondary" onClick={() => setTimelineOpen(false)}>Cancel</button><button className="btn btn-ghost" onClick={() => setTimeline({ from: '', to: '' })}>Clear dates</button>
        <button className="btn btn-primary" disabled={Boolean(timeline.from && timeline.to && timeline.from > timeline.to)} onClick={() => { setFilters(previous => ({ ...previous, ...timeline, page: 0 })); setTimelineOpen(false); }}>Apply dates</button></div>
    </PurchaseDialog>}
    {pickerOpen && <InventoryProductPicker items={items.data ?? []} brands={brands.data ?? []} selected={filters.itemIds} onClose={() => setPickerOpen(false)}
      onApply={itemIds => { setFilters(previous => ({ ...previous, itemIds, page: 0 })); setPickerOpen(false); }} />}
    {detail?.kind === 'sale' && canReadSales && <TransactionDetailsModal saleId={detail.id} onClose={closeDetail} returnLabel="Back to history" />}
    {detail?.kind === 'purchase' && (selectedPurchase ? <UpdatePurchaseModal open purchase={selectedPurchase} onClose={closeDetail} />
      : <PurchaseDialog title={`Purchase #${detail.id.slice(0, 8).toUpperCase()}`} onClose={closeDetail} compact><div className="modal-body">
        {purchases.isPending ? <p role="status">Loading purchase…</p> : <p role="alert">This purchase could not be loaded. <button className="btn btn-secondary" onClick={() => void purchases.refetch()}>Retry purchase</button></p>}</div></PurchaseDialog>)}
  </div>;
};
