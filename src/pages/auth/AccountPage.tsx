import { useState, type FormEvent } from 'react';
import { Link, Navigate } from 'react-router-dom';
import { KeyRound, LogOut } from 'lucide-react';
import { useAuth } from '../../contexts/AuthContext';
import { useChangePassword } from '../../hooks/useAccessManagement';
import '../access-management.css';

export function AccountPage() {
 const {session,access,isLoading,signOut}=useAuth();const change=useChangePassword();
 const [current,setCurrent]=useState('');const [password,setPassword]=useState('');const [confirm,setConfirm]=useState('');const [validation,setValidation]=useState('');const [done,setDone]=useState(false);
 if(isLoading)return <div className="empty-state" role="status">Loading account…</div>;
 if(!session&&!done)return <Navigate to="/login" replace/>;
 async function submit(e:FormEvent){e.preventDefault();setValidation('');if(password!==confirm){setValidation('New passwords do not match.');return;}
  try{await change.mutateAsync({currentPassword:current,password});setCurrent('');setPassword('');setConfirm('');setDone(true);await signOut();}catch{/* inline error */}}
 return <main className="account-screen"><section className="settings-card account-card">
  <KeyRound size={28} aria-hidden="true"/><h1>{done?'Password changed':access?.must_change_password?'Set your own password':'Account & password'}</h1>
  {done?<><p>All previous sessions have been closed. Sign in with your new password.</p><Link className="btn btn-primary" to="/login">Sign in</Link></>:<>
   <p>{access?.email??session?.user.email}</p><p>{access?.must_change_password?'Your temporary password must be changed before you can use the application.':'Choose a strong password. Changing it signs you out on every device.'}</p>
   {access?.reset_pending?<p role="alert">A password reset is still being completed. Contact your administrator.</p>:<form className="access-form" onSubmit={submit}>
    <label className="input-group"><span className="input-label">Current password</span><input className="input-field" type="password" autoComplete="current-password" required value={current} onChange={e=>setCurrent(e.target.value)}/></label>
    <label className="input-group"><span className="input-label">New password</span><input className="input-field" aria-label="New password" aria-describedby="new-password-hint" type="password" autoComplete="new-password" minLength={12} maxLength={128} required value={password} onChange={e=>setPassword(e.target.value)}/><small id="new-password-hint">12–128 characters, including uppercase, lowercase and a number.</small></label>
    <label className="input-group"><span className="input-label">Confirm new password</span><input className="input-field" type="password" autoComplete="new-password" required value={confirm} onChange={e=>setConfirm(e.target.value)}/></label>
    {(validation||change.error)&&<p className="purchase-error" role="alert">{validation||change.error?.message}</p>}
    <button className="btn btn-primary" disabled={change.isPending}>{change.isPending?'Changing password…':'Change password'}</button>
   </form>}
   <div className="access-actions">{!access?.must_change_password&&<Link className="btn btn-secondary" to={access?.is_superadmin?'/admin':'/'}>Back to workspace</Link>}<button className="btn btn-secondary" onClick={()=>void signOut()} disabled={change.isPending}><LogOut size={16}/>Sign out</button></div>
  </>}
 </section></main>;
}
