import { createClient } from '@supabase/supabase-js';

const LOCAL_SUPABASE_URL = 'http://localhost:54321';
const SERVICE_ROLE_JWT_MARKER = 'InNlcnZpY2Vfcm9sZS';

const SUPABASE_URL = import.meta.env.VITE_SUPABASE_URL;
const SUPABASE_ANON_KEY = import.meta.env.VITE_SUPABASE_ANON_KEY;

function assertLocalSupabaseConfig(url?: string, anonKey?: string) {
  if (!url || !anonKey) {
    throw new Error('Local Supabase configuration is missing.');
  }

  if (url.includes('supabase.co') || anonKey.includes('supabase.co')) {
    throw new Error('Cloud Supabase configuration is not allowed in development.');
  }

  if (url !== LOCAL_SUPABASE_URL) {
    throw new Error(`Supabase must use ${LOCAL_SUPABASE_URL}. Received: ${url}`);
  }

  if (anonKey.startsWith('sb_secret_') || anonKey.includes(SERVICE_ROLE_JWT_MARKER)) {
    throw new Error('Supabase client must use the local anon/public key, not a service role or secret key.');
  }
}

assertLocalSupabaseConfig(SUPABASE_URL, SUPABASE_ANON_KEY);

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
