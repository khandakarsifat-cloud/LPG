import {useMutation,useQuery,useQueryClient} from '@tanstack/react-query';
import {useEffect} from 'react';
import {backupRequest} from './useBackups';

export interface BusinessDeletionJob {job_id:string;business_id:string;business_name:string;actor_id:string;status:string;phase?:string;backup_id?:string;created_at:string;completed_at?:string;error?:string}
export interface BusinessDeletionPreview {business_id:string;business_name:string;tables:Record<string,number>;files:number;accounts:number;preserved_accounts:number;backup_ready:boolean;job:BusinessDeletionJob|null}
export function useBusinessDeletionPreview(target:string) {return useQuery({queryKey:['access','deletion-preview',target],queryFn:()=>backupRequest<BusinessDeletionPreview>('business-deletion/preview',{target})});}
export function useBusinessDeletions() {
 const cache=useQueryClient();const query=useQuery({queryKey:['access','deletions'],queryFn:()=>backupRequest<{entries:BusinessDeletionJob[]}>('business-deletion/jobs'),refetchInterval:q=>q.state.data?.entries.some(j=>['running','queued'].includes(j.status))?2500:30000});
 const completed=query.data?.entries.filter(j=>j.status==='completed').map(j=>j.job_id).join(',');
 useEffect(()=>{if(completed)void Promise.all([cache.invalidateQueries({queryKey:['access','businesses']}),cache.invalidateQueries({queryKey:['access','dashboard']}),cache.invalidateQueries({queryKey:['access','storage']})]);},[cache,completed]);
 return query;
}
export function useDeleteBusiness() {const cache=useQueryClient();return useMutation({mutationFn:(body:{target:string;request_id:string;business_name:string;confirmation_token:string;confirmation:string})=>backupRequest<BusinessDeletionJob>('business-deletion/start',body),onSuccess:()=>cache.invalidateQueries({queryKey:['access']})});}
