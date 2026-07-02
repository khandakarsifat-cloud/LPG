import { createContext, useContext, useEffect, useState, type ReactNode } from 'react';
import type { Session, User } from '@supabase/supabase-js';
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

  /** Sign in with email + password */
  signIn: (email: string, password: string) => Promise<{ error: Error | null }>;

  /** Create a new business and its owner account atomically */
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
  const [session, setSession] = useState<Session | null>(null);
  const [user, setUser] = useState<User | null>(null);
  const [profile, setProfile] = useState<TenantProfile | null>(null);
  const [isLoading, setIsLoading] = useState(true);

  /** Fetch the tenant profile for the currently authenticated user */
  const fetchProfile = async (currentUser: User) => {
    const { data, error } = await supabase
      .from('user_profiles')
      .select('tenant_id, email, tenants(business_name)')
      .eq('user_id', currentUser.id)
      .single();

    if (error || !data) {
      setProfile(null);
      return;
    }

    const tenantData = data.tenants as unknown as { business_name: string } | null;

    setProfile({
      tenant_id: data.tenant_id,
      business_name: tenantData?.business_name ?? '',
      full_name: (currentUser.user_metadata?.full_name as string) ?? '',
      email: data.email,
    });
  };

  // Bootstrap: listen to Supabase auth state changes
  useEffect(() => {
    supabase.auth.getSession().then(({ data: { session: s } }) => {
      setSession(s);
      setUser(s?.user ?? null);
      if (s?.user) fetchProfile(s.user).finally(() => setIsLoading(false));
      else setIsLoading(false);
    });

    const { data: listener } = supabase.auth.onAuthStateChange((_event, s) => {
      setSession(s);
      setUser(s?.user ?? null);
      if (s?.user) fetchProfile(s.user);
      else setProfile(null);
    });

    return () => listener.subscription.unsubscribe();
  }, []);

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
    await supabase.auth.signInWithPassword({ email, password });

    // Step 3: Call the atomic RPC to create the tenant, role, and profile
    const { error: rpcError } = await supabase.rpc('setup_business', {
      p_business_name: businessName,
      p_owner_name: ownerName,
    });

    if (rpcError) {
      // Cleanup: sign out and remove the orphaned auth user
      await supabase.auth.signOut();
      return { error: rpcError as unknown as Error };
    }

    // Refresh the profile with the newly created tenant data
    const currentUser = signUpData.user;
    await fetchProfile(currentUser);

    return { error: null };
  };

  const signOut = async () => {
    await supabase.auth.signOut();
    setProfile(null);
  };

  return (
    <AuthContext.Provider
      value={{ session, user, profile, isLoading, signIn, createBusiness, signOut }}
    >
      {children}
    </AuthContext.Provider>
  );
};
