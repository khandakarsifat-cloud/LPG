import { businessLines, businessNames } from '../types/financial';
import type { BusinessAllocation } from '../types/financial';

export function allocationText(value: BusinessAllocation) {
 return businessLines.filter(b => value[b]).map(b => `${businessNames[b]} ${value[b]}%`).join(' · ');
}
export function validAllocation(value: BusinessAllocation) {
 const numbers = Object.values(value);
 return numbers.length > 0 && numbers.every(n => Number.isFinite(n) && n > 0 && n <= 100) && Math.abs(numbers.reduce((sum, n) => sum + n, 0) - 100) < 0.000001;
}
export const customCategoryOptions = [
 { value: 'withdrawals', label: 'Withdrawal' },
 { value: 'operating_expense', label: 'Expense' },
 { value: 'capital', label: 'Capital' },
 { value: 'other_income', label: 'Revenue' },
 { value: 'equipment', label: 'Equipment' },
];
export function financialCategoryLabel(account: string) {
 return customCategoryOptions.find(c => c.value === account)?.label ?? (account === 'interest_expense' ? 'Expense' : account === 'other_assets' ? 'Equipment' : account);
}
