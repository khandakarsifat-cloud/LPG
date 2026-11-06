-- Expose transport cash payments and rebates only after their actual recognition.
create or replace function public.get_purchase_transport(p_transit_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['logistics:view','logistics:manage']);r jsonb;
begin
 select jsonb_build_object('paid',s.amount,'refunded',s.refunded_amount,
 'remaining',s.amount-s.refunded_amount,'can_refund',p.status='cancelled' and s.wallet_id is not null,
 'wallet_name',case when app_private.wallet_allowed(s.wallet_id,'history') then w.name end)
 into r from public.transits tr join public.purchases p using(tenant_id,purchase_id)
 join app_private.internal_transport_settlements s using(tenant_id,purchase_id)
 left join public.wallets w on w.tenant_id=s.tenant_id and w.wallet_id=s.wallet_id
 where tr.tenant_id=t and tr.transit_id=p_transit_id and s.wallet_id is not null;
 return r;
end $$;

CREATE OR REPLACE FUNCTION public.get_purchase_settlement(p_purchase_id uuid, p_offset integer DEFAULT 0, p_limit integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_any_permission(array['purchases:view','purchases:manage']); p public.purchases; result jsonb;
begin
 if p_offset is null or p_limit is null or p_offset<0 or p_limit not between 1 and 100 then raise exception 'Invalid payment page'; end if;
 select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id;
 if not found then raise exception 'Purchase not found'; end if;
 select jsonb_build_object('total',p.payable_amount,'rebate_amount',p.rebate_amount,'rebate_applied',case when p.status='received' or not p.recognize_on_receipt and p.status='in_transit' then p.rebate_amount else 0 end,'company_credit',coalesce((select sum(e.income_delta-e.applied_delta) from app_private.purchase_rebate_events e join app_private.purchase_rebate_accounts a using(tenant_id,account_id) where e.tenant_id=t and a.company_key=app_private.rebate_company_key(p)),0),'can_rebate',not(p.status='received' and p.payment_status='paid') and p.status<>'cancelled' and app_private.has_permission('purchases:rebates') and app_private.has_permission('purchases:manage') and app_private.has_permission('purchases:pay'),'allocated_transport',p.transport_cost,'paid',p.paid_amount,'due',case when p.status='cancelled' then 0 else greatest(0,p.payable_amount-p.rebate_amount-p.paid_amount) end,
 'refund_due',p.refund_due,'refunded',p.refunded_amount,'financial_closed_at',p.financial_closed_at,'can_cancel',public.can_cancel_purchases(),
 'financial_locked',p.paid_amount>0 or p.status='received' or p.payment_status='paid' or exists(select 1 from public.wallet_transactions where tenant_id=t and reference_id=p_purchase_id and amount<0 and type in ('purchase_expense','purchase_company_payment','purchase_logistics_payment','purchase_payment_company','purchase_payment_labour','purchase_payment_transport','purchase_payment')),
 'obligations',coalesce((select jsonb_agg(to_jsonb(o)||jsonb_build_object('refunded',coalesce(q.amount,0),'remaining',o.amount-coalesce(q.amount,0)) order by o.component)
 from public.purchase_refund_obligations o left join lateral(select sum(amount) amount from public.purchase_payments where tenant_id=t and obligation_id=o.obligation_id) q on true where o.tenant_id=t and o.purchase_id=p_purchase_id),'[]'),
 'payment_count',(select count(*) from public.wallet_transactions where tenant_id=t and reference_id=p_purchase_id),
 'payments',coalesce((select jsonb_agg(to_jsonb(e) order by e.entry_no) from (select x.transaction_id,x.purchase_payment_id,x.wallet_name_snapshot wallet_name,x.wallet_method_snapshot method,x.amount,x.type,x.created_at,x.entry_no,x.operation_id,x.description,x.counterparty_wallet_id,pp.reference,pp.component,pp.obligation_id,up.full_name actor
  from public.wallet_transactions x left join public.purchase_payments pp on pp.tenant_id=t and pp.payment_id=x.purchase_payment_id
  left join app_private.tenant_actors up on up.tenant_id=t and up.user_id=x.created_by
  where x.tenant_id=t and x.reference_id=p_purchase_id order by x.entry_no limit p_limit offset p_offset) e),'[]')) into result;
 return result;
end $function$
;
