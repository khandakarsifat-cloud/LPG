// ── Shared domain types for the Logistics module ─────────────────────────────

export type TruckSize = 'big' | 'medium' | 'small';

export interface Truck {
  tenant_id: string;
  truck_id: string;
  name: string;
  serial_no: string;
  capacity: number;
  size: TruckSize;
  is_active: boolean;
  created_at: string;
  updated_at?: string;
}

export interface CreateTruckPayload {
  name: string;
  serial_no: string;
  capacity: number;
  size: TruckSize;
}

export interface UpdateTruckPayload {
  name?: string;
  serial_no?: string;
  capacity?: number;
  size?: TruckSize;
  is_active?: boolean;
}

// Display helpers
export const TRUCK_SIZE_OPTIONS: TruckSize[] = ['big', 'medium', 'small'];

export const TRUCK_SIZE_LABELS: Record<TruckSize, string> = {
  'big': 'Big',
  'medium': 'Medium',
  'small': 'Small',
};

export const TRUCK_SIZE_DESCRIPTIONS: Record<TruckSize, string> = {
  'big': 'Large capacity trucks (35+ units)',
  'medium': 'Standard capacity trucks (20-35 units)',
  'small': 'Small capacity trucks (< 20 units)',
};
