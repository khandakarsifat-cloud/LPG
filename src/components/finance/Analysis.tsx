import { useState } from 'react';
import { ChevronRight, Download, SlidersHorizontal } from 'lucide-react';
import { dhakaToday } from '../../lib/businessDate';
import { useJournalReport } from '../../hooks/useAccounting';
import { positionGroupValue as groupValue } from '../../lib/accountingPosition';
import { formatBDT } from '../../lib/formatBDT';
import type { AnalysisGroup, AnalysisSide, FinancialPosition, JournalFilters } from '../../types/accounting';
import { DatePicker } from '../ui/DatePicker';
import { FinanceCharts } from './FinanceCharts';
import { JournalAudit } from './JournalAudit';
import { AccountingBreakdownModal, AccountingHealth } from './AccountingBreakdown';
import './accounting.css';

const groupNames: Record<AnalysisGroup, string> = { assets: 'Total assets', liabilities: 'Total liabilities', equity: "Total owner’s equity", cash: 'Cash & wallets', receivables: 'Accounts receivable', inventory: 'Supplies & inventory', fixed_assets: 'Equipment, vehicles & fixed assets', other_assets: 'Other assets & advances', dues: 'Loans / outstanding dues', employees: 'Unpaid employee obligations', other_liabilities: 'Other obligations & overdrafts', capital: 'Capital', revenue: 'Cumulative revenue', expenses: 'Cumulative expenses', withdrawals: 'Cumulative owner withdrawals', other_equity: 'Other recorded equity movements', accumulated_income: 'Accumulated income' };
const assets: AnalysisGroup[] = ['cash', 'receivables', 'inventory', 'fixed_assets', 'other_assets'];
const liabilities: AnalysisGroup[] = ['dues', 'employees', 'other_liabilities'];
const equity: AnalysisGroup[] = ['capital', 'revenue', 'expenses', 'withdrawals', 'other_equity'];

export function FinanceAnalysis() {
 const [mobilePosition, setMobilePosition] = useState<'opening' | 'closing'>('closing');
 const [filters, setFilters] = useState<JournalFilters>(() => ({ from: `${dhakaToday().slice(0, 7)}-01`, to: dhakaToday(), grain: 'day', category: 'all', business_id: '' }));
 const [audit, setAudit] = useState(false); const [health, setHealth] = useState(false); const [expanded, setExpanded] = useState(false);
 const [detail, setDetail] = useState<{ group: AnalysisGroup; side: AnalysisSide; value: number } | null>(null);
 const query = useJournalReport(filters); const r = query.data;
 const set = <K extends keyof JournalFilters>(key: K, value: JournalFilters[K]) => setFilters(p => {
  const next = { ...p, [key]: value, all_time: key === 'from' ? false : p.all_time };
  if (next.grain === 'day' && Date.parse(next.to) - Date.parse(next.from) > 730 * 86400000) next.grain = 'month';
  return next;
 });
 function range(kind: 'month' | 'year' | 'history') {
  const today = dhakaToday(); const from = kind === 'month' ? `${today.slice(0, 7)}-01` : kind === 'year' ? `${today.slice(0, 4)}-01-01` : r?.coverage.map(c => new Intl.DateTimeFormat('sv-SE', { timeZone: 'Asia/Dhaka' }).format(new Date(c.started_at))).sort()[0] ?? today;
  setFilters(p => ({ ...p, from, to: today, all_time: kind === 'history', grain: kind === 'month' ? 'day' : 'month' }));
 }
 const open = (group: AnalysisGroup, side: AnalysisSide, value: number) => setDetail({ group, side, value });
 const reportFilters = r ? { ...filters, from: r.from, to: r.to, all_time: r.all_time } : filters;
 const accounts = r ? [...new Map([...r.opening.accounts, ...r.closing.accounts].map(a => [a.account, { account: a.account, name: a.name }])).values()] : [];
 return <section className="accounting-analysis" aria-busy={query.isFetching}>
  <div className="analysis-toolbar"><div className="analysis-quick-ranges" aria-label="Report date ranges">{(['month', 'year', 'history'] as const).map(key => <button type="button" className="btn btn-secondary" key={key} onClick={() => range(key)}>{({ month: 'This month', year: 'This year', history: 'All time' })[key]}</button>)}</div><button type="button" className="btn btn-secondary" aria-label="Export PDF" disabled={!r || query.isFetching || query.isPlaceholderData} onClick={() => { if (r) void import('../../lib/analysisPdf').then(m => m.exportAnalysisPdf(r)); }}><Download size={15} /><span className="analysis-export-prefix">Export </span>PDF</button></div>
  <button className="btn btn-secondary analysis-scope-toggle" aria-expanded={expanded} aria-controls="analysis-filter-fields" onClick={() => setExpanded(p => !p)}><SlidersHorizontal size={14} />Business & trend filters</button>
  <div id="analysis-filter-fields" className={`accounting-filters ${expanded ? 'filters-expanded' : ''}`}><div className="input-group"><span className="input-label">From</span><DatePicker label="From" value={r?.all_time ? r.from : filters.from} max={filters.to} onChange={v => set('from', v)} /></div><div className="input-group"><span className="input-label">To</span><DatePicker label="To" value={filters.to} min={filters.from} max={dhakaToday()} onChange={v => set('to', v)} /></div>
   <label className="input-group"><span className="input-label">Trend interval</span><select className="input-field" aria-label="Trend interval" value={filters.grain} onChange={e => set('grain', e.target.value as JournalFilters['grain'])}><option value="day">Daily</option><option value="month">Monthly</option><option value="year">Yearly</option></select></label>
   <label className="input-group"><span className="input-label">Business line</span><select className="input-field" aria-label="Business line" value={filters.category} onChange={e => { const v = e.target.value; if (v === 'all' || v === 'lpg' || v === 'stove' || v === 'logistics') set('category', v); }}><option value="all">Consolidated organization</option><option value="lpg">LPG</option><option value="stove">Stove</option><option value="logistics">Logistics</option></select></label>
  </div>
  {query.isPending && <p className="analysis-loading" role="status">Loading financial Overview…</p>}{query.error && <p className="payment-error" role="alert">{query.error.message}<button className="btn btn-secondary" onClick={() => void query.refetch()}>Retry</button></p>}
  {r && <div className="overview-content" inert={query.isPlaceholderData}><header className="analysis-period"><div><h2>Financial Overview</h2><span>{r.from} — {r.to} · Asia/Dhaka{query.isFetching ? ' · Updating…' : ''}</span></div>{(!r.complete || r.estimated) && <span className={`analysis-evidence ${!r.complete ? 'analysis-evidence-incomplete' : ''}`}>{!r.complete ? 'Essential asset values missing' : r.estimated ? 'Development estimates included' : 'Recorded accounting values'}</span>}</header>
   <section className="overview-income"><header><h3>Income comparison</h3><p className="finance-note">Accumulated income = cumulative revenue − cumulative expenses.</p></header><div className="overview-income-cards">
    <SummaryCard label="Opening accumulated income" value={r.opening.accumulated_income} onClick={() => open('accumulated_income', 'opening', r.opening.accumulated_income)} />
    <SummaryCard label="Closing accumulated income" value={r.closing.accumulated_income} onClick={() => open('accumulated_income', 'closing', r.closing.accumulated_income)} />
    <SummaryCard label="Period income / profit or loss" value={r.period_income} primary onClick={() => open('accumulated_income', 'period', r.period_income)} />
   </div><p className="finance-note">Period income is closing accumulated income less opening accumulated income. Net cash flow: {formatBDT(r.totals.cash_flow)}. Change in net assets: {formatBDT(r.closing.equity - r.opening.equity)}. Contributions, withdrawals and other equity movements explain why these differ.</p></section>
   <section className="accounting-card"><h3>Period financial activity</h3><div className="overview-category-cards">
    <SummaryCard label="Period revenue" value={r.totals.revenue} onClick={() => open('revenue', 'period', r.totals.revenue)} />
    <SummaryCard label="Period expense" value={r.totals.expenses} onClick={() => open('expenses', 'period', r.totals.expenses)} />
    <SummaryCard label="Period withdrawals" value={r.totals.withdrawals} onClick={() => open('withdrawals', 'period', r.totals.withdrawals)} />
    <SummaryCard label="Period investments" value={r.totals.contributions} onClick={() => open('capital', 'period', r.totals.contributions)} />
    {r.period_values && ([['Stock acquisitions', r.period_values.stock_acquisitions], ['Stock change', r.period_values.stock_change], ['Equipment acquisitions', r.period_values.equipment_acquisitions], ['Receivable change', r.period_values.receivable_change], ['Payable change', r.period_values.payable_change], ['Loan movement', r.period_values.loan_movement], ['Wallet movement', r.period_values.wallet_movement]] as const).map(([name, value]) => <div className="overview-summary" key={name}><span>{name}</span><strong>{formatBDT(value)}</strong></div>)}
   </div></section>
   <p className="overview-equation">Assets = Liabilities + Capital + Revenue − Expenses − Owner withdrawals {(r.opening.other_equity !== 0 || r.closing.other_equity !== 0) && <small>Other recorded equity movements are shown separately.</small>}</p>
   <div className="overview-position-switch" role="group" aria-label="Financial position"><button className="btn btn-secondary" aria-pressed={mobilePosition==='opening'} onClick={()=>setMobilePosition('opening')}>Opening position</button><button className="btn btn-secondary" aria-pressed={mobilePosition==='closing'} onClick={()=>setMobilePosition('closing')}>Closing position</button></div>
   <div className="overview-positions" data-mobile-side={mobilePosition} aria-label="Opening and closing financial positions">
    {(['opening', 'closing'] as const).map(side => <div className={`overview-position overview-${side}`} key={side}>
     <header><h3>{side === 'opening' ? 'Opening position' : 'Closing position'}</h3><span>{side === 'opening' ? r.all_time ? 'Original business opening' : `Immediately before ${r.from}` : `At the end of ${r.to}`}</span></header>
     <PositionSection title={`${side === 'opening' ? 'Opening' : 'Closing'} Assets`} total="assets" groups={assets} position={r[side]} side={side} onOpen={open} />
     <PositionSection title={`${side === 'opening' ? 'Opening' : 'Closing'} Liabilities`} total="liabilities" groups={liabilities} position={r[side]} side={side} onOpen={open} />
     <PositionSection title={`${side === 'opening' ? 'Opening' : 'Closing'} Owner’s Equity`} total="equity" groups={equity.filter(g => g !== 'other_equity' || r.opening.other_equity !== 0 || r.closing.other_equity !== 0)} position={r[side]} side={side} onOpen={open} />
    </div>)}
   </div>
   <FinanceCharts key={`${r.from}:${r.to}:${filters.business_id}:${filters.grain}`} report={r} />
   <details className="analysis-advanced"><summary>Accounting equation & valuation basis</summary><section className="accounting-card">{(['opening', 'closing'] as const).map(side => <p key={side}><strong>{side === 'opening' ? 'Opening' : 'Closing'}:</strong> Assets {formatBDT(r[side].assets)} = Liabilities {formatBDT(r[side].liabilities)} + Owner’s equity {formatBDT(r[side].equity)}</p>)}<p>Period profit from adjusted net assets: <strong>{r.totals.position_profit === null ? 'Unavailable' : formatBDT(r.totals.position_profit)}</strong></p><p className="finance-note">Initial liabilities reduce opening capital. Retained earnings are revenue less expenses, already included in equity. Wallet transfers and loan principal do not affect profit. Inventory uses recorded FIFO costs; historical monthly LPG commissions reduce the related acquisition batches. Later deductions settle the earned supplier rebate. Approximate buying prices remain separate.</p>{r.coverage.map(c => <p className="finance-note" key={c.tenant_id}>{c.note}</p>)}</section></details>
   <details className="analysis-advanced" onToggle={e => setHealth(e.currentTarget.open)}><summary>Reconciliation & monthly savepoints</summary>{health && <AccountingHealth filters={reportFilters} />}</details>
   <details className="analysis-advanced" onToggle={e => setAudit(e.currentTarget.open)}><summary>Advanced journal audit</summary>{audit && <JournalAudit key={JSON.stringify(reportFilters)} filters={reportFilters} accounts={accounts} />}</details>
   {detail && <AccountingBreakdownModal key={`${JSON.stringify(reportFilters)}:${detail.group}:${detail.side}`} title={`${detail.side === 'period' ? 'Period' : detail.side === 'opening' ? 'Opening' : 'Closing'} ${groupNames[detail.group].replace(/^Cumulative /i, '').replace(/^owner /i, '')}`} filters={reportFilters} group={detail.group} side={detail.side} expected={detail.value} onClose={() => setDetail(null)} />}
  </div>}
 </section>;
}

function PositionSection({ title, total, groups, position, side, onOpen }: { title: string; total: AnalysisGroup; groups: AnalysisGroup[]; position: FinancialPosition; side: AnalysisSide; onOpen: (group: AnalysisGroup, side: AnalysisSide, amount: number) => void }) {
 return <section className="overview-section"><header><h4>{title}</h4><button className="overview-total" onClick={() => onOpen(total, side, groupValue(position, total))}>{formatBDT(groupValue(position, total))}<ChevronRight size={14} /></button></header><div className="overview-category-cards">{groups.map(group => <SummaryCard key={group} label={groupNames[group]} value={groupValue(position, group)} subtract={group === 'expenses' || group === 'withdrawals'} onClick={() => onOpen(group, side, groupValue(position, group))} />)}</div></section>;
}
function SummaryCard({ label, value, onClick, primary, subtract }: { label: string; value: number; onClick: () => void; primary?: boolean; subtract?: boolean }) {
 return <button type="button" className={`overview-summary ${primary ? 'overview-summary-primary' : ''}`} data-negative={value < 0} onClick={onClick}><span>{label}</span><strong>{subtract ? '− ' : ''}{formatBDT(value)}</strong><ChevronRight size={14} aria-hidden="true" /></button>;
}
