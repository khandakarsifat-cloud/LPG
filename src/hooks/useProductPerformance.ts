import {useQuery} from '@tanstack/react-query';
import {supabase} from '../lib/supabase';
import type {ProductPerformanceReport,FifoProduct,FifoStockReport} from '../types/productPerformance';
export function useProductPerformance(from:string,to:string,page:number,business:'lpg'|'stove'='lpg') {
 return useQuery<ProductPerformanceReport>({queryKey:['finance','product-performance',business,from,to,page],enabled:!from||!to||from<=to,refetchInterval:30_000,queryFn:async({signal})=>{const {data,error}=await supabase.rpc('get_product_performance',{p_business:business,p_from:from||null,p_to:to||null,p_offset:page*25}).abortSignal(signal);if(error)throw error;return data;}});
}
export function useFifoProducts(search:string,page:number,business:'lpg'|'stove'='lpg') {
 return useQuery<{total:number;entries:FifoProduct[]}>({queryKey:['finance','fifo-products',business,search,page],queryFn:async({signal})=>{const {data,error}=await supabase.rpc('get_fifo_products',{p_business:business,p_search:search,p_offset:page*25}).abortSignal(signal);if(error)throw error;return data;}});
}
export function useFifoStock(productId:string,tier:string,page:number,state:'all'|'filled'|'empty'='all') {
 return useQuery<FifoStockReport>({queryKey:['finance','fifo-stock',productId,tier,state,page],enabled:!!productId,refetchInterval:30_000,queryFn:async({signal})=>{const {data,error}=await supabase.rpc('get_fifo_stock',{p_item_id:productId,p_tier:tier,p_state:state,p_offset:page*25}).abortSignal(signal);if(error)throw error;return data;}});
}
