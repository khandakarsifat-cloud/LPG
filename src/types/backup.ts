export interface RecoveryPoint {
  label: string; snapshot_id: string; captured_at: string; type: 'full' | 'incr'; monthly: boolean;
  status: 'verified' | 'uploaded' | 'failed'; available: boolean; backup_bytes: number; database_bytes: number;
  cloud_bytes_added: number; processed_bytes: number; upload_bytes_per_second: number; duration_seconds: number;
  verified_at?: string; error?: string;
  started_at?: string; destination?: string; job_id?: string; generation?: string;
  previous_generation?: boolean;
}
export interface BackupJob {
  status: 'idle' | 'queued' | 'running' | 'completed' | 'failed' | 'interrupted';
  job_id?: string; mode?: 'manual-full' | 'scheduled'; phase?: string; detail?: string;
  percent?: number | null; processed_bytes?: number | null; total_bytes?: number | null;
  transferred_bytes?: number | null; network_transferred_bytes?: number | null; remaining_seconds?: number | null;
  started_at?: string; updated_at?: string; completed_at?: string; failed_at?: string;
  duration_seconds?: number; destination?: string; error?: string;
}
export interface BackupStatus {
  overdue?: boolean;
  connection: { connected: boolean; status: string; account?: string | null; connected_at?: string; validated_at?: string };
  authorization_error?: { message: string; at: string } | null;
  settings: { enabled: boolean }; queued: boolean; next_run: string; credentials_installed: boolean; key_exported: boolean;
  job: BackupJob; jobs?: BackupJob[];
  history: RecoveryPoint[];
  usage: { total?: number; used?: number; free?: number; backup_bytes: number; objects: number; measured_at: string } | null;
  recovery: { verified_at: string; snapshot_id: string; files_verified: boolean; auth_health: boolean; storage_health: boolean; limitation: string } | null;
}
