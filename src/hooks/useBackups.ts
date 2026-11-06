import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import type { BackupStatus } from '../types/backup';

export async function backupRequest<T>(path: string, body: Record<string, unknown> = {}): Promise<T> {
  const { data } = await supabase.auth.getSession();
  if (!data.session) throw new Error('Sign in again to manage backups.');
  const response = await fetch(`${import.meta.env.VITE_SUPABASE_URL}/backups/v1/${path}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${data.session.access_token}` },
    body: JSON.stringify(body), signal: AbortSignal.timeout(30_000),
  });
  const result = await response.json();
  if (!response.ok) throw new Error(result.error ?? 'Backup service is unavailable. Retry shortly.');
  return result;
}
export function useBackups() {
  return useQuery({ queryKey: ['platform-backups'], queryFn: () => backupRequest<BackupStatus>('status'),
    refetchInterval: query => ['queued', 'running'].includes(query.state.data?.job.status ?? '') ? 2_000 : 30_000 });
}
export function useBackupAction() {
  const cache = useQueryClient();
  return useMutation({ mutationFn: ({ action, body }: { action: 'connect' | 'disconnect' | 'queue' | 'settings' | 'full'; body?: Record<string, unknown> }) =>
    backupRequest<{ ok?: boolean; url?: string }>(action, body),
  onSuccess: () => cache.invalidateQueries({ queryKey: ['platform-backups'] }) });
}

export function useSensitiveConfirmation() {
 return useMutation({mutationFn:({action,target,password}:{action:'restore'|'delete-inspection'|'delete-rollback'|'delete-business';target:string;password:string})=>backupRequest<{confirmation_token:string;expires_in:number}>('authorize',{action,target,password})});
}
