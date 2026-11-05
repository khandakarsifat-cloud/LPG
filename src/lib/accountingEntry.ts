import type { AccountingBreakdownEntry } from '../types/accounting';

const sourceNames: Record<string,string> = { purchase: 'Purchase recorded', purchase_rebate: 'Company rebate applied', inventory: 'Stock value updated', internal_transport: 'Transport added to purchase cost', internal_inventory: 'Transport in Supplies updated', internal_cogs: 'Transport recognized in COGS', sale: 'Sale recorded', salary_accrual: 'Salary earned', bonus: 'Bonus recorded', sale_bottle_claim_reversal: 'Bottle claim reversed', sale_exchange_reversal: 'Bottle exchange reversed' };
export function accountingSourceName(source: string) { return sourceNames[source] ?? source.replaceAll('_',' ').replace(/^./,c=>c.toUpperCase()); }
export function accountingEffectName(account: string, fallback: string) {
 const names: Record<string,string>={cash:'Cash',customer_receivable:'Customers owe',bottle_receivable:'Bottle value due',bottle_exchange:'Exchange difference'};
 return names[account] ?? fallback;
}
export function entryTitle(row: AccountingBreakdownEntry) {
 if (row.event_row && row.description) return row.description;
 if (sourceNames[row.source ?? '']) return sourceNames[row.source ?? ''];
 return (row.description || row.type_name || row.name).replace(/[\s·.]+$/,'').replaceAll('_',' ').replace(/^./,c=>c.toUpperCase());
}
export function explanation(row: AccountingBreakdownEntry) {
 const down=row.amount<0;
 if(row.account==='supplier_payable') return down?'This reduces the amount owed to the supplier.':'This adds to the amount owed to the supplier.';
 if(row.account==='loan_payable') return down?'Borrowed principal was reduced.':'Borrowed principal was added.';
 if(row.account==='loan_receivable') return down?'A repayment reduced the amount this person owes you.':'Money lent is still owed back to the business.';
 if(row.account==='cash') return down?'Business cash decreased.':'Business cash increased.';
 if(row.account==='customer_receivable') return down?'This reduces the amount owed by the customer.':'This adds to the amount owed by the customer.';
 if(row.source==='purchase_rebate' && row.account==='other_income') return 'Company rebate recognized as income. No wallet money moved.';
 if(row.account.startsWith('inventory')) return down?'Recorded inventory value decreased.':'Recorded inventory value increased.';
 return `${row.name} ${down?'decreased':'increased'} in this entry.`;
}
