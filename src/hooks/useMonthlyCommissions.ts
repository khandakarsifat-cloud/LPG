import type { MonthlyCommission } from '../types/inventory';
import { useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { useAuth } from '../contexts/AuthContext';
import { supabase } from '../lib/supabase';
import { finishRequest, hasPendingRequest, isDefiniteRejection, prepareRequest } from '../lib/pendingRequest';

interface CommissionMonth { current: MonthlyCommission | null; quantity: number; quantities: { package: number; refill: number }; earned: number; total: number; entries: (MonthlyCommission & {history_id: string; actor: string; reason: string})[] }
export function useMonthlyCommissions(itemId: string, month: string, page: number) {
  return useQuery<CommissionMonth>({queryKey:['inventory','monthly-commissions',itemId,month,page],queryFn:async({signal})=>{
    const {data,error}=await supabase.rpc('get_monthly_commissions',{p_item_id:itemId,p_month:`${month}-01`,p_offset:page*10}).abortSignal(signal);
    if(error) throw new Error(error.message); return data;
  }});
}
export function useSetMonthlyCommission() {
  const {profile,user}=useAuth(); const qc=useQueryClient(); const key=`lpg-monthly-commission:${profile?.tenant_id}:${user?.id}`;
  const [pending,setPending]=useState(()=>hasPendingRequest(key));
  const mutation=useMutation({mutationFn:async(payload:{item_id:string;month:string;package_rate:number;refill_rate:number;reason?:string;expected_revision:number}|undefined)=>{
    if(!profile||!user) throw new Error('Sign in before saving monthly commissions.');
    const request=prepareRequest(key,payload);setPending(true);
    const {error}=await supabase.rpc('set_monthly_commission',{p_payload:request.body,p_request_id:request.id});
    if(!error||isDefiniteRejection(error.code)){finishRequest(key,request.id);setPending(false);}
    if(error) throw new Error(error.message);
  },onSuccess:async()=>{await Promise.all([['inventory'],['finance'],['purchases'],['dashboard']].map(queryKey=>qc.invalidateQueries({queryKey})));}});
  return {...mutation,hasPending:pending};
}

export function useCorrectCommissionDeduction() {
  const {profile,user}=useAuth();const qc=useQueryClient();const key=`lpg-commission-deduction:${profile?.tenant_id}:${user?.id}`;
  const [pending,setPending]=useState(()=>hasPendingRequest(key));
  const mutation=useMutation({mutationFn:async(payload:{purchase_id:string;month:string;amount:number;reason:string;expected_revision:number}|undefined)=>{
    if(!profile||!user) throw new Error('Sign in before correcting commission deductions.');
    const request=prepareRequest(key,payload);setPending(true);
    const {error}=await supabase.rpc('correct_commission_deduction',{p_payload:request.body,p_request_id:request.id});
    if(!error||isDefiniteRejection(error.code)){finishRequest(key,request.id);setPending(false);}
    if(error) throw new Error(error.message);
  },onSuccess:async()=>{await Promise.all([['inventory'],['finance'],['purchases'],['dashboard']].map(queryKey=>qc.invalidateQueries({queryKey})));}});
  return {...mutation,hasPending:pending};
}
