export type BusinessRole = 'OWNER' | 'MANAGER' | 'SALESMAN';
export interface AccessContext {
  tenant_id: string | null; business_name: string | null; full_name: string; email: string;
  role: BusinessRole | 'SUPERADMIN' | null; is_superadmin: boolean;
  must_change_password: boolean; reset_pending: boolean;
  access_status: 'active' | 'disabled' | 'suspended' | 'unassigned'; permissions: string[];
}
export interface PermissionDefinition { id: string; module: string; label: string; description: string | null; owner_only: boolean; dependencies: string[] }
export interface BusinessUser {
  user_id: string; tenant_id: string; email: string; full_name: string; is_active: boolean; revision: number;
  role: BusinessRole; created_at: string; last_sign_in_at: string | null; must_change_password: boolean;
  reset_pending: boolean; custom_permissions: string[] | null; permissions: string[];
}
export interface BusinessUserDirectory { entries: BusinessUser[]; total: number; role_defaults: Record<'MANAGER' | 'SALESMAN', string[]> }
export interface PlatformBusiness { tenant_id: string; business_name: string; status: 'active' | 'suspended'; created_at: string; users: number }
export interface PlatformDashboard { businesses: number; active: number; suspended: number; users: number; database_bytes: number; uploaded_bytes: number; files: number }
export interface StorageUsage { measured_at: string; database_bytes: number; uploaded_bytes: number; businesses: { tenant_id: string; business_name: string; database_estimate_bytes: number; uploaded_bytes: number; files: number }[] }
export interface AccessActivity { audit_id: string; action: string; actor_email: string | null; target_email: string | null; business_name: string | null; details: Record<string, unknown>; created_at: string }
export interface AccountOperation { kind: 'business' | 'user' | 'reset'; tenant_id?: string; business_name?: string; name?: string; email?: string; role?: 'MANAGER' | 'SALESMAN'; user_id?: string }
