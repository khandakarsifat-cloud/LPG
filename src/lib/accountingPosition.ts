import type { AnalysisGroup, FinancialPosition } from '../types/accounting';

export function positionGroup(account: string, kind: string): AnalysisGroup {
 if (kind === 'asset') return account === 'cash' ? 'cash' : ['inventory_lpg', 'inventory_stove', 'inventory_transit', 'bottle_receivable'].includes(account) ? 'inventory' : ['vehicles', 'equipment', 'other_assets'].includes(account) ? 'fixed_assets' : ['customer_receivable', 'supplier_receivable', 'transport_receivable'].includes(account) ? 'receivables' : 'other_assets';
 return ['loan_payable', 'supplier_payable'].includes(account) ? 'dues' : account === 'employee_payable' ? 'employees' : 'other_liabilities';
}
export function positionGroupValue(p: FinancialPosition, group: AnalysisGroup): number {
 switch (group) {
  case 'assets': case 'liabilities': case 'equity': case 'capital': case 'revenue': case 'expenses': case 'withdrawals': case 'other_equity': case 'accumulated_income': return p[group];
  default: return p.accounts.filter(a => ['asset', 'liability'].includes(a.kind) && positionGroup(a.account, a.kind) === group).reduce((sum, a) => sum + a.amount, 0);
 }
}
