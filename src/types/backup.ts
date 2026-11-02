export interface RecoveryPoint {
  label: string; snapshot_id: string; captured_at: string; type: 'full' | 'incr'; monthly: boolean;
  status: 'verified' | 'uploaded' | 'failed'; available: boolean; backup_bytes: number; database_bytes: number;
  cloud_bytes_added: number; processed_bytes: number; upload_bytes_per_second: number; duration_seconds: number;
  verified_at?: string; error?: string;
}
export interface BackupStatus {
  overdue?: boolean;
  connection: { connected: boolean; status: string; account?: string | null; connected_at?: string; validated_at?: string };
  authorization_error?: { message: string; at: string } | null;
  settings: { enabled: boolean }; queued: boolean; next_run: string; credentials_installed: boolean; key_exported: boolean;
  job: { status: 'idle' | 'running' | 'failed' | 'interrupted'; phase?: string; started_at?: string; failed_at?: string; error?: string };
  history: RecoveryPoint[];
  usage: { total?: number; used?: number; free?: number; backup_bytes: number; objects: number; measured_at: string } | null;
  recovery: { verified_at: string; snapshot_id: string; files_verified: boolean; auth_health: boolean; storage_health: boolean; limitation: string } | null;
}
