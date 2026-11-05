-- Remove the inspected empty pre-core archive; current operations retain their own immutable sources.
do $$begin
 if exists(select 1 from public.financial_source_archive) then
  raise exception 'Inspect and preserve nonempty financial archive before removing this retired development representation';
 end if;
end$$;
create or replace function app_private.transit_operating_paid(t uuid,id uuid)
returns numeric language sql stable set search_path='' as $$
 select coalesce(sum(case when kind='expense' then amount else -amount end),0)
 from public.operating_payments where tenant_id=t and transit_id=id and kind in ('expense','expense_return');
$$;
CREATE OR REPLACE FUNCTION public.get_purchase_activity(p_purchase_id uuid)
 RETURNS SETOF jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid := app_private.require_any_permission(array['purchases:view','purchases:manage']);
begin
  return query
  with activities as materialized (
    select a.*, coalesce(nullif(u.full_name,''),u.email,'Historical user') actor_name
    from public.purchase_activity a
    left join app_private.tenant_actors u on u.tenant_id=a.tenant_id and u.user_id=a.created_by
    where a.tenant_id=t and a.purchase_id=p_purchase_id
  ), ledger as materialized (
    select x.transaction_id, x.purchase_payment_id, x.wallet_name_snapshot wallet_name,
      x.wallet_method_snapshot method, x.amount, x.type, x.created_at, x.entry_no,
      x.operation_id, x.description, x.counterparty_wallet_id,
      pp.reference, pp.component, pp.obligation_id, u.full_name actor,
      linked.activity_id
    from public.wallet_transactions x
    left join public.purchase_payments pp on pp.tenant_id=t and pp.payment_id=x.purchase_payment_id
    left join app_private.tenant_actors u on u.tenant_id=t and u.user_id=x.created_by
    left join lateral (
      select a.activity_id from activities a
      where (x.operation_id is not null and a.details->>'operation_id'=x.operation_id::text)
         or (x.purchase_payment_id is not null and exists (
           select 1 from jsonb_array_elements(case when jsonb_typeof(a.details->'payments')='array'
             then a.details->'payments' else '[]'::jsonb end) payment
           where payment->>'payment_id'=x.purchase_payment_id::text))
      order by a.created_at,a.activity_id limit 1
    ) linked on true
    where x.tenant_id=t and x.reference_id=p_purchase_id
  ), events as (
    select a.created_at, a.activity_id id, 0::bigint entry_no,
      to_jsonb(a)||jsonb_build_object('wallet_entries',coalesce((
        select jsonb_agg(to_jsonb(l)-'activity_id' order by l.entry_no)
        from ledger l where l.activity_id=a.activity_id),'[]'::jsonb)) body
    from activities a
    union all
    select l.created_at,l.transaction_id,l.entry_no,
      jsonb_build_object('activity_id',l.transaction_id,'action','wallet_entry',
        'actor_name',coalesce(l.actor,'Historical user'),'created_at',l.created_at,
        'details','{}'::jsonb,'wallet_entries',jsonb_build_array(to_jsonb(l)-'activity_id'))
    from ledger l where l.activity_id is null
  )
  select e.body from events e order by e.created_at,e.entry_no,e.id;
end $function$;

CREATE OR REPLACE FUNCTION public.initiate_purchase_cancellation(p_purchase_id uuid, p_revision integer, p_confirmation text, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_permission('purchases:manage'); p public.purchases; prior public.finance_requests; payload jsonb; result jsonb;
 r record; obligation_total numeric:=0; sources jsonb;
begin perform app_private.require_permission('purchases:cancel');
 if not public.can_cancel_purchases() then raise exception 'Only the OWNER can cancel purchases' using errcode='42501'; end if;
 if p_confirmation is distinct from 'CANCEL' then raise exception 'Type exactly CANCEL to confirm cancellation'; end if;
 if p_request_id is null then raise exception 'Cancellation request ID is required'; end if;
 payload:=jsonb_build_object('action','purchase_cancel','purchase',p_purchase_id,'revision',p_revision,'confirmation',p_confirmation,'actor',auth.uid());
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from payload then raise exception 'Request ID already used with different details'; end if; return prior.result; end if;
 select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id for update;
 if not found then raise exception 'Purchase not found'; end if;
 if p.status='received' and p.business_category='lpg' then raise exception 'Received purchases can never be cancelled'; end if;
 if p.status='cancelled' then raise exception 'Purchase is already cancelled'; end if;
 if p_revision is distinct from p.revision then raise exception 'Purchase changed. Reload before cancellation.' using errcode='P0001'; end if;
 perform 1 from public.vehicles where tenant_id=t and vehicle_id=p.vehicle_id for update;
 perform 1 from public.transits where tenant_id=t and purchase_id=p_purchase_id order by transit_id for update;
 insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details) values(t,p_purchase_id,'cancellation_confirmed',auth.uid(),jsonb_build_object('previous_status',p.status,'confirmation','CANCEL','operation_id',p_request_id,'before',to_jsonb(p)));
 if p.business_category='stove' and p.status='received' then
  for r in select pi.item_id,sum(pi.quantity) qty from public.purchase_items pi where pi.tenant_id=t and pi.purchase_id=p_purchase_id group by pi.item_id order by pi.item_id loop
   perform 1 from public.items where tenant_id=t and item_id=r.item_id for update;
   if (select filled_quantity from public.items where tenant_id=t and item_id=r.item_id)<r.qty then raise exception 'Purchased stock has been consumed; return stock before cancellation';end if;
   insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,filled_quantity_change,notes,created_by)
   values(t,r.item_id,'purchase_adjustment','stove_purchase_cancellation',p_purchase_id,-r.qty,'Stove purchase cancelled',auth.uid());
  end loop;

 end if;
 -- LPG retains its pre-receipt cancellation boundary.
 for r in select m.item_id,sum(m.empty_quantity_change) empties from public.inventory_movements m where m.tenant_id=t and
 m.reference_id=p_purchase_id and m.reference_type='purchase_dispatch' group by m.item_id order by m.item_id loop
  perform 1 from public.items where tenant_id=t and item_id=r.item_id for update;
  if r.empties<>0 then insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,empty_quantity_change,notes,created_by)
   values(t,r.item_id,'purchase_adjustment','purchase_cancellation',p_purchase_id,-r.empties,'Cancelled purchase: dispatched empties returned',auth.uid()); end if;
 end loop;
 -- Refund only evidence of actual purchasing-business debits. Historical settled
 -- headers with no ledger attribution never create fictional money to refund.
 for r in select component,greatest(0,-sum(amount)) amount,jsonb_agg(evidence order by created_at,transaction_id) sources from (
  select x.amount,x.created_at,x.transaction_id,'purchase' component,
   jsonb_build_object('transaction_id',x.transaction_id,'payment_id',x.purchase_payment_id,'wallet_id',x.wallet_id,'wallet_name',x.wallet_name_snapshot,'method',x.wallet_method_snapshot,'amount',x.amount,'description',x.description,'created_at',x.created_at) evidence
  from public.wallet_transactions x join public.wallets w using(tenant_id,wallet_id) where x.tenant_id=t and x.reference_id=p_purchase_id 
   and x.type='purchase_payment'
 ) q group by component loop
  if r.amount>0 then
   insert into public.purchase_refund_obligations(tenant_id,purchase_id,component,amount,sources,created_by)
    values(t,p_purchase_id,r.component,r.amount,r.sources,auth.uid());
   obligation_total:=obligation_total+r.amount;

  end if;
 end loop;
 if p.status<>'received' then perform app_private.settle_internal_transport(t,p_purchase_id,(now() at time zone 'Asia/Dhaka')::date,true);end if; if p.status<>'received' then update public.transits set status='cancelled',revision=revision+1,updated_at=now() where tenant_id=t and purchase_id=p_purchase_id;end if;
 update public.purchases set status='cancelled',cancelled_at=now(),refund_due=obligation_total,financial_closed_at=case when obligation_total=0 then now() end,
  updated_at=now(),revision=revision+1 where tenant_id=t and purchase_id=p_purchase_id;
 if not exists(select 1 from public.transits where tenant_id=t and vehicle_id=p.vehicle_id and status='active')
  and not exists(select 1 from public.purchases where tenant_id=t and vehicle_id=p.vehicle_id and status='in_transit') then
  update public.vehicles set status='idle',updated_at=now() where tenant_id=t and vehicle_id=p.vehicle_id;
 end if;
 result:=jsonb_build_object('purchase_id',p_purchase_id,'refund_due',obligation_total,'financially_closed',obligation_total=0);
 insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details) values(t,p_purchase_id,'cancellation_initiated',auth.uid(),result||jsonb_build_object('notes','Dispatched empties returned; truck released; transit cancelled. Incurred operating costs preserved. Refunds require separate settlement.'));
 if obligation_total=0 then insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details) values(t,p_purchase_id,'financially_closed',auth.uid(),result); end if;
 insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,payload,result,auth.uid());
 return result;
end $function$;

drop function public.get_financial_source_archive(uuid,integer,integer);
drop table public.financial_source_archive;
drop function app_private.rebuild_fifo(uuid,uuid);
alter table public.purchase_payments add constraint purchase_payments_component_check check(component='purchase');
alter table public.purchase_refund_obligations drop constraint purchase_refund_obligations_component_check;
alter table public.purchase_refund_obligations add constraint purchase_refund_obligations_component_check check(component='purchase');

