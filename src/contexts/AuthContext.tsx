import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from 'react';
import type { Session, User } from '@supabase/supabase-js';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
import type { AccessContext } from '../types/access';

export interface TenantProfile { tenant_id: string; business_name: string; full_name: string; email: string }
interface AuthContextValue {
  session: Session | null; user: User | null; profile: TenantProfile | null; access: AccessContext | null;
  isLoading: boolean; accessError: string | null; permissions: readonly string[];
  can: (permission: string) => boolean;
  signIn: (email: string, password: string) => Promise<{ error: Error | null }>;
  signOut: () => Promise<void>; refreshAccess: () => Promise<void>;
  switchBusiness: (tenantId: string | null) => Promise<void>;
}
const AuthContext = createContext<AuthContextValue | undefined>(undefined);
// eslint-disable-next-line react-refresh/only-export-components
export const useAuth = (): AuthContextValue => { const ctx = useContext(AuthContext); if (!ctx) throw new Error('useAuth must be used inside AuthProvider'); return ctx; };

export const AuthProvider = ({ children }: { children: ReactNode }) => {
  const cache = useQueryClient();
  const [session,setSession] = useState<Session|null>(null);
  const [hydrating,setHydrating] = useState(true);
  const [switching,setSwitching] = useState(false);
  const identity = useRef<string|undefined>(undefined);
  const scope = useRef<string>('');
  const user = session?.user ?? null;
  const query = useQuery<AccessContext>({
    queryKey:['access_context',user?.id], enabled:!!user,
    queryFn:async()=>{const {data,error}=await supabase.rpc('get_access_context');if(error)throw new Error(error.message);return data;},
    staleTime:0,refetchInterval:15_000,retry:1,
  });
  const access = user && !query.isError ? query.data ?? null : null;
  const permissions = access?.permissions ?? [];
  const profile = access?.tenant_id && !access.must_change_password && access.access_status==='active'
    ? {tenant_id:access.tenant_id,business_name:access.business_name??'',full_name:access.full_name,email:access.email} : null;
  useEffect(()=>{
    const fingerprint=access?JSON.stringify([user?.id,access.tenant_id,access.access_status,access.permissions,access.access_revision]):'';
    if(scope.current && scope.current!==fingerprint) {
      // Reset active observers as well as their data. Removing a query while its
      // page is mounted can strand the observer in its initial loading state.
      void cache.resetQueries({predicate:q=>q.queryKey[0]!=='access_context'});
    }
    scope.current=fingerprint;
  },[user?.id,access,cache]);
  useEffect(()=>{
    let mounted=true;
    const accept=(next:Session|null)=>{if(!mounted)return;if(identity.current!==next?.user.id){cache.clear();identity.current=next?.user.id;}setSession(next);setHydrating(false);};
    void supabase.auth.getSession().then(({data})=>accept(data.session));
    const {data}=supabase.auth.onAuthStateChange((_event,next)=>accept(next));
    return()=>{mounted=false;data.subscription.unsubscribe();};
  },[cache]);
  useEffect(()=>{
    const channel=typeof BroadcastChannel==='undefined'?null:new BroadcastChannel('lpg-access-context');
    if(channel)channel.onmessage=()=>{void cache.invalidateQueries({queryKey:['access_context']});};
    return()=>channel?.close();
  },[cache]);
  async function switchBusiness(tenantId:string|null) {
    setSwitching(true);
    try {
      await cache.cancelQueries();
      const {error}=await supabase.rpc('set_admin_workspace',{p_tenant_id:tenantId});if(error)throw new Error(error.message);
      cache.removeQueries({predicate:q=>q.queryKey[0]!=='access_context'});
      const result=await query.refetch();if(result.error)throw result.error;
      const channel=typeof BroadcastChannel==='undefined'?null:new BroadcastChannel('lpg-access-context');channel?.postMessage('changed');channel?.close();
    } finally {setSwitching(false);}
  }
  return <AuthContext.Provider value={{session,user,profile,access,permissions,can:permission=>permissions.includes(permission),
    isLoading:hydrating||switching||Boolean(user&&query.isPending),accessError:query.error?.message??null,
    signIn:async(email,password)=>{const {error}=await supabase.auth.signInWithPassword({email,password});return {error};},
    signOut:async()=>{await supabase.auth.signOut();cache.clear();},
    refreshAccess:async()=>{await query.refetch();},switchBusiness,
  }}>{children}</AuthContext.Provider>;
};
