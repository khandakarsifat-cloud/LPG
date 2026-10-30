import { useEffect } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useAuth } from '../contexts/AuthContext';
import { supabase } from '../lib/supabase';
import { applyTheme, getPreferredTheme, getStoredTheme, persistTheme, type AppTheme } from '../lib/theme';

export function useAppearance() {
 const { user, profile } = useAuth(); const cache = useQueryClient(); const key = ['appearance', user?.id];
 const query = useQuery<{ theme: AppTheme | null }>({ queryKey: key, enabled: !!profile,
  queryFn: async () => { const { data, error } = await supabase.rpc('get_my_preferences'); if (error) throw error; return data; } });
 const theme = query.data?.theme ?? getStoredTheme(user?.id) ?? getPreferredTheme();
 useEffect(() => { applyTheme(theme); if (user) persistTheme(theme, user.id); }, [theme, user]);
 const save = useMutation({ mutationFn: async (next: AppTheme) => { const { error } = await supabase.rpc('save_my_preferences', { p_theme: next }); if (error) throw new Error(error.message); return next; },
  onSuccess: next => { persistTheme(next, user?.id); applyTheme(next); cache.setQueryData(key, { theme: next }); } });
 return { theme, query, save };
}
