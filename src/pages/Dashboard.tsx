import { lazy, Suspense, useCallback, useState, type ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { ArrowRight, ArrowUpRight, ArrowDownRight, Banknote, CircleAlert, ClipboardList, Clock3, Coins, Cylinder, Package, Printer, ReceiptText, ShoppingBag, ShoppingCart, Truck, Users, Wallet } from 'lucide-react';
import { formatDistanceToNow } from 'date-fns';
import { FinancialEntryDialog } from '../components/finance/FinancialEntry';
import { PrinterConfigModal } from '../components/dashboard/PrinterConfigModal';
import { SalesFeed } from '../components/dashboard/SalesFeed';
import { StoveTypeSummary } from '../components/dashboard/StoveTypeSummary';
import { TransactionDetailsModal } from '../components/transactions/TransactionDetailsModal';
import { PurchaseDialog } from '../components/purchases/PurchaseControls';
import { PageNavigation } from '../components/ui/Pagination';
import { useDashboardActivity, useDashboardStats } from '../hooks/useDashboard';
import { formatBDQty, formatBDT } from '../lib/formatBDT';
import { useAuth } from '../contexts/AuthContext';
import type { DashboardActivity, DashboardDay } from '../types/dashboard';
import './dashboard.css';

const RelatedRecord = lazy(() => import('../components/finance/AccountingBreakdown').then(module => ({ default: module.RelatedRecord })));
const activityIcons = { sale: ShoppingCart, purchase: Truck, payment: Users, financial_entry: ReceiptText };
function Panel({ title, icon, action, children, className = '' }: { title: string; icon: ReactNode; action?: ReactNode; children: ReactNode; className?: string }) {
  return <section className={`dashboard-panel ${className}`}><header className="dashboard-panel-heading"><span className="dashboard-heading-icon">{icon}</span><h2>{title}</h2>{action}</header>{children}</section>;
}
function Metric({ title, field, days, icon, tone, unavailable, count = false, inverse = false, description }: {
  title: string; field: keyof Omit<DashboardDay, 'date'>; days: DashboardDay[]; icon: ReactNode; tone: string; unavailable?: boolean; count?: boolean; inverse?: boolean; description: string;
}) {
  const current = days.at(-1)?.[field]; const previous = days.at(-2)?.[field];
  const values = days.map(day => day[field] ?? 0); const min = Math.min(0, ...values); const max = Math.max(1, ...values);
  const points = values.map((value, i) => `${4 + i * 12},${36 - (value - min) / (max - min) * 30}`).join(' ');
  const difference = current != null && previous != null ? current - previous : null;
  const TrendIcon = (difference ?? 0) < 0 ? ArrowDownRight : ArrowUpRight;
  const change = difference === null ? '—' : difference === 0 ? 'No change' : !previous ? 'From zero' : `${difference > 0 ? '+' : ''}${new Intl.NumberFormat('en-BD', { maximumFractionDigits: 1 }).format(difference / Math.abs(previous) * 100)}%`;
  return <section className={`dashboard-metric tone-${tone}`} title={description}>
    <span className="dashboard-metric-icon">{icon}</span><div className="dashboard-metric-content"><h2>{title}</h2>
      <strong className="dashboard-metric-value">{unavailable ? '—' : current == null ? 'Restricted' : count ? formatBDQty(current) : formatBDT(current)}</strong>
      <div className="dashboard-metric-bottom"><small><span className={difference && ((difference > 0) !== inverse) ? 'dashboard-positive' : difference ? 'dashboard-negative' : ''}><TrendIcon size={14} />{unavailable || current == null ? '—' : change}</span> vs. yesterday</small>
        {!unavailable && current != null && <svg className="dashboard-sparkline" viewBox="0 0 80 40" role="img" aria-label={`Last seven days: ${values.map(value => count ? value : formatBDT(value)).join(', ')}`}><polygon points={`4,40 ${points} 76,40`} fill="currentColor" opacity=".08" /><polyline points={points} fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinejoin="round" /><circle cx="76" cy={36 - (current - min) / (max - min) * 30} r="2.3" fill="currentColor" /></svg>}
      </div></div>
  </section>;
}
function Activities({ entries, onOpen }: { entries: DashboardActivity[]; onOpen: (entry: DashboardActivity) => void }) {
  return <div className="dashboard-activities">{entries.length ? entries.map(entry => {
    const Icon = activityIcons[entry.kind];
    return <button key={entry.id} className={`dashboard-activity activity-${entry.kind}`} onClick={() => onOpen(entry)}><span className="dashboard-activity-icon"><Icon size={20} /></span><span className="dashboard-activity-copy"><strong>{entry.title}</strong><small>{entry.description}{entry.amount !== null && ` · ${formatBDT(entry.amount)}`}</small></span><time dateTime={entry.created_at} title={new Date(entry.created_at).toLocaleString('en-BD', { timeZone: 'Asia/Dhaka' })}>{formatDistanceToNow(new Date(entry.created_at), { addSuffix: true })}</time></button>;
  }) : <p className="dashboard-empty">No business activity recorded yet.</p>}</div>;
}
function ActivityHistory({ onClose, onOpen }: { onClose: () => void; onOpen: (entry: DashboardActivity) => void }) {
  const [page, setPage] = useState(0); const query = useDashboardActivity(page);
  return <PurchaseDialog title="Recent activity" onClose={onClose}><div className="modal-body">{query.isPending && <p role="status">Loading activity…</p>}{query.error && <p role="alert">Activity could not be loaded. <button className="btn btn-secondary" onClick={() => void query.refetch()}>Retry</button></p>}{query.data && <Activities entries={query.data.entries} onOpen={onOpen} />}<PageNavigation page={page} hasMore={query.data?.hasMore ?? false} onChange={setPage} busy={query.isFetching} label="activities" /></div></PurchaseDialog>;
}

export const Dashboard = () => {
  const { can, profile } = useAuth(); const query = useDashboardStats(); const stats = query.data;
  const [spendingOpen, setSpendingOpen] = useState(false); const [printerOpen, setPrinterOpen] = useState(false);
  const [saleId, setSaleId] = useState<string | null>(null); const [activity, setActivity] = useState<DashboardActivity | null>(null); const [history, setHistory] = useState(false);
  const closePrinter = useCallback(() => setPrinterOpen(false), []);
  const openActivity = (entry: DashboardActivity) => { setHistory(false); if (entry.record_kind === 'sale') { if (can('sales:view') || can('receipts:print')) setSaleId(entry.record_id); } else setActivity(entry); };
  const unavailable = query.isPending || (query.isError && !stats); const attention = stats?.attention;
  return <div className="page-container dashboard-page" aria-busy={query.isPending}>
    <div className="dashboard-header"><p className="page-subtitle">Today's operations, sales, and key activities at a glance.</p><div className="dashboard-actions">
      {can('finance:entries') && <button className="btn btn-secondary" onClick={() => setSpendingOpen(true)}><ClipboardList size={16} />Financial Entry</button>}
      {can('printers:manage') && <button className="btn btn-secondary" onClick={() => setPrinterOpen(true)}><Printer size={16} />POS Printer</button>}
      {can('pos:sell') && <Link to="/pos" className="btn btn-primary"><ShoppingBag size={16} />Open POS</Link>}
    </div></div>
    {query.isPending && <p className="dashboard-load" role="status">Loading today's business snapshot…</p>}
    {query.error && <p className="payment-error" role="alert">{stats ? 'The snapshot could not be refreshed; the last loaded values are shown.' : 'Dashboard data could not be loaded.'} <button className="btn btn-secondary" onClick={() => void query.refetch()}>Retry</button></p>}
    <div className="dashboard-metrics">
      <Metric title="Today's Revenue" field="revenue" days={stats?.days ?? []} icon={<Banknote size={25} />} tone="green" unavailable={unavailable} description={stats?.finance_visible ? 'Recognized consolidated revenue, including sales and other earned income. Collections are separate.' : 'Recognized product sales revenue. Finance totals require Finance access.'} />
      <Metric title="Today's Expense" field="expense" days={stats?.days ?? []} icon={<Wallet size={25} />} tone="blue" inverse unavailable={unavailable} description="Recognized expenses, including FIFO cost of goods sold and accrued costs. Paying an existing obligation does not count again." />
      <Metric title="Collected Amount" field="collected" days={stats?.days ?? []} icon={<Coins size={25} />} tone="orange" unavailable={unavailable} description="Actual customer payments received today, including checkout and later collections. Refunds remain separate recorded outflows." />
      <Metric title="Total Sales" field="sales" days={stats?.days ?? []} icon={<ShoppingCart size={25} />} tone="purple" count unavailable={unavailable} description="Number of completed sales created today, excluding cancelled sales." />
    </div>
    <div className="dashboard-columns"><div className="dashboard-primary">
      <Panel title="Today's Sales" icon={<ShoppingCart size={21} />} action={can('sales:view') && <Link className="btn btn-secondary" to={`/sales?from=${stats?.date ?? ''}&to=${stats?.date ?? ''}`}>View All Sales<ArrowRight size={15} /></Link>}>
        {!unavailable ? <SalesFeed sales={stats?.sales ?? []} onOpen={setSaleId} /> : <p className="dashboard-empty">{query.isPending ? 'Loading sales…' : 'Sales unavailable.'}</p>}
      </Panel>
      <Panel title="LPG Bottles Sold Today" icon={<Cylinder size={21} />} action={<small className="dashboard-section-note">Retail + Package Sales</small>}>
        <div className="dashboard-bottles">{stats?.bottles.map((bottle, i) => <div className={`dashboard-bottle tone-${['blue', 'green', 'orange', 'purple', 'red'][i % 5]}`} key={bottle.size_kg}><span className="dashboard-bottle-icon"><Cylinder size={29} strokeWidth={1.7} /></span><div><strong>{bottle.size_kg} kg</strong><span>{formatBDQty(bottle.quantity)} bottles</span></div></div>)}{!stats?.bottles.length && <p className="dashboard-empty">{unavailable ? 'Bottle quantities unavailable.' : 'No configured weights or LPG sales today.'}</p>}</div>
      </Panel>
      <Panel title="Stove-Business Products Sold Today" icon={<ReceiptText size={21} />}>
        <StoveTypeSummary types={stats?.stove_types ?? []} unavailable={unavailable} />
      </Panel>
    </div><aside className="dashboard-secondary">
      <Panel title="Needs Attention" icon={<CircleAlert size={22} />} className="dashboard-attention-panel">
        <div className="dashboard-attention">{[
          { title: 'Customer Dues', icon: <Wallet size={25} />, value: unavailable ? '—' : attention?.customer_due == null ? 'Restricted' : formatBDT(attention.customer_due), detail: `${attention?.customers ?? 0} customers`, url: '/customers?dues=payment', allowed: can('customers:view') || can('customers:manage'), tone: 'red' },
          { title: 'Low Stock', icon: <Package size={26} />, value: unavailable ? '—' : attention?.low_stock == null ? 'Restricted' : `${attention.low_stock} products`, detail: 'Below configured thresholds', url: '/inventory?stock=low', allowed: can('inventory:view') || can('inventory:manage'), tone: 'blue' },
          { title: 'Bottle Dues', icon: <Cylinder size={26} />, value: unavailable ? '—' : attention?.bottles == null ? 'Restricted' : `${formatBDQty(attention.bottles)} bottles`, detail: `${attention?.bottle_customers ?? 0} customers`, url: '/customers?dues=bottle', allowed: can('customers:view') || can('customers:manage'), tone: 'orange' },
        ].map(entry => { const content = <><span className={`dashboard-attention-icon tone-${entry.tone}`}>{entry.icon}</span><span><strong>{entry.title}</strong><b>{entry.value}</b><small>{entry.allowed && !unavailable ? entry.detail : 'Access required'}</small></span>{entry.allowed && <ArrowRight size={17} />}</>; return entry.allowed ? <Link to={entry.url} className="dashboard-attention-entry" key={entry.title}>{content}</Link> : <div className="dashboard-attention-entry" key={entry.title}>{content}</div>; })}</div>
      </Panel>
      <Panel title="Recent Activity" icon={<Clock3 size={22} />} className="dashboard-activity-panel" action={<button className="btn btn-ghost" onClick={() => setHistory(true)}>View All<ArrowRight size={14} /></button>}>
        {unavailable ? <p className="dashboard-empty">Activity unavailable.</p> : <Activities entries={stats?.activity.entries ?? []} onOpen={openActivity} />}
      </Panel>
    </aside></div>
    {spendingOpen && <FinancialEntryDialog onClose={() => setSpendingOpen(false)} />}{printerOpen && <PrinterConfigModal onClose={closePrinter} />}
    {saleId && <TransactionDetailsModal saleId={saleId} onClose={() => setSaleId(null)} returnLabel="Close" />}
    {history && <ActivityHistory onClose={() => setHistory(false)} onOpen={openActivity} />}
    {activity && <Suspense fallback={<p role="status">Loading source record…</p>}><RelatedRecord record={{ tenant_id: profile?.tenant_id ?? '', type_id: '', type_name: '', business_category: '', account: '', name: activity.title, entity_id: null, entity_name: activity.description, amount: activity.amount ?? 0, record_kind: activity.record_kind, record_id: activity.record_id }} onClose={() => setActivity(null)} /></Suspense>}
  </div>;
};
