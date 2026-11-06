import { useState, type FormEvent } from 'react';
import { ShieldAlert } from 'lucide-react';
import { useSensitiveConfirmation } from '../../hooks/useBackups';
import { PurchaseDialog } from '../purchases/PurchaseControls';

export type SensitiveAction = 'restore' | 'delete-inspection' | 'delete-rollback' | 'delete-business';

export function SensitiveActionDialog({ action, target, name, description, onClose, onConfirm }: {
  action: SensitiveAction; target: string; name: string; description: string;
  onClose: () => void; onConfirm: (token: string, confirmation: string) => Promise<void>;
}) {
  const authorize = useSensitiveConfirmation();
  const [password, setPassword] = useState('');
  const [token, setToken] = useState<string | null>(null);
  const [confirmation, setConfirmation] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const phrase = action === 'restore' ? 'RESTORE' : 'DELETE';
  async function submit(event: FormEvent) {
    event.preventDefault(); setError('');
    if (!token) {
      try { const result = await authorize.mutateAsync({ action, target, password }); setPassword(''); setToken(result.confirmation_token); }
      catch { setPassword(''); }
      return;
    }
    if (confirmation !== phrase) return;
    setBusy(true);
    try { await onConfirm(token, confirmation); onClose(); }
    catch (failure) { setError(failure instanceof Error ? failure.message : 'The operation could not start. Check its status before retrying.'); setToken(null); setConfirmation(''); }
    finally { setBusy(false); }
  }
  return <PurchaseDialog key={token ? 'confirm' : 'password'} compact className="sensitive-action-dialog" title={token ? `Confirm ${action === 'restore' ? 'restore' : 'deletion'}` : 'Verify your identity'} subtitle={name} onClose={onClose} busy={busy || authorize.isPending}>
    <form onSubmit={submit}><div className="modal-body access-form">
      {token ? <><div className="sensitive-action-warning"><ShieldAlert size={24} aria-hidden="true"/><p>{description}</p></div><label className="input-group"><span className="input-label">Type {phrase} to confirm</span><input autoFocus className="input-field" autoComplete="off" spellCheck={false} value={confirmation} onChange={e => setConfirmation(e.target.value)} required /></label><small>Password confirmation expires after five minutes.</small></> : <><p>Enter your current administrator password to continue.</p><label className="input-group"><span className="input-label">Current password</span><input autoFocus type="password" autoComplete="current-password" className="input-field" value={password} onChange={e => setPassword(e.target.value)} required maxLength={128} disabled={authorize.isPending}/></label></>}
      {(error || authorize.error) && <p className="purchase-error" role="alert">{error || authorize.error?.message}</p>}
    </div><div className="modal-footer"><button className="btn btn-secondary" type="button" onClick={onClose} disabled={busy || authorize.isPending}>Cancel</button><button className={`btn ${token ? 'btn-danger' : 'btn-primary'}`} disabled={busy || authorize.isPending || (token !== null && confirmation !== phrase)}>{busy ? 'Starting…' : authorize.isPending ? 'Verifying…' : token ? action === 'restore' ? 'Restore platform' : 'Delete permanently' : 'Verify password'}</button></div></form>
  </PurchaseDialog>;
}
