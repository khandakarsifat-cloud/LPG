// ── Shared domain types for the Logistics module ─────────────────────────────

export type TruckSize = 'big' | 'medium' | 'small';
export type TruckStatus = 'idle' | 'coming' | 'going';

export interface Truck {
  tenant_id: string;
  truck_id: string;
  name: string;
  serial_no: string;
  capacity: number;
  size: TruckSize;
  status: TruckStatus;
  location: string | null;
  created_at: string;
  updated_at?: string;
}

export interface CreateTruckPayload {
  name: string;
  serial_no: string;
  capacity: number;
  size: TruckSize;
  location?: string;
}

export interface UpdateTruckPayload {
  name?: string;
  serial_no?: string;
  capacity?: number;
  size?: TruckSize;
  status?: TruckStatus;
  location?: string | null;
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

export const TRUCK_STATUS_OPTIONS: TruckStatus[] = ['idle', 'coming', 'going'];

export const TRUCK_STATUS_LABELS: Record<TruckStatus, string> = {
  idle:   'Idle',
  coming: 'Coming In',
  going:  'Going Out',
};

export const TRUCK_STATUS_COLORS: Record<TruckStatus, string> = {
  idle:   'var(--text-muted)',
  coming: 'var(--accent)',
  going:  'var(--primary)',
};

export const TRUCK_STATUS_BG: Record<TruckStatus, string> = {
  idle:   'rgba(148,163,184,0.12)',
  coming: 'rgba(16,185,129,0.12)',
  going:  'rgba(59,130,246,0.12)',
};

// ── Wallets & Transits ────────────────────────────────────────────────────────
export type WalletType = 'dealership' | 'logistics';

export interface Wallet {
  tenant_id: string;
  wallet_id: string;
  type: WalletType;
  balance: number;
  created_at: string;
  updated_at: string;
}

export interface WalletTransaction {
  transaction_id: string;
  wallet_id: string;
  amount: number;
  type: string;
  reference_id: string | null;
  description: string | null;
  created_at: string;
}

export type TransitStatus = 'active' | 'completed' | 'cancelled';

export interface AdditionalCost {
  name: string;
  amount: number;
}

export interface Transit {
  tenant_id: string;
  transit_id: string;
  truck_id: string;
  purchase_id: string | null;
  status: TransitStatus;
  transport_fee: number;
  driver_cost: number;
  helper_cost: number;
  oil_cost: number;
  additional_costs: AdditionalCost[];
  total_cost: number;
  created_at: string;
  updated_at: string;
  
  // Joined fields for convenience
  truck_name?: string;
}
