import { useState, type KeyboardEvent } from 'react';
import { formatBDT } from '../../lib/formatBDT';
import type { JournalReport } from '../../types/accounting';
import { Pagination } from '../ui/Pagination';

type TrendPoint = JournalReport['trend'][number];
type TrendValue = 'revenue' | 'expenses' | 'profit' | 'cash_in' | 'cash_out' | 'net_worth';
interface Series { key: TrendValue; label: string; color: string; dash?: string }
const compact = (value: number) => new Intl.NumberFormat('en', { notation: 'compact', maximumFractionDigits: 1 }).format(value);
const day = (value: string) => new Date(`${value}T12:00:00`).toLocaleDateString('en-BD', { day: 'numeric', month: 'short', year: '2-digit' });
const performance: Series[] = [{ key: 'revenue', label: 'Revenue', color: 'var(--primary)' }, { key: 'expenses', label: 'Expenses', color: 'var(--warning)', dash: '7 4' }, { key: 'profit', label: 'Profit', color: 'var(--accent)', dash: '2 3' }];
const cash: Series[] = [{ key: 'cash_in', label: 'Cash in', color: 'var(--primary)' }, { key: 'cash_out', label: 'Cash out', color: 'var(--warning)', dash: '7 4' }];
const worth: Series[] = [{ key: 'net_worth', label: 'Business net worth', color: 'var(--primary)' }];

export function FinanceCharts({ report }: { report: JournalReport }) {
  return <div className="finance-chart-grid">
    <PositionComparison report={report} />
    <TrendChart title="Revenue, expenses & profit" points={report.trend} series={performance} />
    <TrendChart title="Cash inflow & outflow" points={report.trend} series={cash} />
    <TrendChart title="Business net worth" points={report.trend} series={worth} description="Combined assets less liabilities at each interval end, including capital movements." />
    <Distribution title="Expense distribution" rows={report.categories.filter(c => c.kind === 'expense' && c.amount !== 0).map(c => ({ name: c.name, value: c.amount }))} />
  </div>;
}

function TrendChart({ title, points, series, description }: { title: string; points: TrendPoint[]; series: Series[]; description?: string }) {
  const [selected, setSelected] = useState<number | null>(null); const [hidden, setHidden] = useState<TrendValue[]>([]); const [page, setPage] = useState(0);
  const visible = series.filter(s => !hidden.includes(s.key));
  const values = points.flatMap(p => visible.map(s => p[s.key])); const low = Math.min(0, ...values); const high = Math.max(0, ...values);
  const padding = Math.max(1, high - low) * .08; const min = low < 0 ? low - padding : 0; const max = high + padding;
  const y = (value: number) => 196 - (value - min) / (max - min) * 192;
  const x = (index: number) => points.length < 2 ? 300 : 4 + index / (points.length - 1) * 592;
  const active = Math.min(points.length - 1, selected ?? points.length - 1); const current = points[active];
  function keyboard(e: KeyboardEvent<SVGSVGElement>) {
    if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(e.key)) return;
    e.preventDefault(); setSelected(e.key === 'Home' ? 0 : e.key === 'End' ? points.length - 1 : Math.max(0, Math.min(points.length - 1, active + (e.key === 'ArrowLeft' ? -1 : 1))));
  }
  const ticks = [...new Set([0, Math.round((points.length - 1) / 2), points.length - 1])].filter(i => i >= 0);
  return <section className="accounting-card finance-chart"><header><h3>{title}</h3><div className="chart-legend">{series.map(s => <button type="button" key={s.key} aria-pressed={!hidden.includes(s.key)} onClick={() => setHidden(p => p.includes(s.key) ? p.filter(k => k !== s.key) : p.length < series.length - 1 ? [...p, s.key] : p)}><i style={{ background: s.color, opacity: hidden.includes(s.key) ? .3 : 1 }} />{s.label}</button>)}</div></header>
    {points.length ? <><div className="trend-plot"><div className="trend-y-axis" aria-hidden="true">{[max, min + (max - min) * .75, min + (max - min) * .5, min + (max - min) * .25, min].map((v, i) => <span key={i}>{compact(v)}</span>)}</div>
      <svg viewBox="0 0 600 200" preserveAspectRatio="none" tabIndex={0} role="img" aria-label={`${title}. Use left and right arrow keys to inspect each interval. ${current ? `${day(current.period)}: ${visible.map(s => `${s.label} ${formatBDT(current[s.key])}`).join(', ')}` : ''}`} onKeyDown={keyboard} onPointerMove={e => { const bounds = e.currentTarget.getBoundingClientRect(); setSelected(Math.round(Math.max(0, Math.min(1, (e.clientX - bounds.left) / bounds.width)) * (points.length - 1))); }}>
        {[4, 52, 100, 148, 196].map(n => <line key={n} x1="0" x2="600" y1={n} y2={n} className="chart-grid-line" />)}
        {low < 0 && <line x1="0" x2="600" y1={y(0)} y2={y(0)} className="chart-zero-line" />}
        {visible.map(s => <polyline key={s.key} points={points.map((p, i) => `${x(i)},${y(p[s.key])}`).join(' ')} fill="none" stroke={s.color} strokeWidth="2.5" strokeDasharray={s.dash} vectorEffect="non-scaling-stroke" />)}
        {current && <><line x1={x(active)} x2={x(active)} y1="0" y2="200" className="chart-cursor-line" />{visible.map(s => <circle key={s.key} cx={x(active)} cy={y(current[s.key])} r="4" fill={s.color} vectorEffect="non-scaling-stroke" />)}</>}
      </svg></div><div className="trend-x-axis" aria-hidden="true">{ticks.map(i => <span key={i}>{day(points[i].period)}</span>)}</div>
      <div className="chart-values" aria-live="off">{current && <><strong>{day(current.period)}</strong>{visible.map(s => <span key={s.key}>{s.label} <b>{formatBDT(current[s.key])}</b></span>)}</>}</div>
      {description && <p className="finance-note">{description}</p>}
      <details className="chart-data"><summary>View chart values</summary><div className="accounting-table-wrap"><table><thead><tr><th>Interval starts</th>{series.map(s => <th key={s.key}>{s.label}</th>)}</tr></thead><tbody>{points.slice(page * 12, page * 12 + 12).map(p => <tr key={p.period}><td>{p.period}</td>{series.map(s => <td key={s.key}>{formatBDT(p[s.key])}</td>)}</tr>)}</tbody></table></div><Pagination page={page} pageSize={12} total={points.length} onChange={setPage} label="trend intervals" /></details>
    </> : <p className="finance-empty">No recorded activity in this period.</p>}
  </section>;
}

export function Distribution({ title, rows }: { title: string; rows: { name: string; value: number }[] }) {
  const total = rows.reduce((sum, row) => sum + Math.abs(row.value), 0);
  return <section className="accounting-card finance-distribution"><h3>{title}</h3>{rows.map(row => <div className="distribution-row" key={row.name}><div><span>{row.name}</span><strong>{formatBDT(row.value)}</strong></div><span className="distribution-track" aria-hidden="true"><i style={{ width: `${total ? Math.abs(row.value) / total * 100 : 0}%` }} /></span></div>)}{!rows.length && <p className="finance-note">No recorded amounts in this period.</p>}</section>;
}

function PositionComparison({ report }: { report: JournalReport }) {
  const ceiling = Math.max(1, report.opening.assets, report.opening.liabilities, report.closing.assets, report.closing.liabilities);
  return <section className="accounting-card finance-position-chart"><h3>Assets versus liabilities</h3><div className="position-comparison">{([['Opening position', report.opening], ['Closing position', report.closing]] as const).map(([label, position]) => <div key={label}><h4>{label}</h4>{([['Assets', position.assets], ['Liabilities', position.liabilities]] as const).map(([name, value]) => <div className="position-bar" key={name}><div><span>{name}</span><strong>{formatBDT(value)}</strong></div><span className="distribution-track" aria-hidden="true"><i className={name === 'Liabilities' ? 'position-liability' : ''} style={{ width: `${Math.max(0, value) / ceiling * 100}%` }} /></span></div>)}</div>)}</div><p className="finance-note">Combined business positions at the selected period boundaries, on the same scale.</p></section>;
}
