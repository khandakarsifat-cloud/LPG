import {useQuery} from '@tanstack/react-query';
import {supabase} from '../lib/supabase';
import type {ProductPerformanceReport,FifoProduct,FifoStockReport} from '../types/productPerformance';
export function useProductPerformance(from:string,to:string,page:number) {
 return useQuery<ProductPerformanceReport>({queryKey:['finance','product-performance',from,to,page],enabled:!from||!to||from<=to,refetchInterval:30_000,queryFn:async({signal})=>{const {data,error}=await supabase.rpc('get_lpg_performance',{p_from:from||null,p_to:to||null,p_offset:page*25}).abortSignal(signal);if(error)throw error;return data;}});
}
export function useFifoProducts(search:string,page:number) {
 return useQuery<{total:number;entries:FifoProduct[]}>({queryKey:['finance','fifo-products',search,page],queryFn:async({signal})=>{const {data,error}=await supabase.rpc('get_lpg_fifo_products',{p_search:search,p_offset:page*25}).abortSignal(signal);if(error)throw error;return data;}});
}
export function useFifoStock(productId:string,tier:string,page:number) {
 return useQuery<FifoStockReport>({queryKey:['finance','fifo-stock',productId,tier,page],enabled:!!productId,refetchInterval:30_000,queryFn:async({signal})=>{const {data,error}=await supabase.rpc('get_lpg_fifo_stock',{p_item_id:productId,p_tier:tier,p_offset:page*25}).abortSignal(signal);if(error)throw error;return data;}});
}
