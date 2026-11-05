import { useState } from 'react';
import type { JournalReport } from '../../types/accounting';
import { formatBDT } from '../../lib/formatBDT';
import { columns, tabular, subtract } from '../../lib/businessTabular';
const names = { lpg: 'LPG', stove: 'Stove', logistics: 'Logistics', all: 'Combined' };

export function BusinessTabularAnalysis({ report }: { report: JournalReport }) {
  const [side, setSide] = useState<'opening' | 'movement' | 'closing'>('closing');
  const rows = report.business_positions.map(p => ({ name: names[p.category], category: p.category, values: side === 'movement' ? subtract(tabular(p.closing), tabular(p.opening)) : tabular(p[side]) }));
  return <section className="accounting-card business-tabular"><h3>Business tabular analysis</h3>
    <p>Cash + Accounts Receivable + Supplies + Equipment = Loan + Accounts Payable + Capital + Revenue − Expenses − Withdrawals</p>
    <div className="finance-actions" role="group" aria-label="Tabular reporting position">{(['opening', 'movement', 'closing'] as const).map(value => <button className="btn btn-secondary" key={value} aria-pressed={side === value} onClick={() => setSide(value)}>{value === 'opening' ? 'Opening' : value === 'movement' ? 'Period movement' : 'Closing'}</button>)}</div>
    <div className="finance-table-scroll"><table className="finance-table"><thead><tr><th>Business line</th>{columns.map(([key, label]) => <th key={key}>{label}</th>)}<th>Difference</th></tr></thead><tbody>{rows.map(row => {
      const v = row.values;
      const difference = Math.round((v.cash + v.receivables + v.supplies + v.equipment - v.loan - v.payables - v.capital - v.revenue + v.expenses + v.withdrawals) * 100) / 100;
      return <tr key={row.name}><th scope="row">{row.name}</th>{columns.map(([key]) => <td className="finance-money" key={key}>{formatBDT(v[key])}</td>)}<td className={difference ? 'payment-error' : 'finance-money'}>{formatBDT(difference)}</td></tr>;
    })}</tbody></table></div>
    <p className="finance-note">Each real wallet has one balance. Business Cash shows how each business uses the shared funds and may be negative. Capital includes recorded opening equity, prior retained earnings and business allocations. Combined adds the three businesses without eliminating transport charges.</p>
  </section>;
}
