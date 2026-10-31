import type { PaymentInput } from './finance';
export interface VehicleExpenseCategory {
  category_id: string;
  name: string;
  is_active: boolean;
  revision: number;
}
export interface ServiceExpense {
  category_id: string;
  category_name?: string;
  amount: number;
  description: string;
}
export interface ServiceTrip {
  service_trip_id: string;
  vehicle_id: string;
  vehicle_name: string;
  title: string;
  service_date: string;
  expenses: ServiceExpense[];
  total_cost: number;
  paid: number;
  outstanding: number;
  advance: number;
  revision: number;
  finalized_at: string | null;
  created_at: string;
}
export type OperatingPaymentKind =
  | 'expense'
  | 'expense_return'
  | 'client_receipt'
  | 'client_refund';
export interface OperatingPayment {
  payment_id: string;
  kind: OperatingPaymentKind;
  wallet_id: string;
  wallet_name: string;
  method: string;
  amount: number;
  returned: number;
  reference: string;
  payment_date: string;
  created_at: string;
}
export interface ServiceTripDraft {
  service_trip_id?: string;
  vehicle_id: string;
  revision?: number;
  title: string;
  service_date: string;
  expenses: ServiceExpense[];
}
export interface OperatingPaymentInput {
  transit_id?: string;
  service_trip_id?: string;
  kind: OperatingPaymentKind;
  payment_date: string;
  return_of?: string;
  payments: PaymentInput[];
}
export type VehicleAccountingOperation =
  | { action: 'save'; payload: ServiceTripDraft }
  | { action: 'payment'; payload: OperatingPaymentInput }
  | { action: 'finalize'; service_trip_id: string; revision: number };
