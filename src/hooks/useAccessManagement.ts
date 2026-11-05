import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import { useAuth } from '../contexts/AuthContext';
import type { AccountOperation, BusinessUser, BusinessUserDirectory, PermissionDefinition, PlatformBusiness, PlatformDashboard, StorageUsage, AccessActivity, UserWalletAccess } from '../types/access';

async function readRPC<T>(name:string,params:Record<string,unknown>={}):Promise<T> {
  const {data,error}=await supabase.rpc(name,params);if(error)throw new Error(error.message);return data;
}
async function accountRequest<T>(path:string,body:Record<string,unknown>):Promise<T> {
  const {data}=await supabase.auth.getSession();if(!data.session)throw new Error('Sign in again.');
  const response=await fetch(`${import.meta.env.VITE_SUPABASE_URL}/accounts/v1/${path}`,{method:'POST',headers:{'Content-Type':'application/json',Authorization:`Bearer ${data.session.access_token}`},body:JSON.stringify(body)});
  const result=await response.json();if(!response.ok)throw new Error(result.error??'Account operation failed');return result;
}
export function usePermissionCatalog() {return useQuery({queryKey:['access','catalog'],queryFn:()=>readRPC<PermissionDefinition[]>('get_permission_catalog')});}
export function useBusinessUsers(tenantId:string|undefined,page:number,search:string) {
  const {profile}=useAuth();return useQuery({queryKey:['access','users',tenantId??profile?.tenant_id,page,search],
    queryFn:()=>readRPC<BusinessUserDirectory>('get_business_users',{p_tenant_id:tenantId??null,p_offset:page*25,p_search:search})});
}
export function usePlatformBusinesses(page:number,search:string) {return useQuery({queryKey:['access','businesses',page,search],queryFn:()=>readRPC<{entries:PlatformBusiness[];total:number}>('get_platform_businesses',{p_offset:page*25,p_search:search})});}
export function usePlatformDashboard() {return useQuery({queryKey:['access','dashboard'],queryFn:()=>readRPC<PlatformDashboard>('get_platform_dashboard'),refetchInterval:60_000});}
export function usePlatformStorage() {return useQuery({queryKey:['access','storage'],queryFn:()=>readRPC<StorageUsage>('get_platform_storage'),staleTime:60_000,refetchOnWindowFocus:false});}
export function useAccessActivity(tenantId:string|undefined,page:number) {return useQuery({queryKey:['access','activity',tenantId,page],queryFn:()=>readRPC<{entries:AccessActivity[]}>('get_access_audit',{p_tenant_id:tenantId??null,p_offset:page*25})});}
export function useSaveBusinessUser(tenantId?:string) {
  const cache=useQueryClient();return useMutation({mutationFn:(params:{user:BusinessUser;name:string;role:string;active:boolean;permissions:string[]|null;walletAccess?:UserWalletAccess[]})=>readRPC<void>('manage_business_user',{
    p_user_id:params.user.user_id,p_name:params.name,p_role:params.role,p_active:params.active,p_expected_revision:params.user.revision,p_permissions:params.permissions,p_tenant_id:tenantId??null,p_wallet_access:params.walletAccess?.map(({wallet_id,can_use,can_balance,can_history})=>({wallet_id,can_use,can_balance,can_history}))??null}),
    onSuccess:()=>cache.invalidateQueries({queryKey:['access']})});
}
export function useBusinessWalletAccess(userId:string,tenantId?:string) {return useQuery({queryKey:['access','wallets',tenantId,userId],queryFn:()=>readRPC<UserWalletAccess[]>('get_business_wallet_access',{p_user_id:userId,p_tenant_id:tenantId??null})});}
export function useProvisionAccount() {
  const cache=useQueryClient();return useMutation({mutationFn:(params:{requestId:string;operation:AccountOperation;password:string})=>accountRequest<{user_id:string;tenant_id:string}>('provision',{request_id:params.requestId,operation:params.operation,password:params.password}),
    onSuccess:()=>cache.invalidateQueries({queryKey:['access']})});
}
export function useSetBusinessStatus() {
  const cache=useQueryClient();return useMutation({mutationFn:(params:{business:PlatformBusiness;status:string;confirmation:string;reason:string})=>readRPC<void>('set_business_status',{
    p_tenant_id:params.business.tenant_id,p_status:params.status,p_confirmation:params.confirmation,p_reason:params.reason}),onSuccess:()=>Promise.all([cache.invalidateQueries({queryKey:['access']}),cache.invalidateQueries({queryKey:['access_context']})])});
}
export function useChangePassword() {return useMutation({mutationFn:(params:{currentPassword:string;password:string})=>accountRequest('password',{current_password:params.currentPassword,password:params.password})});}
