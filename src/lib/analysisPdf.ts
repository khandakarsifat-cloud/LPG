import { jsPDF } from 'jspdf';
import type { JournalReport } from '../types/accounting';

/** Export the loaded canonical report; never fetch or recalculate a different scope. */
export function exportAnalysisPdf(r: JournalReport) {
  const doc = new jsPDF(); let y = 18;
  const money = (value: number | null) => value === null ? 'Unavailable' : `Tk ${value.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
  const line = (text: string) => {
    const parts: string[] = doc.splitTextToSize(text, 175);
    for (const part of parts) { if (y > 278) { doc.addPage(); y = 18; } doc.text(part, 16, y); y += 5.5; }
  };
  const heading = (text: string) => { if (y > 255) { doc.addPage(); y = 18; } y += 5; doc.setFont('helvetica', 'bold'); doc.setFontSize(12); line(text); doc.setFont('helvetica', 'normal'); doc.setFontSize(9); };
  doc.setFontSize(17); line('Business financial analysis'); doc.setFontSize(9);
  line(`${r.from} to ${r.to} | Business activity: ${r.category}`);
  line(!r.complete ? 'Incomplete: essential recorded asset values are missing.' : r.estimated ? 'Reconstructed development estimates are included and identified below.' : 'Recorded accounting values.');
  if (r.category !== 'all') line('Revenue, expenses and cash use the selected activity; assets, liabilities and net worth remain combined.');
  heading('Overview');
  for (const [label, value] of [['Net profit', r.totals.profit], ['Available cash at period end', r.closing.cash], ['Total assets', r.closing.assets], ['Total liabilities', r.closing.liabilities], ["Owner's equity", r.closing.equity], ['Invested capital', r.invested_capital], ['Period owner withdrawals', r.totals.withdrawals], ['Net cash flow', r.totals.cash_flow]] as const) line(`${label}: ${money(value)}`);
  for (const [label, position] of [['Opening position', r.opening], ['Closing position', r.closing]] as const) {
    heading(label); line(`Assets ${money(position.assets)} | Liabilities ${money(position.liabilities)} | Equity ${money(position.equity)}`);
    for (const account of position.accounts) line(`${account.kind}: ${account.account === 'cash' ? account.entity_name ?? account.name : account.name}: ${money(account.amount)}`);
  }
  heading('Profit and loss');
  for (const category of r.categories) line(`${category.kind === 'income' ? 'Revenue' : 'Expense'} - ${category.name}: ${money(category.amount)}`);
  line(`Revenue ${money(r.totals.revenue)} | Expenses ${money(r.totals.expenses)} | Net profit ${money(r.totals.profit)}`);
  heading('Capital and withdrawals');
  line(`Contributions ${money(r.totals.contributions)} | Withdrawals ${money(r.totals.withdrawals)} | Other equity movements ${money(r.totals.equity_adjustments)}`);
  line(`Retained earnings ${money(r.retained_earnings)} | Withdrawals to date ${money(r.withdrawals_to_date)}`);
  heading('Cash flow');
  for (const category of r.cash_categories) line(`${category.category}: received ${money(category.received)}, paid ${money(category.spent)}, net ${money(category.net)}`);
  line(`Cash received ${money(r.totals.cash_in)} | Cash paid ${money(r.totals.cash_out)} | Net ${money(r.totals.cash_flow)}`);
  line(`Internal wallet transfers ${money(r.totals.transfers)} are excluded from net cash flow.`);
  heading('Business activity comparison');
  for (const business of r.businesses) line(`${business.business_category}: revenue ${money(business.revenue)}, expenses ${money(business.expenses)}, profit ${money(business.revenue - business.expenses)}`);
  heading('Performance, cash and net-worth trends');
  line('Each row uses the same interval and records as the on-screen charts.');
  for (const point of r.trend) { line(`${point.period}: Revenue ${money(point.revenue)} | Expenses ${money(point.expenses)} | Profit ${money(point.profit)}`); line(`Cash in ${money(point.cash_in)} | Cash out ${money(point.cash_out)} | Net worth ${money(point.net_worth)}`); }
  heading('Reconciliation and valuation basis');
  line(`Assets ${money(r.closing.assets)} = Liabilities ${money(r.closing.liabilities)} + Equity ${money(r.closing.equity)}`);
  line(`Period profit from changes in net assets after contributions, withdrawals and other equity movements: ${money(r.totals.position_profit)}`);
  line('Approximate buying prices and manually configured commissions are operational references and never determine these financial values.');
  for (const coverage of r.coverage) line(coverage.note);
  const pages = doc.getNumberOfPages();
  for (let page = 1; page <= pages; page++) { doc.setPage(page); doc.setFontSize(8); doc.text(`Financial analysis | ${r.from} - ${r.to} | Page ${page} of ${pages}`, 16, 289); }
  doc.save(`business-accounting-${r.from}-${r.to}.pdf`);
}
