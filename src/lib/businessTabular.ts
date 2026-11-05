import type { FinancialPosition } from '../types/accounting';

export const columns = [
  ['cash', 'Cash'], ['receivables', 'Accounts Receivable'], ['supplies', 'Supplies'],
  ['equipment', 'Equipment'], ['loan', 'Loan'], ['payables', 'Accounts Payable'],
  ['capital', 'Capital'], ['revenue', 'Revenue'], ['expenses', 'Expenses'], ['withdrawals', 'Withdrawals'],
] as const;
type Column = typeof columns[number][0];
export type Values = Record<Column, number>;
export function tabular(position: FinancialPosition): Values {
  const supplies = position.accounts.filter(a => a.kind === 'asset' && ['inventory_lpg', 'inventory_stove', 'inventory_transit', 'bottle_receivable'].includes(a.account)).reduce((sum, a) => sum + a.amount, 0);
  const equipment = position.accounts.filter(a => a.kind === 'asset' && ['vehicles', 'equipment', 'other_assets'].includes(a.account)).reduce((sum, a) => sum + a.amount, 0);
  const loan = position.accounts.filter(a => a.kind === 'liability' && a.account === 'loan_payable').reduce((sum, a) => sum + a.amount, 0);
  return {
    cash: position.cash, receivables: position.assets - position.cash - supplies - equipment,
    supplies, equipment, loan, payables: position.liabilities - loan,
    capital: position.capital + position.other_equity, revenue: position.revenue,
    expenses: position.expenses, withdrawals: position.withdrawals,
  };
}
export const subtract = (a: Values, b: Values): Values => Object.fromEntries(columns.map(([key]) => [key, a[key] - b[key]])) as Values;

