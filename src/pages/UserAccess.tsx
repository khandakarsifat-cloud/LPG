import { useState } from 'react';
import { Plus, Pencil, KeyRound } from 'lucide-react';
import { useAuth } from '../contexts/AuthContext';
import { useBusinessUsers, usePermissionCatalog, useAccessActivity } from '../hooks/useAccessManagement';
import { EditAccessForm, ProvisionAccountForm } from '../components/access/AccountForms';
import type { BusinessUser } from '../types/access';
import './access-management.css';

export function UserAccessPage(){return <BusinessUsers/>;}
export function BusinessUsers({tenantId,businessName}:{tenantId?:string;businessName?:string}) {
 const {user,access}=useAuth();const [page,setPage]=useState(0);const [search,setSearch]=useState('');const [editing,setEditing]=useState<BusinessUser|null>(null);const [reset,setReset]=useState<BusinessUser|null>(null);const [creating,setCreating]=useState(false);const [activity,setActivity]=useState(false);
 const q=useBusinessUsers(tenantId,page,search);const catalog=usePermissionCatalog();
 return <div className="access-workspace"><header className="access-heading"><div><h1>{businessName??'User & Access Management'}</h1><p className="page-subtitle">Manage login accounts and application permissions. Employee job roles stay separate.</p></div><button className="btn btn-primary" onClick={()=>setCreating(true)}><Plus size={16}/>Create account</button></header>
  <div className="access-toolbar"><label className="input-group"><span className="input-label">Search accounts</span><input className="input-field" type="search" value={search} placeholder="Name or email" onChange={e=>{setSearch(e.target.value);setPage(0);}}/></label><button className="btn btn-secondary" aria-pressed={activity} onClick={()=>setActivity(v=>!v)}>{activity?'Hide access activity':'Review access activity'}</button></div>
  {(q.isPending||catalog.isPending)&&<p role="status">Loading accounts and permissions…</p>}
  {(q.error||catalog.error)&&<p role="alert" className="purchase-error">{q.error?.message??catalog.error?.message}</p>}
  <div className="access-user-grid">{q.data?.entries.map(account=><article className="settings-card access-user-card" key={account.user_id}>
   <header><div><h2>{account.full_name}</h2><p>{account.email}</p></div><span className="purchase-badge">{account.role}</span></header>
   <dl><div><dt>Status</dt><dd>{account.is_active?'Active':'Disabled'}</dd></div><div><dt>Access</dt><dd>{account.role==='OWNER'?'Full business access':account.custom_permissions?'Custom permissions':'Role defaults'}</dd></div><div><dt>Last sign-in</dt><dd>{account.last_sign_in_at?new Date(account.last_sign_in_at).toLocaleString('en-BD',{timeZone:'Asia/Dhaka'}):'Never'}</dd></div></dl>
   {account.must_change_password&&<p className="purchase-hint">{account.reset_pending?'Password reset awaiting recovery':'Password change required at next sign-in'}</p>}
   {account.user_id===user?.id?<p className="purchase-hint">Your account · change your password in Account & password.</p>:account.role!=='OWNER'||access?.is_superadmin?<div className="access-actions"><button className="btn btn-secondary" disabled={!catalog.data} onClick={()=>setEditing(account)}><Pencil size={15}/>Manage access</button><button className="btn btn-secondary" onClick={()=>setReset(account)}><KeyRound size={15}/>Reset password</button></div>:<p className="purchase-hint">OWNER account · protected full access.</p>}
  </article>)}</div>
  {q.data&&!q.data.total&&<p className="empty-state">No accounts match this search.</p>}
  {q.data&&<AccessPagination page={page} total={q.data.total} onChange={setPage} busy={q.isFetching}/>}
  {activity&&<AccessActivity tenantId={tenantId??access?.tenant_id??undefined}/>}
  {creating&&<ProvisionAccountForm tenantId={tenantId??access?.tenant_id??undefined} onClose={()=>setCreating(false)}/>}
  {reset&&<ProvisionAccountForm tenantId={tenantId} resetUser={reset} onClose={()=>setReset(null)}/>}
  {editing&&catalog.data&&q.data&&<EditAccessForm user={editing} catalog={catalog.data} roleDefaults={q.data.role_defaults} tenantId={tenantId} onClose={()=>setEditing(null)}/>}
 </div>;
}
export function AccessPagination({page,total,onChange,busy}:{page:number;total:number;onChange:(page:number)=>void;busy:boolean}) {
 return <div className="access-pagination"><span>{total?`${page*25+1}–${Math.min(total,(page+1)*25)} of ${total}`:'0 results'}</span><button className="btn btn-secondary" disabled={busy||page===0} onClick={()=>onChange(page-1)}>Previous</button><button className="btn btn-secondary" disabled={busy||(page+1)*25>=total} onClick={()=>onChange(page+1)}>Next</button></div>;
}
export function AccessActivity({tenantId}:{tenantId?:string}) {
 const [page,setPage]=useState(0);const q=useAccessActivity(tenantId,page);
 return <section className="settings-card access-activity"><h2>Access activity</h2>{q.isPending&&<p role="status">Loading activity…</p>}{q.error&&<p role="alert" className="purchase-error">{q.error.message}</p>}
 {q.data?.entries.map(event=><article key={event.audit_id}><div><strong>{event.action.replaceAll('_',' ')}</strong><time dateTime={event.created_at}>{new Date(event.created_at).toLocaleString('en-BD',{timeZone:'Asia/Dhaka'})}</time></div><p>{event.actor_email??'System'}{event.target_email?` → ${event.target_email}`:''}{event.business_name?` · ${event.business_name}`:''}</p>{Object.keys(event.details).length>0&&<details><summary>Action details</summary><pre>{JSON.stringify(event.details,null,2)}</pre></details>}</article>)}
 {q.data?.entries.length===0&&<p>No access activity recorded.</p>}<div className="access-actions"><button className="btn btn-secondary" disabled={page===0||q.isFetching} onClick={()=>setPage(p=>p-1)}>Newer</button><button className="btn btn-secondary" disabled={q.isFetching||(q.data?.entries.length??0)<25} onClick={()=>setPage(p=>p+1)}>Older</button></div></section>;
}
