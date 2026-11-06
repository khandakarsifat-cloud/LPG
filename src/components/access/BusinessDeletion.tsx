import {useState} from 'react';
import {ShieldAlert,Trash2} from 'lucide-react';
import {useBusinessDeletionPreview,useBusinessDeletions,useDeleteBusiness} from '../../hooks/useBusinessDeletion';
import type {BusinessDeletionJob} from '../../hooks/useBusinessDeletion';
import {PurchaseDialog} from '../purchases/PurchaseControls';
import {SensitiveActionDialog} from './SensitiveActionDialog';

export function BusinessDeletionDialog({target,onClose}:{target:string;onClose:()=>void}) {
 const preview=useBusinessDeletionPreview(target);const remove=useDeleteBusiness();
 const [requestId]=useState(()=>crypto.randomUUID());const [confirming,setConfirming]=useState(false);
 const data=preview.data;const pending=data?.job&&['queued','running','completed'].includes(data.job.status);
 return <><PurchaseDialog title="Delete business" subtitle={data?.business_name} className="business-deletion-dialog" onClose={onClose}>
 <div className="modal-body access-form">
 <div className="sensitive-action-warning"><ShieldAlert size={26}/><div><strong>Permanent business removal</strong><p>This removes business records, uploaded files and dedicated login accounts. The business will be blocked while cleanup runs.</p></div></div>
 {preview.isPending&&<p role="status">Checking records and account ownership…</p>}{preview.error&&<p className="purchase-error" role="alert">{preview.error.message}</p>}
 {data&&<><dl className="deletion-impact"><div><dt>Business records</dt><dd>{Object.values(data.tables).reduce((sum,n)=>sum+n,0).toLocaleString()}</dd></div><div><dt>Uploaded files</dt><dd>{data.files}</dd></div><div><dt>Dedicated accounts</dt><dd>{data.accounts}</dd></div><div><dt>Shared / protected accounts kept</dt><dd>{data.preserved_accounts}</dd></div></dl>
 <details><summary>Review affected records</summary><div className="report-table-scroll"><table className="report-table"><thead><tr><th>Record group</th><th>Rows</th></tr></thead><tbody>{Object.entries(data.tables).map(([table,count])=><tr key={table}><th>{table.split('.')[1].replaceAll('_',' ')}</th><td>{count.toLocaleString()}</td></tr>)}</tbody></table></div></details>
 <ol className="deletion-steps"><li>A fresh encrypted backup is created and restored in isolation for verification.</li><li>Files and business records are removed. A failed cleanup stays blocked and can be resumed.</li><li>Dedicated logins are deleted; a minimal deletion audit and normal backup retention remain.</li></ol>
 <p className="purchase-hint">Shared database tables and indexes remain available to other businesses. Deleting their business rows removes the matching index entries automatically.</p>
 {!data.backup_ready&&<p className="purchase-alert">Connect Google Drive in Backups first. Deletion requires a fresh verified recovery backup.</p>}
 {data.job&&<p role="status">{data.job.phase??data.job.status}{data.job.error&&` · ${data.job.error}`}</p>}</>}
 </div><div className="modal-footer"><button className="btn btn-secondary" onClick={onClose}>Close</button><button className="btn btn-danger" disabled={!data||!data.backup_ready||!!pending} onClick={()=>setConfirming(true)}><Trash2 size={16}/>{data?.job?'Verify identity & resume':'Continue to identity verification'}</button></div>
 </PurchaseDialog>
 {confirming&&data&&<SensitiveActionDialog action="delete-business" target={target} name={data.business_name} description={`Permanently delete “${data.business_name}” and its business data. The server will require a verified recovery backup before removing any records.`} onClose={()=>setConfirming(false)} onConfirm={async(token,confirmation)=>{await remove.mutateAsync({target,request_id:data.job?.job_id??requestId,business_name:data.business_name,confirmation_token:token,confirmation});onClose();}}/>}
 </>;
}

export function BusinessDeletionJobs({onResume}:{onResume:(target:string)=>void}) {
 const jobs=useBusinessDeletions();
 return <>{jobs.error&&<p className="purchase-error" role="alert">{jobs.error.message}</p>}{!!jobs.data?.entries.length&&<section className="settings-card deletion-jobs"><header><h2>Business deletions</h2><p className="page-subtitle">Progress and recovery evidence remain available after a business disappears from the directory.</p></header>{jobs.data.entries.map((job:BusinessDeletionJob)=><article key={job.job_id}><div><strong>{job.business_name}</strong><p role="status">{job.phase??job.status}</p>{job.error&&<p className="purchase-error">{job.error}</p>}{job.backup_id&&<small>Recovery backup: {job.backup_id.slice(0,12)}</small>}</div>{['failed','interrupted','prepared','backed_up','data_removed'].includes(job.status)&&<button className="btn btn-secondary" onClick={()=>onResume(job.business_id)}>Review & resume</button>}{job.status==='completed'&&<span className="purchase-badge">Deleted</span>}</article>)}</section>}</>;
}
