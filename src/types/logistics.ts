export type { FinanceWallet as Wallet } from './finance';
export interface Vehicle {
 tenant_id: string; vehicle_id: string; name: string; serial_no: string; capacity: number;
 status: 'idle' | 'coming' | 'going'; location: string; revision: number;
 driver_employee_id: string | null; helper_employee_id: string | null; driver_name: string | null; helper_name: string | null;
 created_at: string; updated_at: string;
}
export interface VehicleInput { vehicle_id?: string; revision?: number; name: string; serial_no: string; capacity: number; driver_employee_id: string | null; helper_employee_id: string | null }
export interface Assignment { assignment_id: string; vehicle_id: string; vehicle_name: string; employee_id: string; employee_name: string; role: 'driver' | 'helper'; started_at: string; ended_at: string | null }
export interface LogisticsFilters { search?: string; status?: string; type?: string; from?: string; to?: string; sort?: string; vehicle_id?: string; employee_id?: string }
export interface LogisticsSummary { assignments: number; current_vehicle: string | null; vehicles: number; home: number; transits: number; active: number; awaiting_completion: number; earnings: number; paid: number; outstanding: number; transport_fees: number; operating_costs: number }
export type TransitStatus = 'active' | 'returned' | 'completed' | 'cancelled';
export interface AdditionalCost { name: string; amount: number }
export interface Transit {
 tenant_id: string; transit_id: string; vehicle_id: string; vehicle_name: string; purchase_id: string | null;
 status: TransitStatus; transport_fee: number; driver_cost: number; helper_cost: number; oil_cost: number; others_cost: number;
 client_name: string | null; destination: string | null; description: string | null; revision: number; closed_at: string | null;
 additional_costs: AdditionalCost[]; total_cost: number; created_at: string; updated_at: string;
 driver_employee_id: string | null; helper_employee_id: string | null; driver_name: string | null; helper_name: string | null; crew_recorded_at: string | null;
 driver_paid: number; helper_paid: number; outstanding: number;
 purchase_refund_due?: number; purchase_financial_closed_at?: string | null;
}
export const transitStatus = (t: Pick<Transit, 'status' | 'closed_at'>) => t.status === 'cancelled' ? (t.closed_at ? 'Cancelled · settled' : 'Cancelled') : t.closed_at ? 'Completed' : t.status === 'active' ? 'In transit' : 'Returned';
