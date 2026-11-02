export const businessLines = ['lpg', 'stove', 'logistics'] as const;
export type BusinessLine = typeof businessLines[number];
export type BusinessAllocation = Partial<Record<BusinessLine, number>>;
export const businessNames: Record<BusinessLine, string> = { lpg: 'LPG', stove: 'Stove', logistics: 'Logistics' };
export interface FinancialType {
 type_id: string; tenant_id: string | null; code: string | null; name: string;
 origin: 'system' | 'custom'; account: string | null; allocations: BusinessAllocation;
 is_active: boolean; revision: number;
}
export interface FixedAccountingCategory { code: string; name: string; account: string }
export interface FinancialCatalog { types: FinancialType[]; categories: FixedAccountingCategory[] }
export interface PeriodFinancialValues {
 stock_acquisitions: number; stock_change: number; equipment_acquisitions: number;
 receivable_change: number; payable_change: number; loan_movement: number; wallet_movement: number;
}
