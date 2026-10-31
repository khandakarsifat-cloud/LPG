import { useQuery } from '@tanstack/react-query';
import { supabase } from '../lib/supabase';
export function useAnalysisBusinesses() {
  return useQuery<{ tenant_id: string; business_name: string }[]>({
    queryKey: ['finance', 'analysis-businesses'],
    refetchInterval: 30_000,
    queryFn: async ({ signal }) => {
      const { data, error } = await supabase
        .rpc('get_analysis_businesses')
        .abortSignal(signal);
      if (error) throw error;
      return data;
    },
  });
}
