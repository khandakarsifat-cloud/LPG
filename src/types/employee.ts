import type { PaymentInput, PaymentWallet } from './finance';
export type BusinessUnit = 'gas_business' | 'truck_business';
export interface EmployeePhone { phone: string; is_primary: boolean }
export interface Employee {
 business_allocations?: import('./financial').BusinessAllocation;
 employee_id: string; name: string; address: string | null; notes: string | null; business_unit: BusinessUnit;
 employee_type_name: string | null; current_salary: number; is_active: boolean; effective_from: string | null;
 joining_date: string; revision: number; phones: EmployeePhone[]; primary_phone: string | null;
}
export interface EmployeeTerm { term_id: string; effective_from: string; monthly_salary: number; is_active: boolean; reason: string }
export interface EmployeeInput {
 business_allocations?: import('./financial').BusinessAllocation;
 employee_id?: string; revision?: number; name: string; phones: EmployeePhone[]; address: string; notes: string;
 business_unit: BusinessUnit; employee_type_name: string; terms?: Omit<EmployeeTerm, 'term_id'>;
 attendance_links?: { device_id: string; pin: string | null; expected: string | null }[];
}
export interface EmployeeProfile { employee: Employee; terms: EmployeeTerm[] }
export interface EmployeeSalaryMonth { period: string; salary_amount: number; paid: number; outstanding: number; established: boolean }
export interface EmployeeOverview { employees: number; active: number; types: string[] }
export interface EmployeeFilters { search: string; status: string; unit: string; type: string; sort: string }
export interface ActivityFilters { employee_id?: string; search: string; kind: string; from: string; to: string }
export interface EmployeeActivity {
 id: string; employee_id: string; employee_name: string; kind: 'profile' | 'terms' | 'payment' | 'reversal' | 'attendance' | 'transit' | 'assignment';
 description: string; date: string; created_at: string; occurred_at?: string; actor: string | null; amount: number | null; reversible: boolean;
 details: { period?: string; reason?: string; reversal_of?: string; kind?: string; bonus_name?: string; transit_id?: string; trip_role?: string; source_snapshot?: { wallet_evidence: string }; effective_from?: string; is_active?: boolean; timezone?: string; manual?: boolean; automatic_close?: boolean; worked_seconds?: number; warning_count?: number };
 wallets: { entry_id: string; wallet_name: string; method: PaymentWallet['kind']; amount: number; reference: string; transaction_id: string }[];
}
export interface EmployeeResult<T> { entries: T[]; total: number }
export interface EmployeePayItem {
 employee_id: string; period?: string; kind: 'salary' | 'bonus' | 'trips'; bonus_name?: string; payment_date: string; description: string;
 payments: PaymentInput[]; trip_count?: number; transit_id?: string; trip_role?: 'driver' | 'helper';
}
export type EmployeeOperation = { action: 'pay'; items: [EmployeePayItem] }
 | { action: 'reverse_payment'; payment_id: string; reason: string; payment_date: string }
 | { action: 'profile'; profile: EmployeeInput };
