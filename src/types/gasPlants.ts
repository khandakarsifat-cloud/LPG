// ── Gas Plants & Area Officers — domain types ─────────────────────────────

export interface GasPlant {
  tenant_id:   string;
  plant_id:    string;
  plant_name:  string;
  brand_id:    string | null;
  brand_name:  string | null;
  location:    string | null;
  is_active:   boolean;
  created_at:  string;
  updated_at:  string;
  // Area officer (joined from area_officers — one per plant for now)
  officer_id:     string | null;
  officer_name:   string | null;
  whatsapp_phone: string | null;
  email:          string | null;
}

export interface AreaOfficer {
  tenant_id:      string;
  officer_id:     string;
  plant_id:       string;
  officer_name:   string;
  whatsapp_phone: string | null;
  email:          string | null;
  created_at:     string;
  updated_at:     string;
}

export interface CreateGasPlantPayload {
  plant_name: string;
  brand_id?:  string | null;
  location?:  string;
}

export interface UpdateGasPlantPayload {
  plant_id:    string;
  plant_name?: string;
  brand_id?:   string | null;
  location?:   string;
  is_active?:  boolean;
}

export interface CreateAreaOfficerPayload {
  plant_id:        string;
  officer_name:    string;
  whatsapp_phone?: string;
  email?:          string;
}

export interface UpdateAreaOfficerPayload {
  officer_id:      string;
  officer_name?:   string;
  whatsapp_phone?: string;
  email?:          string;
}
