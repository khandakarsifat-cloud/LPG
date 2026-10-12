import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from 'react';
import type { Session, User } from '@supabase/supabase-js';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';

// ─── Types ────────────────────────────────────────────────────────────────────

export interface TenantProfile {
  tenant_id: string;
  business_name: string;
  full_name: string;
  email: string;
}

interface AuthContextValue {
  session: Session | null;
  user: User | null;
  profile: TenantProfile | null;
  isLoading: boolean;
  permissions: readonly string[];
  can: (permission: string) => boolean;

  /** Sign in with email + password */
  signIn: (email: string, password: string) => Promise<{ error: Error | null }>;

  /** Create an Auth account, then atomically set up its business membership */
  createBusiness: (params: {
    businessName: string;
    ownerName: string;
    email: string;
    password: string;
  }) => Promise<{ error: Error | null }>;

  /** Sign the current user out */
  signOut: () => Promise<void>;
}

// ─── Context ──────────────────────────────────────────────────────────────────

const AuthContext = createContext<AuthContextValue | undefined>(undefined);

// eslint-disable-next-line react-refresh/only-export-components
export const useAuth = (): AuthContextValue => {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth must be used inside AuthProvider');
  return ctx;
};

// ─── Provider ─────────────────────────────────────────────────────────────────

export const AuthProvider = ({ children }: { children: ReactNode }) => {
  const queryClient = useQueryClient();
  const [session, setSession] = useState<Session | null>(null);
  const user = session?.user ?? null;
  const userId = user?.id;
  const identity = useRef<string | undefined>(undefined);
  const [isLoading, setIsLoading] = useState(true);
  const profileQuery = useQuery<TenantProfile | null>({
    queryKey: ['tenant_profile', userId],
    enabled: Boolean(userId),
    queryFn: async () => {
      if (!userId) return null;
      const { data, error } = await supabase.from('user_profiles')
        .select('tenant_id, email, full_name, tenants(business_name)')
        .eq('user_id', userId).maybeSingle();
      if (error) throw error;
      if (!data) return null;
      const tenant = data.tenants as unknown as { business_name: string } | null;
      return {
        tenant_id: data.tenant_id, email: data.email,
        full_name: data.full_name ?? '', business_name: tenant?.business_name ?? '',
      };
    },
    refetchInterval: 30_000,
    staleTime: 0,
  });
  const profile = user && !profileQuery.isError ? profileQuery.data ?? null : null;
  const permissionQuery = useQuery<string[]>({
    queryKey: ['authorization', user?.id, profile?.tenant_id],
    enabled: Boolean(user && profile),
    queryFn: async () => {
      const { data, error } = await supabase.rpc('get_my_permissions');
      if (error) throw error;
      return data ?? [];
    },
    refetchInterval: 30_000,
    staleTime: 0,
  });
  const permissions = permissionQuery.isError ? [] : permissionQuery.data ?? [];

  // Bootstrap: listen to Supabase auth state changes
  useEffect(() => {
    let mounted = true;
    const acceptSession = (s: Session | null) => {
      if (!mounted) return;
      if (identity.current !== s?.user.id) {
        queryClient.clear();
        identity.current = s?.user.id;
      }
      setSession(s);
      setIsLoading(false);
    };
    supabase.auth.getSession().then(({ data: { session: s } }) => acceptSession(s));

    const { data: listener } = supabase.auth.onAuthStateChange((_event, s) => {
      acceptSession(s);
    });

    return () => {
      mounted = false;
      listener.subscription.unsubscribe();
    };
  }, [queryClient]);

  // ─── Auth Actions ───────────────────────────────────────────────────────────

  const signIn = async (email: string, password: string) => {
    const { error } = await supabase.auth.signInWithPassword({ email, password });
    return { error: error as Error | null };
  };

  const createBusiness = async ({
    businessName,
    ownerName,
    email,
    password,
  }: {
    businessName: string;
    ownerName: string;
    email: string;
    password: string;
  }) => {
    // Step 1: Create the Supabase Auth user
    const { data: signUpData, error: signUpError } = await supabase.auth.signUp({
      email,
      password,
      options: {
        data: { full_name: ownerName },
      },
    });

    if (signUpError || !signUpData.user) {
      return { error: signUpError as Error };
    }

    // Step 2: Sign in immediately (needed if email confirmation is disabled)
    const { error: signInError } = await supabase.auth.signInWithPassword({ email, password });
    if (signInError) return { error: signInError };

    // Step 3: Call the atomic RPC to create the tenant, role, and profile
    const { error: rpcError } = await supabase.rpc('setup_business', {
      p_business_name: businessName,
      p_owner_name: ownerName,
    });

    if (rpcError) {
      // Auth signup is separate from database setup; sign out on setup failure.
      await supabase.auth.signOut();
      return { error: rpcError as unknown as Error };
    }

    // Refresh the profile with the newly created tenant data
    await queryClient.invalidateQueries({ queryKey: ['tenant_profile'] });
    await queryClient.invalidateQueries({ queryKey: ['authorization'] });

    return { error: null };
  };

  const signOut = async () => {
    await supabase.auth.signOut();
    queryClient.clear();
  };

  return (
    <AuthContext.Provider
      value={{
        session, user, profile,
        isLoading: isLoading || Boolean(user && profileQuery.isPending) ||
          Boolean(profile && permissionQuery.isPending),
        permissions, can: permission => permissions.includes(permission),
        signIn, createBusiness, signOut,
      }}
    >
      {children}
    </AuthContext.Provider>
  );
};
