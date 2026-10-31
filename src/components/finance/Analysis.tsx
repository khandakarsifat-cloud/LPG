import { useState } from 'react';
import { Download, SlidersHorizontal } from 'lucide-react';
import { dhakaToday } from '../../lib/businessDate';
import { useJournalReport } from '../../hooks/useAccounting';
import { useAnalysisBusinesses } from '../../hooks/useAnalysis';
import { formatBDT } from '../../lib/formatBDT';
import type { FinancialPosition, JournalFilters, JournalReport } from '../../types/accounting';
import { DatePicker } from '../ui/DatePicker';
import { FinanceCharts, Distribution } from './FinanceCharts';
import { JournalAudit } from './JournalAudit';
import './accounting.css';

const money = (value: number | null) => value === null ? 'Unavailable' : formatBDT(value);
const activityNames: Record<string, string> = { all: 'Combined business', lpg: 'LPG', stove: 'Stove', logistics: 'Logistics', shared: 'Shared / unallocated' };
const sections = [['overview', 'Overview'], ['profit', 'Profit & loss'], ['position', 'Assets & liabilities'], ['cash', 'Cash flow'], ['capital', 'Capital & withdrawals']] as const;

export function FinanceAnalysis() {
  const [filters, setFilters] = useState<JournalFilters>(() => ({ from: `${dhakaToday().slice(0, 7)}-01`, to: dhakaToday(), grain: 'day', category: 'all', business_id: '' }));
  const [tab, setTab] = useState('overview'); const [audit, setAudit] = useState(false); const [scopeFilters, setScopeFilters] = useState(false);
  const businesses = useAnalysisBusinesses(); const q = useJournalReport(filters); const r = q.data;
  const set = <K extends keyof JournalFilters>(key: K, value: JournalFilters[K]) => setFilters(previous => {
    const next = { ...previous, [key]: value };
    if (next.grain === 'day' && Date.parse(next.to) - Date.parse(next.from) > 730 * 86400000) next.grain = 'month';
    return next;
  });
  function range(kind: 'today' | 'month' | 'year' | 'history') {
    const today = dhakaToday(); let from = today;
    if (kind === 'month') from = `${today.slice(0, 7)}-01`;
    if (kind === 'year') from = `${today.slice(0, 4)}-01-01`;
    if (kind === 'history') from = r?.coverage.map(c => new Intl.DateTimeFormat('sv-SE', { timeZone: 'Asia/Dhaka' }).format(new Date(c.started_at))).sort()[0] ?? today;
    setFilters(p => ({ ...p, from, to: today, grain: kind === 'year' || kind === 'history' && Date.parse(today) - Date.parse(from) > 90 * 86400000 ? 'month' : 'day' }));
  }
  const metrics = r ? [['Net profit', r.totals.profit], ['Available cash', r.closing.cash], ['Total assets', r.closing.assets], ['Total liabilities', r.closing.liabilities], ["Owner’s equity", r.closing.equity], ['Invested capital', r.invested_capital], ['Owner withdrawals', r.totals.withdrawals], ['Net cash flow', r.totals.cash_flow]] as const : [];
  const accounts = r ? [...new Map([...r.opening.accounts, ...r.closing.accounts].map(a => [a.account, { account: a.account, name: a.name }])).values()].sort((a, b) => a.name.localeCompare(b.name)) : [];
  return <section className="accounting-analysis" aria-busy={q.isFetching}>
    <div className="analysis-toolbar"><div className="analysis-quick-ranges" aria-label="Report date ranges">{(['today', 'month', 'year', 'history'] as const).map(key => <button type="button" className="btn btn-secondary" key={key} onClick={() => range(key)}>{({ today: 'Today', month: 'This month', year: 'This year', history: 'All history' })[key]}</button>)}</div>
      <button type="button" className="btn btn-secondary" disabled={!r || q.isFetching || q.isPlaceholderData} onClick={() => { if (r) void import('../../lib/analysisPdf').then(m => m.exportAnalysisPdf(r)); }}><Download size={15} />Export report PDF</button>
    </div>
    <button type="button" className="btn btn-secondary analysis-scope-toggle" aria-expanded={scopeFilters} aria-controls="analysis-filter-fields" onClick={() => setScopeFilters(p => !p)}><SlidersHorizontal size={14} />Business & trend filters</button>
    <div id="analysis-filter-fields" className={`accounting-filters ${scopeFilters ? 'filters-expanded' : ''}`}><div className="input-group"><span className="input-label">From</span><DatePicker label="From" value={filters.from} max={filters.to} onChange={v => set('from', v)} /></div><div className="input-group"><span className="input-label">To</span><DatePicker label="To" value={filters.to} min={filters.from} max={dhakaToday()} onChange={v => set('to', v)} /></div>
      <label className="input-group"><span className="input-label">Business</span><select className="input-field" value={filters.business_id} onChange={e => set('business_id', e.target.value)}><option value="">All authorized businesses</option>{businesses.data?.map(b => <option value={b.tenant_id} key={b.tenant_id}>{b.business_name}</option>)}</select></label>
      <label className="input-group"><span className="input-label">Business activity</span><select className="input-field" value={filters.category} onChange={e => set('category', e.target.value as JournalFilters['category'])}>{Object.entries(activityNames).map(([key, label]) => <option key={key} value={key}>{label}</option>)}</select></label>
      <label className="input-group"><span className="input-label">Trend interval</span><select className="input-field" value={filters.grain} onChange={e => set('grain', e.target.value as JournalFilters['grain'])}><option value="day">Daily</option><option value="month">Monthly</option><option value="year">Yearly</option></select></label>
    </div>
    {q.isPending && <div className="analysis-loading" role="status">Loading financial analysis…</div>}{q.error && <p className="payment-error" role="alert">{q.error.message}<button className="btn btn-secondary" onClick={() => void q.refetch()}>Retry</button></p>}
    {r && <><div className="analysis-period"><div><strong>{r.from} — {r.to}</strong><span>{activityNames[r.category]}{q.isFetching ? ' · Updating…' : ''}</span></div><span className={`analysis-evidence ${!r.complete ? 'analysis-evidence-incomplete' : ''}`}>{!r.complete ? 'Essential asset values missing' : r.estimated ? 'Development estimates included' : 'Recorded accounting values'}</span></div>
      {r.category !== 'all' && <p className="finance-note">Revenue, expenses and cash show this activity. Assets, liabilities and net worth show the combined business; shared costs remain separate.</p>}
      <nav className="accounting-tabs" aria-label="Financial analysis sections">{sections.map(([key, label]) => <button type="button" key={key} aria-current={tab === key ? 'page' : undefined} onClick={() => setTab(key)}>{label}</button>)}</nav>
      {tab === 'overview' && <><div className="accounting-metrics">{metrics.map(([label, value], index) => <article className={`accounting-card accounting-metric ${index === 0 ? 'accounting-metric-primary' : ''}`} data-negative={value !== null && value < 0} key={label}><span>{label}</span><strong>{money(value)}</strong><small>{index === 1 || index === 2 || index === 3 || index === 4 || index === 5 ? 'At period end' : 'Selected period'}</small></article>)}</div>
        <div className="analysis-wallets" aria-label="Wallet balances at period end">{r.closing.accounts.filter(a => a.account === 'cash').map(a => <div key={`${a.tenant_id}:${a.entity_id}`}><span>{a.entity_name ?? 'Wallet'}</span><strong>{formatBDT(a.kind === 'liability' ? -a.amount : a.amount)}</strong></div>)}</div>
        <FinanceCharts key={`${r.from}:${r.to}:${r.category}:${filters.business_id}:${filters.grain}`} report={r} />
        <ActivityComparison report={r} businesses={businesses.data ?? []} />
      </>}
      {tab === 'profit' && <div className="accounting-position-grid"><Breakdown title="Revenue" rows={r.categories.filter(c => c.kind === 'income')} total={r.totals.revenue} /><Breakdown title="Expenses" rows={r.categories.filter(c => c.kind === 'expense')} total={r.totals.expenses} /><section className="accounting-card analysis-profit"><h3>Net profit</h3><strong>{money(r.totals.profit)}</strong><p className="finance-note">Revenue less cost of goods sold and incurred business expenses. Payments settle balances; purchasing stock creates an asset until it is sold or lost.</p></section><Distribution title="Expense distribution" rows={r.categories.filter(c => c.kind === 'expense').map(c => ({ name: c.name, value: c.amount }))} /></div>}
      {tab === 'position' && <><div className="accounting-position-grid"><Position title="Opening position" data={r.opening} /><Position title="Closing position" data={r.closing} /></div><Distribution title="Assets versus liabilities at period end" rows={[{ name: 'Assets', value: r.closing.assets }, { name: 'Liabilities', value: r.closing.liabilities }, { name: "Owner’s equity", value: r.closing.equity }]} /></>}
      {tab === 'cash' && <><div className="accounting-metrics">{[['Cash received', r.totals.cash_in], ['Cash paid out', r.totals.cash_out], ['Net cash flow', r.totals.cash_flow]].map(([label, value]) => <article className="accounting-card accounting-metric" key={label}><span>{label}</span><strong>{formatBDT(Number(value))}</strong></article>)}</div><div className="cash-flow-categories">{r.cash_categories.map(c => <article className="accounting-card" key={c.category}><h3>{c.category === 'unclassified' ? 'Opening balance settlements' : `${c.category[0].toUpperCase()}${c.category.slice(1)}`}</h3><dl className="accounting-breakdown"><div><dt>Received</dt><dd>{formatBDT(c.received)}</dd></div><div><dt>Paid out</dt><dd>{formatBDT(c.spent)}</dd></div><div><dt>Net movement</dt><dd>{formatBDT(c.net)}</dd></div></dl></article>)}</div><p className="finance-note">Internal wallet transfers {formatBDT(r.totals.transfers)} have no net cash flow. Loan principal, capital and withdrawals are financing movements. Interest is an expense when manually recorded.</p></>}
      {tab === 'capital' && <section className="accounting-card"><h3>Capital & withdrawals</h3><dl className="accounting-breakdown">{[['Invested capital at period end', r.invested_capital], ['Period owner contributions', r.totals.contributions], ['Period owner withdrawals', r.totals.withdrawals], ['Withdrawals to date', r.withdrawals_to_date], ['Retained earnings at period end', r.retained_earnings], ['Other period equity movements', r.totals.equity_adjustments], ["Owner’s equity at period end", r.closing.equity]].map(([label, value]) => <div key={label}><dt>{label}</dt><dd>{money(value as number | null)}</dd></div>)}</dl><p className="finance-note">Opening net assets are opening capital. Reconstructed development history assumes zero retained earnings before the first supported records; later retained earnings come from recorded revenue and expenses.</p></section>}
      <details className="analysis-advanced"><summary><SlidersHorizontal size={15} />Financial reconciliation & valuation basis</summary><section className="accounting-card"><h3>Financial reconciliation</h3><p>Assets {formatBDT(r.closing.assets)} = Liabilities {formatBDT(r.closing.liabilities)} + Owner’s equity {formatBDT(r.closing.equity)}</p><p>Profit from revenue and expenses: <strong>{money(r.totals.profit)}</strong> · Profit from changes in net assets: <strong>{money(r.totals.position_profit)}</strong></p><p className="finance-note">Changes in net assets exclude contributions, withdrawals and other equity adjustments. Approximate buying prices and commission estimates never determine these values.</p>{r.coverage.map(c => <p className="finance-note" key={c.tenant_id}>{c.note}</p>)}</section></details>
      <details className="analysis-advanced" onToggle={e => setAudit(e.currentTarget.open)}><summary>Advanced journal audit</summary>{audit && <JournalAudit key={JSON.stringify(filters)} filters={filters} accounts={accounts} />}</details>
    </>}
  </section>;
}

function Breakdown({ title, rows, total }: { title: string; rows: { account: string; name: string; amount: number }[]; total: number }) {
  return <section className="accounting-card"><h3>{title}</h3><dl className="accounting-breakdown">{rows.map(row => <div key={row.account}><dt>{row.name}</dt><dd>{formatBDT(row.amount)}</dd></div>)}<div className="breakdown-total"><dt>Total {title.toLowerCase()}</dt><dd>{formatBDT(total)}</dd></div></dl></section>;
}
function Position({ title, data }: { title: string; data: FinancialPosition }) {
  return <section className="accounting-card"><h3>{title}</h3>{(['asset', 'liability', 'equity'] as const).map(kind => <div key={kind}><h4>{kind === 'asset' ? 'Assets' : kind === 'liability' ? 'Liabilities' : 'Capital & other equity'}</h4><dl className="accounting-breakdown">{data.accounts.filter(a => a.kind === kind).map(a => <div key={`${a.tenant_id}:${a.account}:${a.entity_id}`}><dt>{a.account === 'cash' ? a.entity_name ?? a.name : a.name}</dt><dd>{formatBDT(a.amount)}</dd></div>)}</dl></div>)}<dl className="accounting-breakdown"><div><dt>Accumulated profit</dt><dd>{formatBDT(data.accounts.filter(a => a.kind === 'income' || a.kind === 'expense').reduce((sum, a) => sum + (a.kind === 'income' ? a.amount : -a.amount), 0))}</dd></div><div className="breakdown-total"><dt>Assets</dt><dd>{formatBDT(data.assets)}</dd></div><div><dt>Liabilities</dt><dd>{formatBDT(data.liabilities)}</dd></div><div><dt>Owner’s equity</dt><dd>{formatBDT(data.equity)}</dd></div></dl></section>;
}
function ActivityComparison({ report, businesses }: { report: JournalReport; businesses: { tenant_id: string; business_name: string }[] }) {
  return <section className="accounting-card"><h3>Business activity comparison</h3><div className="analysis-activities">{report.businesses.map(b => <article key={`${b.tenant_id}:${b.business_category}`}><h4>{activityNames[b.business_category]}</h4>{businesses.length > 1 && <small>{businesses.find(x => x.tenant_id === b.tenant_id)?.business_name ?? 'Business'}</small>}<dl className="accounting-breakdown"><div><dt>Revenue</dt><dd>{formatBDT(b.revenue)}</dd></div><div><dt>Expenses</dt><dd>{formatBDT(b.expenses)}</dd></div><div className="breakdown-total"><dt>Profit / loss</dt><dd>{formatBDT(b.revenue - b.expenses)}</dd></div></dl></article>)}</div>{!report.businesses.length && <p className="finance-note">No revenue or expenses recorded in this period.</p>}</section>;
}
