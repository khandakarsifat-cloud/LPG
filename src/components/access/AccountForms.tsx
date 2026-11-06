import { useState, type FormEvent } from 'react';
import { useProvisionAccount, useSaveBusinessUser, useBusinessWalletAccess } from '../../hooks/useAccessManagement';
import { PurchaseConfirmation, PurchaseDialog } from '../purchases/PurchaseControls';
import type { AccountOperation, BusinessUser, PermissionDefinition, UserWalletAccess } from '../../types/access';
import { permissionSelection } from '../../lib/accessPermissions';
import { useAuth } from '../../contexts/AuthContext';

function readPendingAccount(key:string):{requestId:string;operation:AccountOperation}|null {
 try{const value=JSON.parse(sessionStorage.getItem(key)??'null');return value&&typeof value.requestId==='string'&&value.operation?value:null;}catch{return null;}
}

export function ProvisionAccountForm({tenantId,onClose,business=false,resetUser}:{tenantId?:string;onClose:()=>void;business?:boolean;resetUser?:BusinessUser}) {
 const {user}=useAuth();const provision=useProvisionAccount();
 const pendingKey=`lpg-account-operation:${user?.id}:${resetUser?.user_id??tenantId??'platform'}:${resetUser?'reset':business?'business':'user'}`;
 const [pending]=useState(()=>readPendingAccount(pendingKey));const [requestId,setRequestId]=useState(()=>pending?.requestId??crypto.randomUUID());
 const [name,setName]=useState(pending?.operation.name??'');const [email,setEmail]=useState(pending?.operation.email??'');const [businessName,setBusinessName]=useState(pending?.operation.business_name??'');const [role,setRole]=useState<'MANAGER'|'SALESMAN'>(pending?.operation.role??'SALESMAN');const [password,setPassword]=useState('');const [confirmation,setConfirmation]=useState('');
 const [submitted,setSubmitted]=useState<AccountOperation|null>(pending?.operation??null);
 async function submit(e:FormEvent){e.preventDefault();const operation:AccountOperation=submitted??(resetUser?{kind:'reset',tenant_id:tenantId??resetUser.tenant_id,user_id:resetUser.user_id}:business?{kind:'business',business_name:businessName.trim(),name:name.trim(),email:email.trim().toLowerCase()}:{kind:'user',tenant_id:tenantId,name:name.trim(),email:email.trim().toLowerCase(),role});
  setSubmitted(operation);sessionStorage.setItem(pendingKey,JSON.stringify({requestId,operation}));
  try{await provision.mutateAsync({requestId,operation,password});sessionStorage.removeItem(pendingKey);setPassword('');onClose();}
  catch(error){if(error instanceof Error&&(error.message==='An account with this email already exists.'||error.message.includes('reset was superseded'))){sessionStorage.removeItem(pendingKey);setSubmitted(null);setRequestId(crypto.randomUUID());}}}
 return <PurchaseDialog title={resetUser?'Reset account password':business?'Register business':'Create login account'} subtitle={resetUser?.email??(business?'Create a business and its initial OWNER':'Employee job titles are managed separately in Employees.')} onClose={onClose} busy={provision.isPending} compact>
  <form onSubmit={submit}><div className="modal-body access-form">
   {!resetUser&&<fieldset className="access-form" disabled={provision.isPending||!!submitted}>
    {business&&<label className="input-group"><span className="input-label">Business name</span><input autoFocus className="input-field" required maxLength={255} value={businessName} onChange={e=>setBusinessName(e.target.value)}/></label>}
    <label className="input-group"><span className="input-label">{business?'Owner name':'Full name'}</span><input autoFocus={!business} className="input-field" required maxLength={255} value={name} onChange={e=>setName(e.target.value)}/></label>
    <label className="input-group"><span className="input-label">Login email</span><input className="input-field" type="email" autoComplete="off" required maxLength={255} value={email} onChange={e=>setEmail(e.target.value)}/></label>
    {!business&&<label className="input-group"><span className="input-label">Application role</span><select className="input-field" value={role} onChange={e=>setRole(e.target.value==='MANAGER'?'MANAGER':'SALESMAN')}><option value="SALESMAN">SALESMAN</option><option value="MANAGER">MANAGER</option></select></label>}
   </fieldset>}
   <label className="input-group"><span className="input-label">Temporary password</span><input className="input-field" aria-label="Temporary password" aria-describedby="temporary-password-hint" type="password" autoComplete="new-password" required minLength={12} maxLength={128} value={password} onChange={e=>setPassword(e.target.value)} disabled={provision.isPending}/><small id="temporary-password-hint">12–128 characters, including uppercase, lowercase and a number. Share it securely with the user.</small></label>
   <p>{resetUser?'Existing sessions will be closed immediately. ':''}The user must change this password at their next sign-in.</p>
   {resetUser&&<label className="input-group"><span className="input-label">Type the account email to confirm</span><input className="input-field" autoComplete="off" required value={confirmation} onChange={e=>setConfirmation(e.target.value)}/></label>}
   {submitted&&!provision.isPending&&<p className="purchase-alert">This request is saved for recovery. Retry here using the same temporary password. Request: {requestId}</p>}
   {provision.error&&<p className="purchase-error" role="alert">{provision.error.message}</p>}
  </div><div className="modal-footer"><button type="button" className="btn btn-secondary" onClick={onClose} disabled={provision.isPending}>Close</button><button className="btn btn-primary" disabled={provision.isPending||!!resetUser&&confirmation!==resetUser.email}>{provision.isPending?'Saving…':resetUser?'Reset password':business?'Create business & owner':'Create account'}</button></div></form>
 </PurchaseDialog>;
}

export function EditAccessForm({user,catalog,roleDefaults,tenantId,onClose}:{user:BusinessUser;catalog:PermissionDefinition[];roleDefaults:Record<'MANAGER'|'SALESMAN',string[]>;tenantId?:string;onClose:()=>void}) {
 const save=useSaveBusinessUser(tenantId);const [name,setName]=useState(user.full_name);const [role,setRole]=useState(user.role);const [active,setActive]=useState(user.is_active);const [custom,setCustom]=useState(user.custom_permissions!==null);const [perms,setPerms]=useState(user.permissions);const [confirm,setConfirm]=useState('');
 const walletQuery=useBusinessWalletAccess(user.user_id,tenantId);const [walletEdits,setWalletEdits]=useState<UserWalletAccess[]|null>(null);
 const [search,setSearch]=useState('');const [moduleFilter,setModuleFilter]=useState('All permissions');
 const [review,setReview]=useState(false);
 const owner=user.role==='OWNER';const groups=new Map<string,PermissionDefinition[]>();
 for(const permission of catalog.filter(p=>!p.owner_only)){const entries=groups.get(permission.module)??[];entries.push(permission);groups.set(permission.module,entries);}
 const defaults=role==='OWNER'?user.permissions:roleDefaults[role]??[];
 const selected=custom?perms:defaults;
 async function submit(){try{await save.mutateAsync({user,name,role,active,permissions:owner||!custom?null:perms,walletAccess:owner?undefined:walletEdits?.filter(w=>w.can_use!==null&&w.can_balance!==null&&w.can_history!==null)});onClose();}catch{/* inline */}}
 return <PurchaseDialog title="Manage account & access" subtitle={user.email} onClose={onClose} busy={save.isPending} className="access-editor-dialog">
 <form onSubmit={e=>{e.preventDefault();setReview(true);}}><div className="modal-body access-form">
  <div className="access-form-columns"><label className="input-group"><span className="input-label">Full name</span><input className="input-field" required maxLength={255} value={name} onChange={e=>setName(e.target.value)}/></label><label className="input-group"><span className="input-label">Application role</span><select className="input-field" value={role} disabled={owner} onChange={e=>setRole(e.target.value==='MANAGER'?'MANAGER':'SALESMAN')}>
   {owner?<option value="OWNER">OWNER · full access</option>:<><option value="MANAGER">MANAGER</option><option value="SALESMAN">SALESMAN</option></>}
  </select></label></div>
  <label className="access-check"><input type="checkbox" checked={active} onChange={e=>setActive(e.target.checked)}/><span>Account active<small>Deactivation closes existing sessions and blocks business access.</small></span></label>
  {!active&&user.is_active&&<label className="input-group"><span className="input-label">Type the email to confirm deactivation</span><input className="input-field" autoComplete="off" value={confirm} onChange={e=>setConfirm(e.target.value)}/></label>}
  {owner?<p className="purchase-alert">OWNER always retains every business permission. Owner promotion and ownership changes are protected server-side.</p>:<>
   <label className="access-check"><input type="checkbox" checked={custom} onChange={e=>{setCustom(e.target.checked);if(e.target.checked)setPerms(defaults);}}/><span>Customize this user’s permissions<small>Otherwise the role defaults apply. Required permissions are selected together.</small></span></label>
   <div className="access-permission-heading"><div><h3>Business permissions</h3><p>Choose what this account can view and do.</p></div><span className="access-selection-count">{selected.length} selected</span></div>
   <label className="input-group"><span className="input-label">Find a permission</span><input className="input-field" type="search" value={search} onChange={e=>setSearch(e.target.value)} placeholder="Search actions, pages or descriptions"/></label>
   <div className="access-permission-workspace"><nav className="access-module-nav" aria-label="Permission modules">{['All permissions',...groups.keys()].map(module=><button type="button" key={module} aria-current={moduleFilter===module?'page':undefined} onClick={()=>setModuleFilter(module)}>{module}<span>{module==='All permissions'?catalog.filter(p=>!p.owner_only).length:groups.get(module)?.length}</span></button>)}</nav>
   <div className="permission-groups">{[...groups].filter(([module])=>moduleFilter==='All permissions'||module===moduleFilter).map(([module,entries])=>{const matching=entries.filter(p=>`${p.label} ${p.description??''} ${p.id}`.toLowerCase().includes(search.trim().toLowerCase()));return matching.length>0&&<section className="access-permission-section" key={module}><header><h4>{module}</h4><span>{entries.filter(p=>selected.includes(p.id)).length} of {entries.length} enabled</span></header><div>{matching.map(p=><label className="access-check permission-row" key={p.id}><input type="checkbox" checked={selected.includes(p.id)} disabled={!custom||save.isPending} onChange={e=>setPerms(permissionSelection(perms,p.id,e.target.checked,catalog))}/><span><strong>{p.label}</strong>{p.description&&<small>{p.description}</small>}{p.dependencies.length>0&&<small className="permission-dependencies">Requires {p.dependencies.map(id=>catalog.find(x=>x.id===id)?.label??id).join(', ')}</small>}</span></label>)}</div></section>;})}</div></div>
   <section className="settings-card"><h3>Wallet access</h3><p className="purchase-hint">Use permits authorized payments without revealing balances. History requires Finance workspace access and reveals movements; Balance reveals the current and running balances. Analysis and Accounting activity require Balance access to every wallet.</p>
   {walletQuery.isPending&&<p role="status">Loading wallet access…</p>}{walletQuery.error&&<p role="alert">{walletQuery.error.message}</p>}
   <button type="button" className="btn btn-secondary" disabled={!walletQuery.data||save.isPending} onClick={()=>setWalletEdits((walletQuery.data??[]).map(w=>({...w,can_use:null,can_balance:null,can_history:null})))}>Use wallet defaults</button><div className="finance-table-scroll"><table className="finance-table wallet-access-table"><thead><tr><th>Wallet</th><th>Use</th><th>Balance</th><th>History</th></tr></thead><tbody>{(walletEdits??walletQuery.data??[]).map(w=><tr key={w.wallet_id}><th>{w.name}</th>{(['can_use','can_balance','can_history'] as const).map((key,i)=><td key={key}><input type="checkbox" aria-label={`${w.name} ${['Use','Balance','History'][i]}`} checked={w[key]??selected.includes(['wallets:use','wallets:balances','wallets:ledger'][i])} disabled={save.isPending} onChange={e=>setWalletEdits((walletEdits??walletQuery.data??[]).map(row=>{const effective={...row,can_use:row.can_use??selected.includes('wallets:use'),can_balance:row.can_balance??selected.includes('wallets:balances'),can_history:row.can_history??selected.includes('wallets:ledger')};return row.wallet_id===w.wallet_id?{...effective,[key]:e.target.checked}:effective;}))}/></td>)}</tr>)}</tbody></table></div><p className="purchase-hint">Wallets without individual overrides follow the role/custom default capabilities above. Saving individual choices fixes the displayed choices for these wallets; new wallets continue to follow defaults.</p>
   </section>
   <p className="purchase-hint">Sensitive business actions are granted individually. Only the owner and platform administrator can manage accounts and permissions; both retain full access.</p>
  </>}
  {save.error&&<p className="purchase-error" role="alert">{save.error.message}</p>}
 </div><div className="modal-footer"><button type="button" className="btn btn-secondary" disabled={save.isPending} onClick={onClose}>Cancel</button><button className="btn btn-primary" disabled={save.isPending||!active&&user.is_active&&confirm!==user.email}>{save.isPending?'Saving…':'Review access changes'}</button></div></form>
 {review&&<PurchaseConfirmation title="Review account access" action="Save access" busy={save.isPending} onCancel={()=>setReview(false)} onConfirm={()=>void submit()}><p><strong>{name}</strong> · {user.email}</p><p>{role} · {active?'Active':'Disabled'}</p><p>{custom?'Individual permissions':'Role defaults'}</p><ul>{selected.filter(p=>!user.permissions.includes(p)).map(p=><li key={p}>Enable: {catalog.find(x=>x.id===p)?.label??p}</li>)}{user.permissions.filter(p=>!selected.includes(p)).map(p=><li key={p}>Remove: {catalog.find(x=>x.id===p)?.label??p}</li>)}</ul>{walletEdits&&<p>Wallet access overrides will also be saved for {walletEdits.length} wallets. Review the Use, Balance and History choices before confirming.</p>}{save.error&&<p className="purchase-error" role="alert">{save.error.message}</p>}</PurchaseConfirmation>}

 </PurchaseDialog>;
}
