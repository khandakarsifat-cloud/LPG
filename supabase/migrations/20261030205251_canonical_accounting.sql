-- Canonical incurred-cost accounting. Historical evidence is archived before
-- obsolete virtual-account relationships are removed. Real balances change only
-- through compensating ledger entries supported by original funding evidence.
alter table public.purchases add column payable_amount numeric(14,2)
 generated always as (company_payable+labour_cost) stored;
create table public.financial_source_archive(
 tenant_id uuid not null references public.tenants(tenant_id),archive_id uuid not null default gen_random_uuid(),
 source_table text not null,source_id uuid not null,reference_id uuid,record jsonb not null,
 reason text not null,archived_at timestamptz not null default clock_timestamp(),
 primary key(tenant_id,archive_id),unique(tenant_id,source_table,source_id)
);
create index financial_archive_reference on public.financial_source_archive(tenant_id,reference_id);
alter table public.financial_source_archive enable row level security;
revoke all on public.financial_source_archive from public,anon,authenticated;
create trigger immutable_financial_archive before update or delete on public.financial_source_archive
 for each row execute function app_private.immutable_finance_record();
-- Preserve the full source rows, including original IDs, timestamps and balances.
insert into public.financial_source_archive(tenant_id,source_table,source_id,reference_id,record,reason)
select tenant_id,'wallets',wallet_id,wallet_id,to_jsonb(w),'Retired virtual Logistics account' from public.wallets w where type='logistics';
insert into public.financial_source_archive(tenant_id,source_table,source_id,reference_id,record,reason)
select x.tenant_id,'wallet_transactions',x.transaction_id,x.reference_id,to_jsonb(x),'Virtual Logistics evidence; not a real cash account'
from public.wallet_transactions x join public.wallets w using(tenant_id,wallet_id) where w.type='logistics';
-- Capture relationships that normalization will change, without changing amounts.
insert into public.financial_source_archive(tenant_id,source_table,source_id,reference_id,record,reason)
select e.tenant_id,'employee_payment_entries',e.entry_id,e.payment_id,to_jsonb(e),'Original virtual wallet attribution; real source account unknown'
from public.employee_payment_entries e join public.wallets w using(tenant_id,wallet_id) where w.type='logistics';
insert into public.financial_source_archive(tenant_id,source_table,source_id,reference_id,record,reason)
select p.tenant_id,'purchases',p.purchase_id,p.purchase_id,to_jsonb(p),'Purchase payable normalized to external obligations' from public.purchases p;
-- Undo only net automatic real-account funding which has not already been refunded.
-- Nonautomatic transfers/adjustments remain actual cash evidence.
insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description,operation_id)
select x.tenant_id,x.wallet_id,-sum(x.amount),'accounting_normalization',x.reference_id,
 'Reverse automatic virtual transport funding; original ledger evidence retained',gen_random_uuid()
from public.wallet_transactions x join public.wallets w using(tenant_id,wallet_id)
where w.type<>'logistics' and x.type in ('purchase_transport_funding','purchase_transport_refund')
group by x.tenant_id,x.wallet_id,x.reference_id having sum(x.amount)<>0;
insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description,operation_id)
select x.tenant_id,x.wallet_id,-least(x.amount,greatest(0,o.logistics_amount-coalesce((select sum(older.amount) from public.purchase_payments older where older.tenant_id=pp.tenant_id and older.obligation_id=pp.obligation_id and (older.created_at,older.payment_id)<(pp.created_at,pp.payment_id)),0))),
 'accounting_normalization',x.reference_id,'Reverse historical virtual-funding refund; original evidence retained',gen_random_uuid()
from public.wallet_transactions x join public.purchase_payments pp on pp.tenant_id=x.tenant_id and pp.payment_id=x.purchase_payment_id
join public.purchase_refund_obligations o on o.tenant_id=pp.tenant_id and o.obligation_id=pp.obligation_id
where x.type='purchase_refund' and o.logistics_amount>0 and x.amount>0
and least(x.amount,greatest(0,o.logistics_amount-coalesce((select sum(older.amount) from public.purchase_payments older where older.tenant_id=pp.tenant_id and older.obligation_id=pp.obligation_id and (older.created_at,older.payment_id)<(pp.created_at,pp.payment_id)),0)))>0;
-- A virtual wallet is not sufficient evidence to invent a real refund destination.
alter table public.employee_payment_entries alter column wallet_id drop not null;
alter table public.employee_payment_entries disable trigger immutable_employee_record;
update public.employee_payment_entries e set wallet_id=null
from public.wallets w where w.tenant_id=e.tenant_id and w.wallet_id=e.wallet_id and w.type='logistics';
alter table public.employee_payment_entries enable trigger immutable_employee_record;
-- Other historical virtual attributions retain their immutable labels and archive.
do $$ declare r record;begin
 for r in select * from (values ('purchase_payments','payment_id','purchase_id','immutable_purchase_payment'),
 ('sale_payments','payment_id','sale_id','immutable_sale_payment'),('spendings','spending_id','spending_id','immutable_spending')) v(tbl,id,ref,trg) loop
  execute format('insert into public.financial_source_archive(tenant_id,source_table,source_id,reference_id,record,reason) select e.tenant_id,%L,e.%I,e.%I,to_jsonb(e),%L from public.%I e join public.wallets w using(tenant_id,wallet_id) where w.type=''logistics''',r.tbl,r.id,r.ref,'Original virtual wallet attribution; actual cash account unknown',r.tbl);
  if exists(select 1 from information_schema.triggers where event_object_schema='public' and event_object_table=r.tbl and trigger_name=r.trg) then execute format('alter table public.%I disable trigger %I',r.tbl,r.trg);end if;
  execute format('alter table public.%I alter column wallet_id drop not null',r.tbl);
  execute format('update public.%I e set wallet_id=null from public.wallets w where e.tenant_id=w.tenant_id and e.wallet_id=w.wallet_id and w.type=''logistics''',r.tbl);
  if exists(select 1 from information_schema.triggers where event_object_schema='public' and event_object_table=r.tbl and trigger_name=r.trg) then execute format('alter table public.%I enable trigger %I',r.tbl,r.trg);end if;
 end loop;
end $$;
alter table public.wallet_transactions disable trigger immutable_wallet_entry;
update public.wallet_transactions x set counterparty_wallet_id=null from public.wallets w
where x.tenant_id=w.tenant_id and x.counterparty_wallet_id=w.wallet_id and w.type='logistics';
delete from public.wallet_transactions x using public.wallets w where x.tenant_id=w.tenant_id and x.wallet_id=w.wallet_id and w.type='logistics';
alter table public.wallet_transactions enable trigger immutable_wallet_entry;
-- Receipt expense references are optional historical metadata, never reposted.
do $$ begin
 if exists(select 1 from public.sale_bottle_receipts r join public.wallets w on w.tenant_id=r.tenant_id and w.wallet_id=r.expense_wallet_id where w.type='logistics') then
 raise exception 'Historical bottle expense references a virtual wallet; reconcile its original source before migration';end if;end $$;
delete from public.wallets where type='logistics';
-- Funding is not a purchase payment. Retain genuine paid-header evidence where
-- historical attribution is unavailable, capped at the normalized payable.
update public.purchases p set paid_amount=least(payable_amount,greatest(0,paid_amount-coalesce((
 select -sum(x.amount) from public.wallet_transactions x where x.tenant_id=p.tenant_id and x.reference_id=p.purchase_id
 and x.type='purchase_transport_funding'),0)));
update public.purchases set payment_status=case when paid_amount>=payable_amount and status<>'created' then 'paid' when paid_amount>0 then 'partial' else 'unpaid' end;
-- Archive/remove only obsolete internal refund obligations; real obligations remain.
insert into public.financial_source_archive(tenant_id,source_table,source_id,reference_id,record,reason)
select tenant_id,'purchase_refund_obligations',obligation_id,purchase_id,to_jsonb(o),'Virtual funding reversal replaced by accounting normalization'
from public.purchase_refund_obligations o where component in ('transport','transport_income');
alter table public.purchase_refund_obligations disable trigger immutable_purchase_refund;
alter table public.purchase_refund_obligations drop constraint purchase_refund_obligations_amount_check;
update public.purchase_refund_obligations o set amount=greatest(
 coalesce((select sum(amount) from public.purchase_payments pp where pp.tenant_id=o.tenant_id and pp.obligation_id=o.obligation_id),0),
 case when not credit_business then 0 else amount-coalesce((select -sum((e->>'amount')::numeric) from jsonb_array_elements(o.sources) e
 where exists(select 1 from public.wallet_transactions x where x.tenant_id=o.tenant_id and x.transaction_id=(e->>'transaction_id')::uuid and x.type='purchase_transport_funding')),0) end),logistics_amount=0
where o.component in ('transport','transport_income') and (credit_business or exists(select 1 from public.purchase_payments pp where pp.tenant_id=o.tenant_id and pp.obligation_id=o.obligation_id));
delete from public.purchase_refund_obligations o where (amount=0 or not credit_business) and not exists(select 1 from public.purchase_payments pp where pp.tenant_id=o.tenant_id and pp.obligation_id=o.obligation_id);
alter table public.purchase_refund_obligations add constraint purchase_refund_obligations_amount_check check(amount>0);
alter table public.purchase_refund_obligations enable trigger immutable_purchase_refund;
update public.purchases p set refund_due=coalesce((select sum(greatest(0,o.amount-coalesce((select sum(pp.amount) from public.purchase_payments pp where pp.tenant_id=o.tenant_id and pp.obligation_id=o.obligation_id),0))) from public.purchase_refund_obligations o where o.tenant_id=p.tenant_id and o.purchase_id=p.purchase_id),0) where status='cancelled';
update public.purchases set financial_closed_at=coalesce(financial_closed_at,clock_timestamp()) where status='cancelled' and refund_due=0;

CREATE OR REPLACE FUNCTION app_private.initialize_wallets(t uuid)
 RETURNS void
 LANGUAGE sql
 SET search_path TO ''
AS $function$
 insert into public.wallets(tenant_id,type,name,kind,balance) values
 (t,'dealership','Primary Bank Account','bank',0),(t,'cash','Cash Register','cash',0),
 (t,'bkash','bKash','bkash',0),(t,'nagad','Nagad','nagad',0)
 on conflict (tenant_id,type) where type<>'custom' do nothing;
$function$;

CREATE OR REPLACE FUNCTION public.dispatch_purchase(p_purchase_id uuid, p_revision integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid := app_private.require_permission('purchases:manage'); p public.purchases; tr public.vehicles; x record;
begin
  select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id for update;
  if not found then raise exception 'Purchase not found'; end if;
  if p.status='in_transit' or p.status='received' then return jsonb_build_object('purchase_id',p_purchase_id,'already_dispatched',true); end if;
  if p.status<>'created' then raise exception 'Only a Created purchase can be dispatched'; end if;
  if p_revision is distinct from p.revision then raise exception 'Purchase changed. Reload before dispatch.' using errcode='P0001'; end if;
  select * into tr from public.vehicles where tenant_id=t and vehicle_id=p.vehicle_id for update;
  if not found or tr.status<>'idle' then raise exception 'Select an idle truck before dispatch'; end if;
  if exists(select 1 from public.transits where tenant_id=t and vehicle_id=p.vehicle_id and status='active')
    or exists(select 1 from public.purchases where tenant_id=t and vehicle_id=p.vehicle_id and status='in_transit') then
    raise exception 'Vehicle already has an active shipment'; end if;
  if not exists(select 1 from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id) then raise exception 'Add at least one product before dispatch'; end if;
  -- Existing Created plans need an explicit save before dispatch if they used
  -- independent empties. Do not silently rewrite a saved plan or its revision.
  if exists(select 1 from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id
    and empty_dispatched <> case when type='refill' then quantity else 0 end) then
    raise exception 'Refills exchange one empty cylinder per refill. Refresh and save the purchase before dispatch.';
  end if;
  perform 1 from public.gas_plants gp join public.lpg_brands b on b.tenant_id=gp.tenant_id and b.brand_id=gp.brand_id
    where gp.tenant_id=t and gp.plant_id=p.plant_id and gp.brand_id=p.brand_id and gp.is_active and b.is_active for share of gp,b;
  if not found then raise exception 'Plant company is unavailable'; end if;
  perform app_private.check_purchase_empties(t,(select jsonb_agg(to_jsonb(pi)) from public.purchase_items pi where tenant_id=t and purchase_id=p_purchase_id));
  -- Acquire stock locks in SKU order. Movement inserts apply the stock once.
  for x in select i.item_id,i.empty_quantity,i.brand_id,sum(pi.empty_dispatched) outgoing
    from public.purchase_items pi join public.items i on i.tenant_id=pi.tenant_id and i.item_id=pi.item_id
    where pi.tenant_id=t and pi.purchase_id=p_purchase_id group by i.tenant_id,i.item_id order by i.item_id loop
    perform 1 from public.items where tenant_id=t and item_id=x.item_id for update;
    if x.brand_id is distinct from p.brand_id then raise exception 'All products must belong to the plant company'; end if;
    if (select empty_quantity from public.items where tenant_id=t and item_id=x.item_id) < x.outgoing then
      raise exception 'Insufficient empty cylinder stock'; end if;
    if x.outgoing>0 then
      insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,empty_quantity_change,notes,created_by)
      values(t,x.item_id,'purchase','purchase_dispatch',p_purchase_id,-x.outgoing,'Empty cylinders dispatched to plant',auth.uid());
    end if;
  end loop;
  insert into public.transits(tenant_id,vehicle_id,purchase_id,status,transport_fee)
    values(t,p.vehicle_id,p_purchase_id,'active',p.transport_cost);
  update public.vehicles set status='going',updated_at=now() where tenant_id=t and vehicle_id=p.vehicle_id;
  update public.purchases set status='in_transit',dispatched_at=now(),payment_status=case when paid_amount>=payable_amount then 'paid' when paid_amount>0 then 'partial' else 'unpaid' end,paid_at=case when paid_amount>=payable_amount then now() end,updated_at=now(),revision=revision+1
    where tenant_id=t and purchase_id=p_purchase_id;
  insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details)
    values(t,p_purchase_id,'dispatched',auth.uid(),jsonb_build_object('empty_cylinders',
      (select sum(empty_dispatched) from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id)));
  return jsonb_build_object('purchase_id',p_purchase_id);
end $function$;

CREATE OR REPLACE FUNCTION public.update_purchase(p_purchase_id uuid, p_payload jsonb, p_revision integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid := app_private.require_permission('purchases:manage'); p public.purchases; truck uuid; before_items jsonb;
begin
  select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id for update;
  if not found then raise exception 'Purchase not found'; end if;
  if p_revision is distinct from p.revision then raise exception 'Purchase changed. Reload it before saving.' using errcode='P0001'; end if;
  if p.status='cancelled' or (p.status='received' and p.payment_status='paid') then raise exception 'Purchase is completed and locked'; end if;
  if p_payload ? 'plant_id' and (p_payload->>'plant_id')::uuid is distinct from p.plant_id
    or p_payload ? 'brand_id' and (p_payload->>'brand_id')::uuid is distinct from p.brand_id then
    raise exception 'Plant and company cannot change'; end if;
  select jsonb_agg(to_jsonb(pi)) into before_items from public.purchase_items pi where tenant_id=t and purchase_id=p_purchase_id;
  truck := case when p_payload ? 'vehicle_id' then (p_payload->>'vehicle_id')::uuid else p.vehicle_id end;
  if p.status<>'created' and truck is distinct from p.vehicle_id then raise exception 'Vehicle is locked after dispatch'; end if;
  if truck is not null and not exists(select 1 from public.vehicles where tenant_id=t and vehicle_id=truck) then raise exception 'Vehicle not found'; end if;
  if p.payment_status='paid' or exists(select 1 from public.wallet_transactions where tenant_id=t and reference_id=p_purchase_id and amount<0 and type in ('purchase_expense','purchase_company_payment','purchase_logistics_payment','purchase_payment_company','purchase_payment_labour','purchase_payment_transport','purchase_payment')) then
    if p_payload ? 'items' or p_payload ? 'commission' or p_payload ? 'transport_cost' or p_payload ? 'labour_cost' then
      raise exception 'Financial values lock after the first payment'; end if;
  else
    update public.purchases set vehicle_id=truck where tenant_id=t and purchase_id=p_purchase_id;
    if p_payload ?| array['items','commission','transport_cost','labour_cost'] then
    if p.status<>'created' then
      perform 1 from public.vehicles where tenant_id=t and vehicle_id=p.vehicle_id for update;
      perform 1 from public.transits where tenant_id=t and purchase_id=p_purchase_id order by transit_id for update;
    end if;
    if p_payload ? 'items' then perform app_private.save_purchase_lines(t,p_purchase_id,p_payload->'items'); end if;
    update public.purchases set vehicle_id=truck,
      transport_cost=app_private.purchase_money(coalesce((p_payload->>'transport_cost')::numeric,transport_cost,0)),
      labour_cost=app_private.purchase_money(coalesce((p_payload->>'labour_cost')::numeric,labour_cost,0)),
      commission=app_private.purchase_money(coalesce((p_payload->>'commission')::numeric,commission))
      where tenant_id=t and purchase_id=p_purchase_id;
    perform app_private.recalculate_purchase(t,p_purchase_id);
    if exists(select 1 from public.transits where tenant_id=t and purchase_id=p_purchase_id and closed_at is not null)
      and (select transport_cost from public.purchases where tenant_id=t and purchase_id=p_purchase_id) is distinct from p.transport_cost then
      raise exception 'Transport fee is locked because the transit is closed'; end if;
    update public.transits set transport_fee=(select transport_cost from public.purchases where tenant_id=t and purchase_id=p_purchase_id)
      where tenant_id=t and purchase_id=p_purchase_id;

    end if;
  end if;
  update public.purchases set payment_status=case when status='created' then payment_status when paid_amount>=payable_amount then 'paid' when paid_amount>0 then 'partial' else 'unpaid' end,
    paid_at=case when status<>'created' and paid_amount>=payable_amount then coalesce(paid_at,now()) else paid_at end,notes=case when p_payload ? 'notes' then p_payload->>'notes' else notes end,
    updated_at=now(),revision=revision+1 where tenant_id=t and purchase_id=p_purchase_id;
  insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details)
    values(t,p_purchase_id,'updated',auth.uid(),jsonb_build_object('before',to_jsonb(p),'before_items',before_items,
      'after',(select to_jsonb(h) from public.purchases h where h.tenant_id=t and h.purchase_id=p_purchase_id),
      'items',(select jsonb_agg(to_jsonb(pi)) from public.purchase_items pi where pi.tenant_id=t and pi.purchase_id=p_purchase_id)));
  return jsonb_build_object('purchase_id',p_purchase_id);
end $function$;

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
 select jsonb_build_object('total',p.payable_amount,'allocated_transport',p.transport_cost,'paid',p.paid_amount,'due',case when p.status='cancelled' then 0 else greatest(0,p.payable_amount-p.paid_amount) end,
 'refund_due',p.refund_due,'refunded',p.refunded_amount,'financial_closed_at',p.financial_closed_at,'can_cancel',public.can_cancel_purchases(),
 'financial_locked',p.payment_status='paid' or exists(select 1 from public.wallet_transactions where tenant_id=t and reference_id=p_purchase_id and amount<0 and type in ('purchase_expense','purchase_company_payment','purchase_logistics_payment','purchase_payment_company','purchase_payment_labour','purchase_payment_transport','purchase_payment')),
 'obligations',coalesce((select jsonb_agg(to_jsonb(o)||jsonb_build_object('refunded',coalesce(q.amount,0),'remaining',o.amount-coalesce(q.amount,0)) order by o.component)
 from public.purchase_refund_obligations o left join lateral(select sum(amount) amount from public.purchase_payments where tenant_id=t and obligation_id=o.obligation_id) q on true where o.tenant_id=t and o.purchase_id=p_purchase_id),'[]'),
 'payment_count',(select count(*) from public.wallet_transactions where tenant_id=t and reference_id=p_purchase_id),
 'payments',coalesce((select jsonb_agg(to_jsonb(e) order by e.entry_no) from (select x.transaction_id,x.purchase_payment_id,x.wallet_name_snapshot wallet_name,x.wallet_method_snapshot method,x.amount,x.type,x.created_at,x.entry_no,x.operation_id,x.description,x.counterparty_wallet_id,pp.reference,pp.component,pp.obligation_id,up.full_name actor
  from public.wallet_transactions x left join public.purchase_payments pp on pp.tenant_id=t and pp.payment_id=x.purchase_payment_id
  left join public.user_profiles up on up.tenant_id=t and up.user_id=x.created_by
  where x.tenant_id=t and x.reference_id=p_purchase_id order by x.entry_no limit p_limit offset p_offset) e),'[]')) into result;
 return result;
end $function$;

CREATE OR REPLACE FUNCTION public.get_purchase_overview()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_any_permission(array['purchases:view','purchases:manage']); result jsonb;
begin
 select jsonb_build_object('total',count(*),'created',count(*) filter(where status='created'),'in_transit',count(*) filter(where status='in_transit'),
 'unpaid',count(*) filter(where payment_status<>'paid' and status not in ('created','cancelled')),
 'company_payable',coalesce(sum(company_payable) filter(where payment_status<>'paid' and status not in ('created','cancelled')),0),
 'outstanding',coalesce(sum(greatest(0,payable_amount-paid_amount)) filter(where status not in ('created','cancelled')),0),
 'refund_due',coalesce(sum(refund_due),0),'pending_refunds',count(*) filter(where status='cancelled' and financial_closed_at is null)) into result from public.purchases where tenant_id=t;
 return result;
end $function$;

CREATE OR REPLACE FUNCTION public.initiate_purchase_cancellation(p_purchase_id uuid, p_revision integer, p_confirmation text, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_permission('purchases:manage'); p public.purchases; prior public.finance_requests; payload jsonb; result jsonb;
 r record; obligation_total numeric:=0; sources jsonb;
begin
 if not public.can_cancel_purchases() then raise exception 'Only the OWNER can cancel purchases' using errcode='42501'; end if;
 if p_confirmation is distinct from 'CANCEL' then raise exception 'Type exactly CANCEL to confirm cancellation'; end if;
 if p_request_id is null then raise exception 'Cancellation request ID is required'; end if;
 payload:=jsonb_build_object('action','purchase_cancel','purchase',p_purchase_id,'revision',p_revision,'confirmation',p_confirmation,'actor',auth.uid());
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from payload then raise exception 'Request ID already used with different details'; end if; return prior.result; end if;
 select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id for update;
 if not found then raise exception 'Purchase not found'; end if;
 if p.status='received' then raise exception 'Received purchases can never be cancelled'; end if;
 if p.status='cancelled' then raise exception 'Purchase is already cancelled'; end if;
 if p_revision is distinct from p.revision then raise exception 'Purchase changed. Reload before cancellation.' using errcode='P0001'; end if;
 perform 1 from public.vehicles where tenant_id=t and vehicle_id=p.vehicle_id for update;
 perform 1 from public.transits where tenant_id=t and purchase_id=p_purchase_id order by transit_id for update;
 insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details) values(t,p_purchase_id,'cancellation_confirmed',auth.uid(),jsonb_build_object('previous_status',p.status,'confirmation','CANCEL','operation_id',p_request_id,'before',to_jsonb(p)));
 -- Only dispatch is reversible: receiving is a permanent cancellation boundary.
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
   and x.type in ('purchase_expense','purchase_company_payment','purchase_logistics_payment','purchase_payment_company','purchase_payment_labour','purchase_payment_transport','purchase_payment')
 ) q group by component loop
  if r.amount>0 then
   insert into public.purchase_refund_obligations(tenant_id,purchase_id,component,amount,sources,created_by)
    values(t,p_purchase_id,r.component,r.amount,r.sources,auth.uid());
   obligation_total:=obligation_total+r.amount;

  end if;
 end loop;
 update public.transits set status='cancelled',revision=revision+1,updated_at=now() where tenant_id=t and purchase_id=p_purchase_id;
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

CREATE OR REPLACE FUNCTION public.refund_purchase(p_purchase_id uuid, p_obligation_id uuid, p_payments jsonb, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_permission('purchases:manage'); p public.purchases; o public.purchase_refund_obligations;
 payload jsonb; prior public.finance_requests; result jsonb; x jsonb; w public.wallets; a numeric; id uuid;
 refunded numeric; total numeric:=0; details jsonb:='[]';
begin
 if p_request_id is null then raise exception 'Refund request ID is required'; end if;
 payload:=jsonb_build_object('action','purchase_refund','purchase',p_purchase_id,'obligation',p_obligation_id,'payments',p_payments,'actor',auth.uid());
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from payload then raise exception 'Request ID already used with different details'; end if; return prior.result; end if;
 select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id for update;
 if not found then raise exception 'Purchase not found'; end if;
 if p.status<>'cancelled' or p.financial_closed_at is not null then raise exception 'Only pending cancelled purchases accept refunds'; end if;
 select * into o from public.purchase_refund_obligations where tenant_id=t and purchase_id=p_purchase_id and obligation_id=p_obligation_id;
 if not found then raise exception 'Refund obligation not found'; end if;
 select coalesce(sum(amount),0) into refunded from public.purchase_payments where tenant_id=t and obligation_id=p_obligation_id;
 if p_payments is null or jsonb_typeof(p_payments)<>'array' or jsonb_array_length(p_payments) not between 1 and 20 then raise exception 'Add between 1 and 20 refund entries'; end if;
 perform 1 from public.wallets where tenant_id=t and (wallet_id in(select (value->>'wallet_id')::uuid from jsonb_array_elements(p_payments))) order by wallet_id for update;
 for x in select value from jsonb_array_elements(p_payments) loop
  if jsonb_typeof(x)<>'object' or jsonb_typeof(x->'amount') is distinct from 'number' then raise exception 'Refund amounts must be numbers'; end if;
  a:=app_private.purchase_money((x->>'amount')::numeric);
  if a<=0 or a<>(x->>'amount')::numeric then raise exception 'Enter a positive amount with at most two decimals'; end if;
  if length(coalesce(x->>'reference',''))>200 then raise exception 'Refund reference is too long'; end if;
  select * into w from public.wallets where tenant_id=t and wallet_id=(x->>'wallet_id')::uuid and is_active ;
  if not found then raise exception 'Select an active refund wallet belonging to this business'; end if;
  if refunded+total+a>o.amount then raise exception 'Refund exceeds the remaining obligation'; end if;
  insert into public.purchase_payments(tenant_id,purchase_id,wallet_id,wallet_name,method,amount,kind,component,obligation_id,operation_id,reference,created_by)
   values(t,p_purchase_id,w.wallet_id,w.name,w.kind,a,'refund',o.component,o.obligation_id,p_request_id,coalesce(x->>'reference',''),auth.uid()) returning payment_id into id;
   insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description,operation_id,purchase_payment_id)
    values(t,w.wallet_id,a,'purchase_refund',p_purchase_id,'Purchase '||o.component||' refund Â· '||w.name||' Â· '||coalesce(x->>'reference',''),p_request_id,id);
  details:=details||jsonb_build_array(jsonb_build_object('payment_id',id,'wallet_id',w.wallet_id,'wallet_name',w.name,'method',w.kind,'amount',a,'component',o.component,'reference',coalesce(x->>'reference',''),'business_credit',a));
  total:=total+a;
 end loop;
 update public.purchases set refund_due=refund_due-total,refunded_amount=refunded_amount+total,
  financial_closed_at=case when refund_due=total then now() end,revision=revision+1,updated_at=now() where tenant_id=t and purchase_id=p_purchase_id;
 result:=jsonb_build_object('purchase_id',p_purchase_id,'refunded',total,'refund_due',p.refund_due-total,'financially_closed',p.refund_due=total);
 insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details) values(t,p_purchase_id,'refund_recorded',auth.uid(),result||jsonb_build_object('payments',details,'obligation_id',o.obligation_id,'original_payments',o.sources,'operation_id',p_request_id));
 if p.refund_due=total then
  insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details) values(t,p_purchase_id,'refund_completed',auth.uid(),result),(t,p_purchase_id,'financially_closed',auth.uid(),jsonb_build_object('notes','All purchase refund obligations settled. Transit operating-cost closure remains independent.'));
 end if;
 insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,payload,result,auth.uid());
 return result;
end $function$;

CREATE OR REPLACE FUNCTION public.record_purchase_payment(p_purchase_id uuid, p_payments jsonb, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_permission('purchases:manage'); p public.purchases; payload jsonb; prior public.finance_requests; result jsonb;
 x jsonb; w public.wallets; a numeric; part numeric; remaining numeric; company_left numeric; labour_left numeric; component text; id uuid; paid numeric:=0; detail jsonb:='[]';
begin
 if p_request_id is null then raise exception 'Payment request ID is required'; end if;
 payload:=jsonb_build_object('action','purchase_payment','purchase',p_purchase_id,'payments',p_payments,'actor',auth.uid());
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from payload then raise exception 'Request ID already used with different details'; end if; return prior.result; end if;
 select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id for update;
 if not found then raise exception 'Purchase not found'; end if;
 if p.status not in ('in_transit','received') then raise exception 'Payments require a dispatched, non-cancelled purchase'; end if;
 if p.payment_status='paid' or p.payable_amount<=p.paid_amount then raise exception 'Purchase is already fully paid'; end if;
 if p_payments is null or jsonb_typeof(p_payments)<>'array' or jsonb_array_length(p_payments) not between 1 and 20 then raise exception 'Add between 1 and 20 payment entries'; end if;
 perform 1 from public.wallets where tenant_id=t and wallet_id in(select (value->>'wallet_id')::uuid from jsonb_array_elements(p_payments)) order by wallet_id for update;
 for x in select value from jsonb_array_elements(p_payments) loop
  if jsonb_typeof(x)<>'object' or jsonb_typeof(x->'amount') is distinct from 'number' then raise exception 'Payment amounts must be numbers'; end if;
  a:=app_private.purchase_money((x->>'amount')::numeric);
  if a<=0 or a<>(x->>'amount')::numeric then raise exception 'Enter a positive amount with at most two decimals'; end if;
  select * into w from public.wallets where tenant_id=t and wallet_id=(x->>'wallet_id')::uuid and is_active ;
  if not found then raise exception 'Select an active payment wallet belonging to this business'; end if;
  if length(coalesce(x->>'reference',''))>200 then raise exception 'Payment reference is too long'; end if;
  paid:=paid+a; if p.paid_amount+paid>p.payable_amount then raise exception 'Payments exceed the remaining purchase balance'; end if;
  insert into public.purchase_payments(tenant_id,purchase_id,wallet_id,wallet_name,method,amount,kind,component,operation_id,reference,created_by)
   values(t,p_purchase_id,w.wallet_id,w.name,w.kind,a,'payment','purchase',p_request_id,coalesce(x->>'reference',''),auth.uid()) returning payment_id into id;
  insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description,operation_id,purchase_payment_id)
   values(t,w.wallet_id,-a,'purchase_payment',p_purchase_id,'Purchase payment · '||w.name||' · '||coalesce(x->>'reference',''),p_request_id,id);
  detail:=detail||jsonb_build_array(jsonb_build_object('payment_id',id,'wallet_id',w.wallet_id,'wallet_name',w.name,'method',w.kind,'amount',a,'component','purchase'));
 end loop;
 update public.purchases set paid_amount=paid_amount+paid,payment_status=case when paid_amount+paid>=payable_amount then 'paid' else 'partial' end,
 paid_at=case when paid_amount+paid>=payable_amount then now() else null end,revision=revision+1,updated_at=now() where tenant_id=t and purchase_id=p_purchase_id;
 result:=jsonb_build_object('purchase_id',p_purchase_id,'paid',paid,'paid_amount',p.paid_amount+paid,'due',p.payable_amount-p.paid_amount-paid);
 insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details) values(t,p_purchase_id,'payment_recorded',auth.uid(),result||jsonb_build_object('payments',detail,'operation_id',p_request_id));
 insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,payload,result,auth.uid());
 return result;
end $function$;

CREATE OR REPLACE FUNCTION public.employee_payment_operation(p_payload jsonb, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_permission('payroll:pay'); action text:=p_payload->>'action'; prior public.finance_requests;
 payload jsonb:=jsonb_build_object('action','employee_payment','actor',auth.uid(),'body',p_payload); result jsonb;
 eid uuid; oid uuid; month date; pid uuid; tid uuid; tr public.transits; e public.employees;
 payment public.employee_payments; ent public.employee_payment_entries; w public.wallets;
 item jsonb; x jsonb; balance jsonb; amount numeric; total numeric; kind text; reason text; entry uuid;
 items jsonb; ids jsonb:='[]'; role_name text; trip_count integer;
begin
 if p_request_id is null or jsonb_typeof(p_payload) is distinct from 'object' then raise exception 'Request ID and operation are required'; end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload<>payload then raise exception 'Request ID was already used with different details'; end if; return prior.result; end if;
 if action='pay' then
 items:=p_payload->'items';
 if jsonb_typeof(items) is distinct from 'array' or jsonb_array_length(items)<>1 then raise exception 'Choose one employee per payment'; end if;
 if (select count(distinct value->>'employee_id') from jsonb_array_elements(items))<>jsonb_array_length(items) then raise exception 'Choose each employee once per payment'; end if;
 -- Trip payments are individual. Transit precedes employee/obligation/wallet.
 if exists(select 1 from jsonb_array_elements(items) j where nullif(j->>'transit_id','') is not null) then
 if jsonb_array_length(items)<>1 then raise exception 'Record linked trip payments individually'; end if;
 perform app_private.require_permission('logistics:manage');
 tid:=(items->0->>'transit_id')::uuid;
 select * into tr from public.transits where tenant_id=t and transit_id=tid for update;
 if not found or tr.closed_at is not null then raise exception 'Select a trip with open operating costs'; end if;
 end if;
 perform 1 from public.employees where tenant_id=t and employee_id in (select (value->>'employee_id')::uuid from jsonb_array_elements(items)) order by employee_id for update;
 for item in select value from jsonb_array_elements(items) loop
 eid:=(item->>'employee_id')::uuid; kind:=item->>'kind'; oid:=null; month:=null; reason:=nullif(trim(item->>'description'),'');
 if not exists(select 1 from public.employees where tenant_id=t and employee_id=eid) then raise exception 'Employee not found'; end if;
 if kind is null or kind not in ('salary','bonus','trips') then raise exception 'Select a payment category'; end if;
 if kind='salary' then month:=app_private.employee_month((item->>'period')::date); elsif item ? 'period' then raise exception 'Only salary has a salary month'; end if;
 if (item->>'payment_date')::date is null or (item->>'payment_date')::date>(now() at time zone 'Asia/Dhaka')::date then raise exception 'Payment date is required and cannot be in the future'; end if;
 if kind='bonus' and (nullif(trim(item->>'bonus_name'),'') is null or length(item->>'bonus_name')>120) then raise exception 'Name this bonus (up to 120 characters)'; end if;
 if length(reason)>1000 then raise exception 'Description is too long'; end if;
 if kind='salary' then
 balance:=app_private.employee_month_balance(t,eid,month);
 if (balance->>'salary_amount')::numeric<=0 then raise exception 'No salary is due for this month'; end if;
 insert into public.employee_salary_months(tenant_id,employee_id,period,salary_amount,calculation,created_by)
 values(t,eid,month,(balance->>'salary_amount')::numeric,jsonb_build_object('source','salary_revision','monthly_salary',(balance->>'salary_amount')::numeric),auth.uid())
 on conflict(tenant_id,employee_id,period) do nothing;
 select salary_month_id into oid from public.employee_salary_months where tenant_id=t and employee_id=eid and period=month for update;
 end if;
 if jsonb_typeof(item->'payments') is distinct from 'array' or jsonb_array_length(item->'payments') not between 1 and 20 then raise exception 'Use one to twenty payment entries'; end if;
 if kind in ('salary','bonus') and jsonb_array_length(item->'payments')<>1 then raise exception 'Choose one wallet per salary or bonus payment'; end if;
 total:=0;
 perform 1 from public.wallets where tenant_id=t and wallet_id in (select (v->>'wallet_id')::uuid from jsonb_array_elements(item->'payments') v) order by wallet_id for update;
 for x in select value from jsonb_array_elements(item->'payments') loop
 if jsonb_typeof(x->'amount') is distinct from 'number' then raise exception 'Payment amounts must be numbers'; end if;
 amount:=app_private.purchase_money((x->>'amount')::numeric); if amount<=0 or amount<>(x->>'amount')::numeric then raise exception 'Payment must be positive'; end if; total:=total+amount;
 if length(coalesce(x->>'reference',''))>200 then raise exception 'Payment reference is too long'; end if;
 if not exists(select 1 from public.wallets pw where pw.tenant_id=t and pw.wallet_id=(x->>'wallet_id')::uuid and pw.is_active ) then raise exception 'Select an active payment wallet belonging to this business'; end if;
 end loop;
 if oid is not null and total>(balance->>'outstanding')::numeric then raise exception 'Payment exceeds outstanding salary. Reload this month before paying.'; end if;
 role_name:=item->>'trip_role'; trip_count:=(item->>'trip_count')::integer;
 if kind='trips' then
 if tid is null then raise exception 'Trip payments require a saved Logistics trip'; end if;
 if trip_count is null or trip_count<1 then raise exception 'Enter a positive trip count'; end if;
 if tid is not null then
 if role_name is null or role_name not in ('driver','helper') then raise exception 'Choose driver or helper'; end if;
 if eid is distinct from (case role_name when 'driver' then tr.driver_employee_id else tr.helper_employee_id end) then raise exception 'Pay the employee recorded on this transit'; end if;
 if total+app_private.transit_employee_paid(t,tid,role_name)>(case role_name when 'driver' then tr.driver_cost else tr.helper_cost end) then raise exception 'Employee payment exceeds the saved trip role cost'; end if;
 end if;
 elsif trip_count is not null or role_name is not null or tid is not null then raise exception 'Trip fields are only valid for trip payments'; end if;
 insert into public.employee_payments(tenant_id,employee_id,kind,amount,payment_date,description,salary_month_id,trip_count,transit_id,trip_role,operation_id,created_by,bonus_name)
 values(t,eid,kind,total,(item->>'payment_date')::date,reason,oid,trip_count,tid,role_name,p_request_id,auth.uid(),case when kind='bonus' then trim(item->>'bonus_name') end) returning payment_id into pid;
 for x in select value from jsonb_array_elements(item->'payments') loop
 select * into w from public.wallets where tenant_id=t and wallet_id=(x->>'wallet_id')::uuid;
 insert into public.employee_payment_entries(tenant_id,payment_id,wallet_id,wallet_name,method,amount,reference)
 values(t,pid,w.wallet_id,w.name,w.kind,(x->>'amount')::numeric,coalesce(x->>'reference','')) returning entry_id into entry;
 insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description,operation_id,employee_entry_id)
 values(t,w.wallet_id,-(x->>'amount')::numeric,'payroll_'||kind,pid,
 (select name from public.employees where tenant_id=t and employee_id=eid)||' Â· '||case when kind='bonus' then trim(item->>'bonus_name') when kind='salary' then 'Salary Â· '||to_char(month,'FMMonth YYYY') else 'Trip payment' end||coalesce(' Â· '||reason,'')||coalesce(' Â· '||(x->>'reference'),''),p_request_id,entry);
 end loop;
 if tid is not null then update public.transits set revision=revision+1,updated_at=clock_timestamp() where tenant_id=t and transit_id=tid; end if;
 ids:=ids||jsonb_build_array(pid);
 end loop;
 result:=jsonb_build_object('payment_ids',ids);
 elsif action='reverse_payment' then
 select * into payment from public.employee_payments where tenant_id=t and payment_id=(p_payload->>'payment_id')::uuid;
 if not found or payment.reversal_of is not null then raise exception 'Original payment not found'; end if;
 if payment.transit_id is not null then
 perform app_private.require_permission('logistics:manage');
 select * into tr from public.transits where tenant_id=t and transit_id=payment.transit_id for update;
 if tr.closed_at is not null then raise exception 'Closed trip payments are locked. Record a separately audited Finance correction.'; end if;
 end if;
 perform 1 from public.employees where tenant_id=t and employee_id=payment.employee_id for update;
 if payment.salary_month_id is not null then perform 1 from public.employee_salary_months where tenant_id=t and salary_month_id=payment.salary_month_id for update; end if;
 if exists(select 1 from public.employee_payments where tenant_id=t and reversal_of=payment.payment_id) then raise exception 'Payment has already been reversed'; end if;
 if not exists(select 1 from public.employee_payment_entries where tenant_id=t and payment_id=payment.payment_id) or exists(select 1 from public.employee_payment_entries where tenant_id=t and payment_id=payment.payment_id and wallet_id is null) then raise exception 'Historical payment has no wallet evidence and cannot create a wallet refund'; end if;
 reason:=nullif(trim(p_payload->>'reason'),''); if reason is null or length(reason)>1000 then raise exception 'A reversal reason is required'; end if;
 if (p_payload->>'payment_date')::date is null or (p_payload->>'payment_date')::date<payment.payment_date or (p_payload->>'payment_date')::date>(now() at time zone 'Asia/Dhaka')::date then raise exception 'Enter the date funds were returned'; end if;
 perform 1 from public.wallets where tenant_id=t and wallet_id in (select wallet_id from public.employee_payment_entries where tenant_id=t and payment_id=payment.payment_id) order by wallet_id for update;
 insert into public.employee_payments(tenant_id,employee_id,kind,amount,payment_date,description,salary_month_id,trip_count,transit_id,trip_role,reversal_of,operation_id,created_by,bonus_name)
 values(t,payment.employee_id,payment.kind,payment.amount,(p_payload->>'payment_date')::date,reason,payment.salary_month_id,payment.trip_count,payment.transit_id,payment.trip_role,payment.payment_id,p_request_id,auth.uid(),payment.bonus_name) returning payment_id into pid;
 for ent in select * from public.employee_payment_entries where tenant_id=t and payment_id=payment.payment_id loop
 insert into public.employee_payment_entries(tenant_id,payment_id,wallet_id,wallet_name,method,amount,reference)
 values(t,pid,ent.wallet_id,ent.wallet_name,ent.method,ent.amount,ent.reference) returning entry_id into entry;
 insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description,operation_id,employee_entry_id)
 values(t,ent.wallet_id,ent.amount,'payroll_reversal',pid,'Returned employee funds Â· '||reason,p_request_id,entry);
 end loop;
 if payment.transit_id is not null then update public.transits set revision=revision+1,updated_at=clock_timestamp() where tenant_id=t and transit_id=payment.transit_id; end if;
 result:=jsonb_build_object('payment_id',pid);
 else raise exception 'Unknown employee payment operation'; end if;
 insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,payload,result,auth.uid()); return result;
end $function$;

CREATE OR REPLACE FUNCTION public.get_payment_wallets()
 RETURNS TABLE(wallet_id uuid, name text, kind text, type text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_any_permission(array['pos:sell','finance:view','finance:manage','purchases:manage','payroll:pay']);
begin return query select w.wallet_id,w.name,w.kind,w.type from public.wallets w where w.tenant_id=t and w.is_active 
 order by case w.type when 'cash' then 0 when 'bkash' then 1 when 'nagad' then 2 when 'dealership' then 3 else 4 end,w.name,w.wallet_id; end $function$;

CREATE OR REPLACE FUNCTION public.get_trip_payment_wallets(p_transit_id uuid)
 RETURNS TABLE(wallet_id uuid, name text, kind text, type text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_permission('payroll:pay');
begin
 perform app_private.require_permission('logistics:manage');
 if not exists(select 1 from public.transits where tenant_id=t and transit_id=p_transit_id and closed_at is null) then raise exception 'Select a trip with open costs'; end if;
 return query select w.wallet_id,w.name,w.kind,w.type from public.wallets w where w.tenant_id=t and w.is_active order by w.name,w.wallet_id;
end $function$;

CREATE OR REPLACE FUNCTION public.create_custom_transit(p_payload jsonb, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_permission('logistics:manage'); vehicle public.vehicles; id uuid; wid uuid;
 fee numeric:=app_private.purchase_money((p_payload->>'fee')::numeric); prior public.finance_requests;
 body jsonb:=jsonb_build_object('action','custom_transit','actor',auth.uid(),'body',p_payload); result jsonb;
begin
 if p_request_id is null or jsonb_typeof(p_payload) is distinct from 'object' then raise exception 'Transit details and request ID are required'; end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload<>body then raise exception 'Request ID was already used with different details'; end if; return prior.result; end if;
 select * into vehicle from public.vehicles where tenant_id=t and vehicle_id=(p_payload->>'vehicle_id')::uuid for update;
 if not found or vehicle.status<>'idle' then raise exception 'Select a vehicle at Home'; end if;
 if nullif(trim(p_payload->>'client_name'),'') is null or length(p_payload->>'client_name')>200 or nullif(trim(p_payload->>'destination'),'') is null or length(p_payload->>'destination')>300 or length(p_payload->>'description')>1000 then raise exception 'Client and destination are required (up to 200 and 300 characters)'; end if;
 insert into public.transits(tenant_id,vehicle_id,status,transport_fee,client_name,destination,description)
  values(t,vehicle.vehicle_id,'active',fee,trim(p_payload->>'client_name'),trim(p_payload->>'destination'),p_payload->>'description') returning transit_id into id;
 update public.vehicles set status='going',updated_at=clock_timestamp() where tenant_id=t and vehicle_id=vehicle.vehicle_id;
 result:=jsonb_build_object('transit_id',id);
 insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,result,auth.uid()); return result;
end $function$;

drop function app_private.fund_purchase_transport(uuid,uuid);
alter table public.purchases drop column transport_funded;
-- Categories are shared by vehicle service trips and additional transit costs.
create table public.vehicle_expense_categories(
 tenant_id uuid not null references public.tenants(tenant_id),category_id uuid not null default gen_random_uuid(),
 name text not null check(length(trim(name)) between 1 and 80),is_active boolean not null default true,
 revision integer not null default 1,primary key(tenant_id,category_id)
);
create unique index vehicle_category_name on public.vehicle_expense_categories(tenant_id,lower(name));
create function app_private.initialize_vehicle_categories(t uuid) returns void language sql set search_path='' as $$
 insert into public.vehicle_expense_categories(tenant_id,name) select t,n from unnest(array['Engine Oil','Spare Parts','Trip Cost','Road Permit Renewal','Vehicle Tax','Other Costs']) n on conflict do nothing;
$$;
select app_private.initialize_vehicle_categories(tenant_id) from public.tenants;
create function app_private.vehicle_categories_created() returns trigger language plpgsql set search_path='' as $$
begin perform app_private.initialize_vehicle_categories(new.tenant_id);return new;end $$;
create trigger vehicle_categories_created after insert on public.tenants for each row execute function app_private.vehicle_categories_created();
create function public.get_vehicle_expense_categories() returns setof public.vehicle_expense_categories language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['settings:manage','logistics:view','logistics:manage']);begin
 return query select * from public.vehicle_expense_categories where tenant_id=t order by name,category_id;
end $$;
create function public.save_vehicle_expense_category(p_payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('settings:manage');id uuid:=nullif(p_payload->>'category_id','')::uuid;begin
 if nullif(trim(p_payload->>'name'),'') is null or length(p_payload->>'name')>80 then raise exception 'Enter a category name (up to 80 characters)';end if;
 if id is null then insert into public.vehicle_expense_categories(tenant_id,name) values(t,trim(p_payload->>'name')) returning category_id into id;
 else update public.vehicle_expense_categories set name=trim(p_payload->>'name'),is_active=coalesce((p_payload->>'is_active')::boolean,true),revision=revision+1
 where tenant_id=t and category_id=id and revision=(p_payload->>'revision')::integer;
 if not found then raise exception 'Category changed. Reload before saving.';end if;end if;
 return jsonb_build_object('category_id',id);
end $$;
create table public.vehicle_service_trips(
 tenant_id uuid not null,service_trip_id uuid not null default gen_random_uuid(),vehicle_id uuid not null,
 title text not null check(length(trim(title)) between 1 and 160),service_date date not null check(isfinite(service_date)),
 expenses jsonb not null default '[]' check(jsonb_typeof(expenses)='array'),total_cost numeric(14,2) not null default 0 check(total_cost>=0 and total_cost<10000000000),
 revision integer not null default 1,finalized_at timestamptz,created_at timestamptz not null default clock_timestamp(),
 created_by uuid not null,updated_at timestamptz not null default clock_timestamp(),primary key(tenant_id,service_trip_id),
 foreign key(tenant_id,vehicle_id) references public.vehicles(tenant_id,vehicle_id),
 foreign key(tenant_id,created_by) references public.user_profiles(tenant_id,user_id)
);
create index vehicle_service_history on public.vehicle_service_trips(tenant_id,vehicle_id,service_date desc,service_trip_id);
create index vehicle_service_categories on public.vehicle_service_trips using gin(expenses jsonb_path_ops);
create table public.operating_payments(
 tenant_id uuid not null,payment_id uuid not null default gen_random_uuid(),transit_id uuid,service_trip_id uuid,
 kind text not null check(kind in ('expense','expense_return','client_receipt','client_refund')),
 wallet_id uuid not null,wallet_name text not null,method text not null,
 amount numeric(14,2) not null check(amount>0 and amount<10000000000),reference text not null default '' check(length(reference)<=200),
 payment_date date not null check(isfinite(payment_date)),operation_id uuid not null,return_of uuid,
 created_at timestamptz not null default clock_timestamp(),created_by uuid not null,
 primary key(tenant_id,payment_id),check(num_nonnulls(transit_id,service_trip_id)=1),
 check((kind='expense_return')=(return_of is not null)),
 foreign key(tenant_id,transit_id) references public.transits(tenant_id,transit_id),
 foreign key(tenant_id,service_trip_id) references public.vehicle_service_trips(tenant_id,service_trip_id),
 foreign key(tenant_id,wallet_id) references public.wallets(tenant_id,wallet_id),
 foreign key(tenant_id,return_of) references public.operating_payments(tenant_id,payment_id),
 foreign key(tenant_id,created_by) references public.user_profiles(tenant_id,user_id)
);
create index operating_transit_history on public.operating_payments(tenant_id,transit_id,created_at,payment_id);
create index operating_service_history on public.operating_payments(tenant_id,service_trip_id,created_at,payment_id);
create index operating_returns on public.operating_payments(tenant_id,return_of) where return_of is not null;
alter table public.wallet_transactions add column operating_payment_id uuid,
 add foreign key(tenant_id,operating_payment_id) references public.operating_payments(tenant_id,payment_id);
create unique index operating_ledger_once on public.wallet_transactions(tenant_id,operating_payment_id) where operating_payment_id is not null;
create table public.operating_cost_events(
 tenant_id uuid not null,event_id uuid not null default gen_random_uuid(),transit_id uuid,service_trip_id uuid,
 category text not null,amount numeric(14,2) not null,incurred_on date not null check(isfinite(incurred_on)),
 recorded_at timestamptz not null default clock_timestamp(),created_by uuid,details jsonb not null,
 primary key(tenant_id,event_id),check(num_nonnulls(transit_id,service_trip_id)=1),
 foreign key(tenant_id,transit_id) references public.transits(tenant_id,transit_id),
 foreign key(tenant_id,service_trip_id) references public.vehicle_service_trips(tenant_id,service_trip_id)
);
create index operating_cost_period on public.operating_cost_events(tenant_id,incurred_on,category);
create index operating_cost_transit on public.operating_cost_events(tenant_id,transit_id);
create index operating_cost_service on public.operating_cost_events(tenant_id,service_trip_id);
create table public.service_trip_activity(
 tenant_id uuid not null,activity_id uuid not null default gen_random_uuid(),service_trip_id uuid not null,
 action text not null,details jsonb not null,created_at timestamptz not null default clock_timestamp(),created_by uuid not null,
 primary key(tenant_id,activity_id),foreign key(tenant_id,service_trip_id) references public.vehicle_service_trips(tenant_id,service_trip_id)
);
create index service_activity_history on public.service_trip_activity(tenant_id,service_trip_id,created_at desc,activity_id);
create function app_private.transit_operating_paid(t uuid,id uuid) returns numeric language sql stable set search_path='' as $$
 select coalesce((select sum(case when kind='expense' then amount else -amount end) from public.operating_payments where tenant_id=t and transit_id=id and kind in ('expense','expense_return')),0)
 +coalesce((select -sum((record->>'amount')::numeric) from public.financial_source_archive where tenant_id=t and source_table='wallet_transactions' and reference_id=id and record->>'type' in ('transit_close_cost','transit_cost')),0);
$$;
create function app_private.service_paid(t uuid,id uuid) returns numeric language sql stable set search_path='' as $$
 select coalesce(sum(case when kind='expense' then amount else -amount end),0) from public.operating_payments where tenant_id=t and service_trip_id=id;
$$;
create function app_private.transit_client_paid(t uuid,id uuid) returns numeric language sql stable set search_path='' as $$
 select coalesce(sum(case when kind='client_receipt' then amount else -amount end),0) from public.operating_payments where tenant_id=t and transit_id=id and kind in ('client_receipt','client_refund');
$$;
create function app_private.transit_expense_breakdown(tr public.transits) returns table(category text,amount numeric) language sql immutable set search_path='' as $$
 select 'Driver earnings',tr.driver_cost union all select 'Helper earnings',tr.helper_cost union all select 'Engine Oil',tr.oil_cost union all select 'Other Costs',tr.others_cost
 union all select value->>'name',(value->>'amount')::numeric from jsonb_array_elements(tr.additional_costs);
$$;
-- Historical incurrence date is the journey date; original row/timing stays in details.
insert into public.operating_cost_events(tenant_id,transit_id,category,amount,incurred_on,details)
select tr.tenant_id,tr.transit_id,c.category,c.amount,(tr.created_at at time zone 'Asia/Dhaka')::date,
 jsonb_build_object('source','historical_transit','original',to_jsonb(tr)) from public.transits tr cross join lateral app_private.transit_expense_breakdown(tr) c where c.amount<>0;
create function app_private.capture_transit_costs() returns trigger language plpgsql set search_path='' as $$
begin
 insert into public.operating_cost_events(tenant_id,transit_id,category,amount,incurred_on,created_by,details)
 select new.tenant_id,new.transit_id,coalesce(n.category,o.category),coalesce(n.amount,0)-coalesce(o.amount,0),
 (new.created_at at time zone 'Asia/Dhaka')::date,auth.uid(),jsonb_build_object('before',to_jsonb(old),'after',to_jsonb(new))
 from (select category,sum(amount) amount from app_private.transit_expense_breakdown(new) group by category) n full join
 (select category,sum(amount) amount from app_private.transit_expense_breakdown(old) group by category) o using(category)
 where coalesce(n.amount,0)<>coalesce(o.amount,0);
 return new;
end $$;
create trigger capture_transit_costs after update of driver_cost,helper_cost,oil_cost,others_cost,additional_costs on public.transits for each row execute function app_private.capture_transit_costs();
create function app_private.service_json(t uuid,id uuid) returns jsonb language sql stable set search_path='' as $$
 select to_jsonb(s)||jsonb_build_object('vehicle_name',v.name,'paid',app_private.service_paid(t,id),
 'outstanding',greatest(0,s.total_cost-app_private.service_paid(t,id)),'advance',greatest(0,app_private.service_paid(t,id)-s.total_cost))
 from public.vehicle_service_trips s join public.vehicles v using(tenant_id,vehicle_id) where s.tenant_id=t and s.service_trip_id=id;
$$;
create function public.get_service_trip(p_service_trip_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['logistics:view','logistics:manage']);r jsonb;begin
 r:=app_private.service_json(t,p_service_trip_id);if r is null then raise exception 'Service trip not found';end if;return r;
end $$;
create function public.get_service_trip_directory(p_filters jsonb default '{}',p_offset integer default 0,p_limit integer default 8) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['logistics:view','logistics:manage']);r jsonb;begin
 if p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100 or length(coalesce(p_filters->>'search',''))>500
 or nullif(p_filters->>'from','')::date>nullif(p_filters->>'to','')::date then raise exception 'Invalid service trip filters';end if;
 with matching as materialized(select s.* from public.vehicle_service_trips s where s.tenant_id=t
 and (nullif(p_filters->>'vehicle_id','') is null or vehicle_id=(p_filters->>'vehicle_id')::uuid)
 and app_private.finance_search(concat_ws(' ',s.title,s.service_trip_id,s.expenses::text),coalesce(p_filters->>'search',''))
 and (nullif(p_filters->>'from','') is null or s.service_date>=(p_filters->>'from')::date)
 and (nullif(p_filters->>'to','') is null or s.service_date<=(p_filters->>'to')::date)
 and (nullif(p_filters->>'category_id','') is null or expenses @> jsonb_build_array(jsonb_build_object('category_id',p_filters->>'category_id')))),
 page as(select * from matching order by service_date desc,created_at desc,service_trip_id desc offset p_offset limit p_limit)
 select jsonb_build_object('total',(select count(*) from matching),'entries',coalesce((select jsonb_agg(app_private.service_json(t,service_trip_id) order by service_date desc,created_at desc,service_trip_id desc) from page),'[]')) into r;return r;
end $$;
create function public.save_service_trip(p_payload jsonb,p_request_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('logistics:manage');id uuid:=nullif(p_payload->>'service_trip_id','')::uuid;
 s public.vehicle_service_trips;prior public.finance_requests;body jsonb:=jsonb_build_object('action','service_save','actor',auth.uid(),'body',p_payload);
 r jsonb; x jsonb;c public.vehicle_expense_categories;expenses jsonb:='[]';total numeric:=0;a numeric;d date:=(p_payload->>'service_date')::date;
begin
 if p_request_id is null or jsonb_typeof(p_payload) is distinct from 'object' then raise exception 'Request ID and details are required';end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||p_request_id::text,0));select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload<>body then raise exception 'Request ID was already used with different details';end if;return prior.result;end if;
 if nullif(trim(p_payload->>'title'),'') is null or length(p_payload->>'title')>160 or d is null or not isfinite(d) or d>(now() at time zone 'Asia/Dhaka')::date then raise exception 'Enter a title and a valid past/current service date';end if;
 perform 1 from public.vehicles where tenant_id=t and vehicle_id=(p_payload->>'vehicle_id')::uuid for update;if not found then raise exception 'Vehicle not found';end if;
 if id is not null then select * into s from public.vehicle_service_trips where tenant_id=t and service_trip_id=id for update;
 if not found or s.vehicle_id<>(p_payload->>'vehicle_id')::uuid then raise exception 'Service trip not found';end if;
 if s.finalized_at is not null then raise exception 'Finalized service trip is locked';end if;
 if s.revision is distinct from (p_payload->>'revision')::integer then raise exception 'Service trip changed. Reload before saving.';end if;end if;
 if jsonb_typeof(p_payload->'expenses') is distinct from 'array' or jsonb_array_length(p_payload->'expenses')>100 then raise exception 'Use up to 100 expense entries';end if;
 for x in select value from jsonb_array_elements(p_payload->'expenses') loop
 select * into c from public.vehicle_expense_categories where tenant_id=t and category_id=(x->>'category_id')::uuid for share;
 if not found or (not c.is_active and not exists(select 1 from jsonb_array_elements(coalesce(s.expenses,'[]')) old where old->>'category_id'=c.category_id::text)) then raise exception 'Select an active expense category belonging to this business';end if;
 a:=app_private.purchase_money((x->>'amount')::numeric);if a<=0 or length(coalesce(x->>'description',''))>1000 then raise exception 'Each expense needs a positive amount and a description up to 1000 characters';end if;
 total:=total+a;expenses:=expenses||jsonb_build_array(jsonb_build_object('category_id',c.category_id,'category_name',c.name,'amount',a,'description',coalesce(x->>'description','')));
 end loop;
 if id is null then insert into public.vehicle_service_trips(tenant_id,vehicle_id,title,service_date,expenses,total_cost,created_by)
 values(t,(p_payload->>'vehicle_id')::uuid,trim(p_payload->>'title'),d,expenses,total,auth.uid()) returning service_trip_id into id;
 else update public.vehicle_service_trips set title=trim(p_payload->>'title'),service_date=d,expenses=expenses,total_cost=total,revision=revision+1,updated_at=clock_timestamp() where tenant_id=t and service_trip_id=id;end if;
 -- Reclassification/date edits reverse old incurred rows then add the new breakdown.
 insert into public.operating_cost_events(tenant_id,service_trip_id,category,amount,incurred_on,created_by,details)
 select t,id,value->>'category_name',-(value->>'amount')::numeric,s.service_date,auth.uid(),jsonb_build_object('source','service_edit') from jsonb_array_elements(coalesce(s.expenses,'[]'));
 insert into public.operating_cost_events(tenant_id,service_trip_id,category,amount,incurred_on,created_by,details)
 select t,id,value->>'category_name',(value->>'amount')::numeric,d,auth.uid(),jsonb_build_object('source','service_save') from jsonb_array_elements(expenses);
 insert into public.service_trip_activity(tenant_id,service_trip_id,action,details,created_by) values(t,id,'saved',jsonb_build_object('before',to_jsonb(s),'after',app_private.service_json(t,id)),auth.uid());
 r:=jsonb_build_object('service_trip_id',id);insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,r,auth.uid());return r;
end $$;
create function public.record_operating_payment(p_payload jsonb,p_request_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('logistics:manage');prior public.finance_requests;body jsonb:=jsonb_build_object('action','operating_payment','actor',auth.uid(),'body',p_payload);
 tid uuid:=nullif(p_payload->>'transit_id','')::uuid;sid uuid:=nullif(p_payload->>'service_trip_id','')::uuid;
 kind text:=p_payload->>'kind';original public.operating_payments;tr public.transits;s public.vehicle_service_trips;
 r jsonb;x jsonb;w public.wallets;a numeric;total numeric:=0;id uuid;ids jsonb:='[]';d date:=(p_payload->>'payment_date')::date;due numeric;
begin
 if p_request_id is null or jsonb_typeof(p_payload) is distinct from 'object' then raise exception 'Request ID and payment details are required';end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||p_request_id::text,0));select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload<>body then raise exception 'Request ID was already used with different details';end if;return prior.result;end if;
 if num_nonnulls(tid,sid)<>1 or kind is null or kind not in ('expense','expense_return','client_receipt','client_refund') or d is null or not isfinite(d) or d>(now() at time zone 'Asia/Dhaka')::date then raise exception 'Choose a trip, payment kind and valid past/current date';end if;
 if tid is not null then select * into tr from public.transits where tenant_id=t and transit_id=tid for update;
 if not found or tr.closed_at is not null then raise exception 'Select a transit with open accounting';end if;
 if kind in ('client_receipt','client_refund') and tr.purchase_id is not null then raise exception 'Purchase transport revenue is an internal allocation, never a cash collection';end if;
 if kind='client_receipt' and tr.status='cancelled' then raise exception 'Cancelled transits only accept client refunds';end if;
 else select * into s from public.vehicle_service_trips where tenant_id=t and service_trip_id=sid for update;
 if not found or s.finalized_at is not null then raise exception 'Select an unfinalized service trip';end if;
 if kind in ('client_receipt','client_refund') then raise exception 'Service trips have expenses only';end if;end if;
 if jsonb_typeof(p_payload->'payments') is distinct from 'array' or jsonb_array_length(p_payload->'payments') not between 1 and 20 then raise exception 'Use one to twenty payment entries';end if;
 if kind='expense_return' then
 select op.* into original from public.operating_payments op where op.tenant_id=t and op.payment_id=(p_payload->>'return_of')::uuid and op.kind='expense' for update;
 if not found or original.transit_id is distinct from tid or original.service_trip_id is distinct from sid then raise exception 'Select an original payment for this trip';end if;
 if d<original.payment_date then raise exception 'Return date cannot precede the original payment';end if;
 due:=original.amount-coalesce((select sum(amount) from public.operating_payments where tenant_id=t and return_of=original.payment_id),0);
 elsif kind='client_receipt' then due:=tr.transport_fee-app_private.transit_client_paid(t,tid);
 elsif kind='client_refund' then due:=app_private.transit_client_paid(t,tid);
 elsif tid is not null then due:=tr.total_cost-tr.driver_cost-tr.helper_cost-app_private.transit_operating_paid(t,tid);end if;
 perform 1 from public.wallets where tenant_id=t and wallet_id in(select (value->>'wallet_id')::uuid from jsonb_array_elements(p_payload->'payments')) order by wallet_id for update;
 for x in select value from jsonb_array_elements(p_payload->'payments') loop
 if jsonb_typeof(x->'amount') is distinct from 'number' then raise exception 'Payment amounts must be numbers';end if;
 a:=app_private.purchase_money((x->>'amount')::numeric);if a<=0 or length(coalesce(x->>'reference',''))>200 then raise exception 'Enter a positive amount and a reference up to 200 characters';end if;
 total:=total+a;if due is not null and total>due then raise exception 'Payment exceeds the outstanding balance';end if;
 select * into w from public.wallets where tenant_id=t and wallet_id=(x->>'wallet_id')::uuid and is_active;
 if not found then raise exception 'Select an active wallet belonging to this business';end if;
 if kind='expense_return' and w.wallet_id<>original.wallet_id then raise exception 'Returned funds must use the original wallet';end if;
 insert into public.operating_payments(tenant_id,transit_id,service_trip_id,kind,wallet_id,wallet_name,method,amount,reference,payment_date,operation_id,return_of,created_by)
 values(t,tid,sid,kind,w.wallet_id,w.name,w.kind,a,coalesce(x->>'reference',''),d,p_request_id,case when kind='expense_return' then original.payment_id end,auth.uid()) returning payment_id into id;
 insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description,operation_id,operating_payment_id)
 values(t,w.wallet_id,case when kind in ('expense','client_refund') then -a else a end,
 case when sid is not null then 'vehicle_service_' else 'transit_' end||kind,coalesce(sid,tid),
 case when sid is not null then 'Vehicle service trip · '||s.title else 'Transit · '||coalesce(tr.client_name,'Purchase shipment') end||' · '||replace(kind,'_',' '),p_request_id,id);
 ids:=ids||jsonb_build_array(id);
 end loop;
 if tid is not null then update public.transits set revision=revision+1,updated_at=clock_timestamp() where tenant_id=t and transit_id=tid;
 else update public.vehicle_service_trips set revision=revision+1,updated_at=clock_timestamp() where tenant_id=t and service_trip_id=sid;
 insert into public.service_trip_activity(tenant_id,service_trip_id,action,details,created_by) values(t,sid,'payment',p_payload||jsonb_build_object('payment_ids',ids),auth.uid());end if;
 r:=jsonb_build_object('payment_ids',ids);insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,r,auth.uid());return r;
end $$;
create function public.finalize_service_trip(p_service_trip_id uuid,p_revision integer,p_request_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('logistics:manage');s public.vehicle_service_trips;prior public.finance_requests;
 body jsonb:=jsonb_build_object('action','finalize_service','actor',auth.uid(),'id',p_service_trip_id,'revision',p_revision);r jsonb;begin
 if p_request_id is null then raise exception 'Request ID is required';end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||p_request_id::text,0));select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload<>body then raise exception 'Request ID was already used with different details';end if;return prior.result;end if;
 select * into s from public.vehicle_service_trips where tenant_id=t and service_trip_id=p_service_trip_id for update;
 if not found then raise exception 'Service trip not found';end if;
 if s.finalized_at is null then
 if s.revision is distinct from p_revision then raise exception 'Service trip changed. Reload before finalizing.';end if;
 if s.total_cost<>app_private.service_paid(t,p_service_trip_id) then raise exception 'Settle all outstanding costs or return surplus advances before finalizing';end if;
 update public.vehicle_service_trips set finalized_at=clock_timestamp(),revision=revision+1,updated_at=clock_timestamp() where tenant_id=t and service_trip_id=p_service_trip_id;
 insert into public.service_trip_activity(tenant_id,service_trip_id,action,details,created_by) values(t,p_service_trip_id,'finalized',jsonb_build_object('total',s.total_cost),auth.uid());end if;
 r:=jsonb_build_object('service_trip_id',p_service_trip_id);insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,r,auth.uid());return r;
end $$;
create function public.get_operating_payments(p_transit_id uuid default null,p_service_trip_id uuid default null,p_offset integer default 0,p_limit integer default 8) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['logistics:view','logistics:manage']);r jsonb;begin
 if num_nonnulls(p_transit_id,p_service_trip_id)<>1 or p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid payment history page';end if;
 with rows as materialized(select p.*,coalesce((select sum(amount) from public.operating_payments rr where rr.tenant_id=t and rr.return_of=p.payment_id),0) returned
 from public.operating_payments p where p.tenant_id=t and (p.transit_id=p_transit_id or p.service_trip_id=p_service_trip_id)),
 page as(select * from rows order by created_at desc,payment_id desc offset p_offset limit p_limit)
 select jsonb_build_object('total',(select count(*) from rows),'entries',coalesce((select jsonb_agg(to_jsonb(p) order by created_at desc,payment_id desc) from page p),'[]')) into r;return r;
end $$;
create function public.get_service_trip_activity(p_service_trip_id uuid,p_offset integer default 0,p_limit integer default 8) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['logistics:view','logistics:manage']);r jsonb;begin
 if p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid activity page';end if;
 select jsonb_build_object('total',(select count(*) from public.service_trip_activity where tenant_id=t and service_trip_id=p_service_trip_id),
 'entries',coalesce((select jsonb_agg(to_jsonb(a) order by created_at desc,activity_id desc) from(select * from public.service_trip_activity where tenant_id=t and service_trip_id=p_service_trip_id order by created_at desc,activity_id desc offset p_offset limit p_limit)a),'[]')) into r;return r;
end $$;
create or replace function app_private.transit_json(t uuid,id uuid) returns jsonb language sql stable set search_path='' as $$
 select to_jsonb(tr)||jsonb_build_object('vehicle_name',v.name,'driver_paid',app_private.transit_employee_paid(t,id,'driver'),
 'helper_paid',app_private.transit_employee_paid(t,id,'helper'),'operating_paid',app_private.transit_operating_paid(t,id),
 'client_paid',app_private.transit_client_paid(t,id),'revenue',case when tr.status='cancelled' then 0 else tr.transport_fee end,
 'profit',case when tr.status='cancelled' then 0 else tr.transport_fee end-tr.total_cost,
 'outstanding',greatest(0,tr.driver_cost-app_private.transit_employee_paid(t,id,'driver'))+greatest(0,tr.helper_cost-app_private.transit_employee_paid(t,id,'helper'))+
 greatest(0,tr.total_cost-tr.driver_cost-tr.helper_cost-app_private.transit_operating_paid(t,id)),
 'purchase_refund_due',p.refund_due,'purchase_financial_closed_at',p.financial_closed_at)
 from public.transits tr join public.vehicles v using(tenant_id,vehicle_id) left join public.purchases p on p.tenant_id=t and p.purchase_id=tr.purchase_id where tr.tenant_id=t and tr.transit_id=id;
$$;
create or replace function public.transition_transit(p_transit_id uuid,p_action text,p_revision integer) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('logistics:manage');tr public.transits;pid uuid;begin
 select purchase_id into pid from public.transits where tenant_id=t and transit_id=p_transit_id;
 if pid is not null then perform 1 from public.purchases where tenant_id=t and purchase_id=pid for update;end if;
 select * into tr from public.transits where tenant_id=t and transit_id=p_transit_id;if not found then raise exception 'Transit not found';end if;
 perform 1 from public.vehicles where tenant_id=t and vehicle_id=tr.vehicle_id for update;
 select * into tr from public.transits where tenant_id=t and transit_id=p_transit_id for update;
 if p_action is null or p_action not in ('complete','return','cancel') then raise exception 'Invalid transit action';end if;
 if p_action='complete' and tr.closed_at is not null or p_action='cancel' and tr.status='cancelled' or p_action='return' and tr.status='returned' then return jsonb_build_object('already_applied',true);end if;
 if tr.closed_at is not null then raise exception 'Completed transit is locked';end if;
 if p_revision is distinct from tr.revision then raise exception 'Transit changed. Reload before continuing.';end if;
 if pid is not null and (p_action in ('return','cancel') or tr.status='active') then raise exception 'Receive or cancel this shipment in Purchases before completing its transit';end if;
 if p_action='return' and tr.status<>'active' then raise exception 'Only an active journey can return';end if;
 if p_action='complete' then
 if tr.driver_cost>app_private.transit_employee_paid(t,p_transit_id,'driver') or tr.helper_cost>app_private.transit_employee_paid(t,p_transit_id,'helper') or
 tr.total_cost-tr.driver_cost-tr.helper_cost>app_private.transit_operating_paid(t,p_transit_id) then raise exception 'Settle all outstanding transit obligations before completing';end if;
 if tr.status='cancelled' and app_private.transit_client_paid(t,p_transit_id)>0 then raise exception 'Refund outstanding client collections before completing';end if;
 update public.transits set status=case when status='cancelled' then status else 'completed' end,closed_at=clock_timestamp(),revision=revision+1,updated_at=clock_timestamp() where tenant_id=t and transit_id=p_transit_id;
 else update public.transits set status=case when p_action='cancel' then 'cancelled'::public.transit_status else 'returned'::public.transit_status end,revision=revision+1,updated_at=clock_timestamp() where tenant_id=t and transit_id=p_transit_id;end if;
 if not exists(select 1 from public.transits where tenant_id=t and vehicle_id=tr.vehicle_id and status='active') and not exists(select 1 from public.purchases where tenant_id=t and vehicle_id=tr.vehicle_id and status='in_transit') then update public.vehicles set status='idle',updated_at=clock_timestamp() where tenant_id=t and vehicle_id=tr.vehicle_id;end if;
 if pid is not null then insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details) values(t,pid,'transit_closed',auth.uid(),jsonb_build_object('transit_id',p_transit_id,'operating_cost',tr.total_cost));end if;
 return jsonb_build_object('transit_id',p_transit_id);
end $$;
-- Guard changes against already-settled costs. Save and payment take the same trip lock.
create function app_private.guard_transit_operating_costs() returns trigger language plpgsql set search_path='' as $$
begin
 if new.total_cost-new.driver_cost-new.helper_cost<app_private.transit_operating_paid(new.tenant_id,new.transit_id) then raise exception 'Costs cannot fall below recorded operating payments; return funds first';end if;
 return new;
end $$;
create trigger guard_transit_operating_costs before update of total_cost,driver_cost,helper_cost on public.transits for each row execute function app_private.guard_transit_operating_costs();
-- Read-only audit access; old virtual records never become current wallet cash.
create function public.get_financial_source_archive(p_reference_id uuid,p_offset integer default 0,p_limit integer default 10) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['finance:view','finance:manage','purchases:view','purchases:manage','payroll:view','payroll:pay']);r jsonb;begin
 if p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid archive page';end if;
 if not app_private.has_any_permission(array['finance:view','finance:manage']) and not (
 app_private.has_any_permission(array['purchases:view','purchases:manage']) and exists(select 1 from public.purchases where tenant_id=t and purchase_id=p_reference_id)
 or app_private.has_any_permission(array['payroll:view','payroll:pay']) and exists(select 1 from public.employee_payments where tenant_id=t and payment_id=p_reference_id)) then raise exception 'Archive is not authorized' using errcode='42501';end if;
 with rows as materialized(select * from public.financial_source_archive where tenant_id=t and reference_id=p_reference_id),page as(select * from rows order by archived_at,archive_id offset p_offset limit p_limit)
 select jsonb_build_object('total',(select count(*) from rows),'entries',coalesce((select jsonb_agg(to_jsonb(p)) from page p),'[]')) into r;return r;
end $$;
do $$ declare tbl text;begin
 foreach tbl in array array['vehicle_expense_categories','vehicle_service_trips','operating_payments','operating_cost_events','service_trip_activity'] loop
 execute format('alter table public.%I enable row level security',tbl);execute format('revoke all on public.%I from public,anon,authenticated',tbl);execute format('alter table public.%I owner to postgres',tbl);end loop;
 foreach tbl in array array['operating_payments','operating_cost_events','service_trip_activity'] loop
 execute format('create trigger immutable_operating_record before update or delete on public.%I for each row execute function app_private.immutable_finance_record()',tbl);end loop;
end $$;

alter table public.purchase_refund_obligations drop column logistics_amount,drop column credit_business;
alter table public.purchase_refund_obligations drop constraint purchase_refund_obligations_component_check;
alter table public.purchase_refund_obligations add constraint purchase_refund_obligations_component_check check(component in ('purchase','company','labour','transport','legacy','transport_income'));
alter table public.wallets drop constraint wallet_type_valid,drop constraint wallet_kind_valid;
alter table public.wallets add constraint wallet_type_valid check(type in ('dealership','cash','bkash','nagad','custom')),
 add constraint wallet_kind_valid check(kind in ('cash','bank','bkash','nagad','other'));
-- Unknown historical cash attribution cannot offer a fictional wallet return.
do $$ declare s text;needle text:='p.reversal_of is null and p.source_snapshot is null and not exists(';begin
 s:=pg_get_functiondef('public.get_employee_activity(jsonb,integer,integer)'::regprocedure);
 if position(needle in s)=0 then raise exception 'Unexpected employee reversal contract';end if;
 execute replace(s,needle,'p.reversal_of is null and p.source_snapshot is null and not exists(select 1 from public.employee_payment_entries unknown_entry where unknown_entry.tenant_id=t and unknown_entry.payment_id=p.payment_id and unknown_entry.wallet_id is null) and not exists(');
end $$;

CREATE OR REPLACE FUNCTION app_private.receive_sale_payments(t uuid, sid uuid, entries jsonb, phase text, op uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare s public.sales; x jsonb; w public.wallets; paid numeric:=0; amount numeric; pid uuid;
begin
 select * into s from public.sales where tenant_id=t and sale_id=sid for update;
 if not found or s.status<>'completed' then raise exception 'Sale does not support payment collection'; end if;
 if entries is null or jsonb_typeof(entries)<>'array' or jsonb_array_length(entries)>20 then raise exception 'Use up to 20 payment entries'; end if;
 -- Lock only participating wallets, in the same order as purchase funding.
 perform 1 from public.wallets where tenant_id=t and wallet_id in (select (value->>'wallet_id')::uuid from jsonb_array_elements(entries)) order by wallet_id for update;
 for x in select value from jsonb_array_elements(entries) loop
  if jsonb_typeof(x)<>'object' or jsonb_typeof(x->'amount') is distinct from 'number' then raise exception 'Payment amounts must be numbers'; end if;
  amount:=app_private.purchase_money((x->>'amount')::numeric);
  if amount<=0 or amount<>(x->>'amount')::numeric then raise exception 'Payment must be positive with at most two decimal places'; end if;
  select * into w from public.wallets where tenant_id=t and wallet_id=(x->>'wallet_id')::uuid and is_active ;
  if not found then raise exception 'Select an active payment wallet belonging to this business'; end if;
  if length(coalesce(x->>'reference',''))>200 then raise exception 'Payment reference is too long'; end if;
  paid:=paid+amount;
  if paid+s.paid_amount>(s.total_amount+s.additional_charges) then raise exception 'Payments exceed the remaining sale balance'; end if;
  insert into public.sale_payments(tenant_id,sale_id,wallet_id,wallet_name,method,amount,phase,operation_id,reference,created_by)
   values(t,sid,w.wallet_id,w.name,w.kind,amount,phase,op,coalesce(x->>'reference',''),auth.uid()) returning payment_id into pid;
  insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description,operation_id,payment_id)
   values(t,w.wallet_id,amount,case phase when 'checkout' then 'pos_sale_income' else 'customer_collection' end,sid,
    'Sale #'||left(sid::text,8)||' · '||w.name,op,pid);
  insert into public.customer_transactions(tenant_id,customer_id,type,amount,reference_id,created_by,payment_id)
   values(t,s.customer_id,'payment_receipt',amount,sid,auth.uid(),pid);
 end loop;
 update public.sales set paid_amount=paid_amount+paid where tenant_id=t and sale_id=sid;
 return paid;
end $function$;


do $$ declare r record;begin
 for r in select p.oid,n.nspname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname in ('public','app_private') and p.proname in (
 'initialize_vehicle_categories','vehicle_categories_created','get_vehicle_expense_categories','save_vehicle_expense_category',
 'transit_operating_paid','service_paid','transit_client_paid','transit_expense_breakdown','capture_transit_costs','service_json',
 'get_service_trip','get_service_trip_directory','save_service_trip','record_operating_payment','finalize_service_trip',
 'get_operating_payments','get_service_trip_activity','guard_transit_operating_costs','get_financial_source_archive') loop
 execute format('alter function %s owner to postgres',r.oid::regprocedure);execute format('revoke all on function %s from public,anon,authenticated',r.oid::regprocedure);
 if r.nspname='public' then execute format('grant execute on function %s to authenticated',r.oid::regprocedure);end if;end loop;
end $$;
notify pgrst,'reload schema';

CREATE OR REPLACE FUNCTION public.get_transit_directory(p_filters jsonb DEFAULT '{}'::jsonb, p_offset integer DEFAULT 0, p_limit integer DEFAULT 25)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_any_permission(array['logistics:view','logistics:manage','employees:view','employees:manage','payroll:view','payroll:pay']);
 eid uuid:=nullif(p_filters->>'employee_id','')::uuid; vid uuid:=nullif(p_filters->>'vehicle_id','')::uuid;
 state text:=coalesce(p_filters->>'status','all'); ordering text:=coalesce(p_filters->>'sort','date_desc');
 f date:=nullif(p_filters->>'from','')::date; until date:=nullif(p_filters->>'to','')::date; result jsonb;
begin
 if not app_private.has_any_permission(array['logistics:view','logistics:manage']) and eid is null then raise exception 'Choose an employee'; end if;
 if p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100 or length(coalesce(p_filters->>'search',''))>500 or f>until
  or state not in ('all','active','returned','completed','cancelled','outstanding') or ordering not in ('date_desc','date_asc') or coalesce(p_filters->>'type','all') not in ('all','purchase','custom') then raise exception 'Invalid transit filters'; end if;
 with matching as materialized (select tr.transit_id,tr.created_at from public.transits tr join public.vehicles v using(tenant_id,vehicle_id)
  where tr.tenant_id=t and (vid is null or tr.vehicle_id=vid) and (eid is null or eid in (tr.driver_employee_id,tr.helper_employee_id))
   and (f is null or tr.created_at>=f::timestamp at time zone 'Asia/Dhaka') and (until is null or tr.created_at<(until+1)::timestamp at time zone 'Asia/Dhaka')
   and (coalesce(p_filters->>'type','all')='all' or p_filters->>'type'='purchase' and tr.purchase_id is not null or p_filters->>'type'='custom' and tr.purchase_id is null)
   and (state='all' or state='active' and tr.status='active' or state='returned' and tr.status='returned'
    or state='completed' and tr.closed_at is not null or state='cancelled' and tr.status='cancelled'
    or state='outstanding' and tr.closed_at is null and (tr.driver_cost>app_private.transit_employee_paid(t,tr.transit_id,'driver') or tr.helper_cost>app_private.transit_employee_paid(t,tr.transit_id,'helper') or tr.total_cost-tr.driver_cost-tr.helper_cost>app_private.transit_operating_paid(t,tr.transit_id)))
   and (nullif(p_filters->>'expense_category','') is null or exists(select 1 from app_private.transit_expense_breakdown(tr) c where c.category=p_filters->>'expense_category' and c.amount>0))
   and app_private.finance_search(concat_ws(' ',v.name,v.serial_no,tr.transit_id,tr.client_name,tr.destination,tr.description,tr.driver_name,tr.helper_name),coalesce(p_filters->>'search',''))),
 page as (select * from matching order by case when ordering='date_desc' then created_at end desc,case when ordering='date_asc' then created_at end,transit_id desc offset p_offset limit p_limit)
 select jsonb_build_object('total',(select count(*) from matching),'entries',coalesce((select jsonb_agg(app_private.transit_json(t,p.transit_id) order by case when ordering='date_desc' then p.created_at end desc,case when ordering='date_asc' then p.created_at end,p.transit_id desc) from page p),'[]')) into result;
 return result;
end $function$;

CREATE OR REPLACE FUNCTION public.get_logistics_summary(p_vehicle_id uuid DEFAULT NULL::uuid, p_employee_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_any_permission(array['logistics:view','logistics:manage','employees:view','employees:manage','payroll:view','payroll:pay']); result jsonb;
begin
 if not app_private.has_any_permission(array['logistics:view','logistics:manage']) and p_employee_id is null then raise exception 'Choose an employee'; end if;
 with trips as (select tr.*,case when p_employee_id is null then tr.driver_cost+tr.helper_cost
  when p_employee_id=tr.driver_employee_id then tr.driver_cost else tr.helper_cost end earnings,
  app_private.transit_employee_paid(t,tr.transit_id,case when p_employee_id is null then null when p_employee_id=tr.driver_employee_id then 'driver' else 'helper' end) paid
  from public.transits tr where tr.tenant_id=t and (p_vehicle_id is null or tr.vehicle_id=p_vehicle_id) and (p_employee_id is null or p_employee_id in (tr.driver_employee_id,tr.helper_employee_id)))
 select jsonb_build_object('transits',count(*),'active',count(*) filter(where status='active'),'awaiting_completion',count(*) filter(where closed_at is null),
  'earnings',coalesce(sum(earnings),0),'paid',coalesce(sum(paid),0),'outstanding',coalesce(sum(greatest(0,earnings-paid)) filter(where closed_at is null),0),
  'transport_fees',coalesce(sum(transport_fee) filter(where status<>'cancelled'),0),'operating_costs',coalesce(sum(total_cost),0),
  'profit',coalesce(sum(case when status='cancelled' then 0 else transport_fee end-total_cost),0),
  'expense_outstanding',coalesce(sum(greatest(0,total_cost-driver_cost-helper_cost-app_private.transit_operating_paid(t,transit_id))),0),
  'service_expenses',(select coalesce(sum(total_cost),0) from public.vehicle_service_trips where tenant_id=t and (p_vehicle_id is null or vehicle_id=p_vehicle_id)),

  'vehicles',(select count(*) from public.vehicles where tenant_id=t),'home',(select count(*) from public.vehicles where tenant_id=t and status='idle')) into result from trips;
 return result||jsonb_build_object('assignments',(select count(*) from public.vehicle_assignments where tenant_id=t and employee_id=p_employee_id),'current_vehicle',(select v.name from public.vehicle_assignments a join public.vehicles v using(tenant_id,vehicle_id) where a.tenant_id=t and a.employee_id=p_employee_id and a.ended_at is null));
end $function$;

CREATE OR REPLACE FUNCTION public.save_transit_costs(p_transit_id uuid, p_costs jsonb, p_revision integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_permission('logistics:manage'); tr public.transits; pid uuid; x jsonb; total numeric;
  driver numeric:=app_private.purchase_money((p_costs->>'driver_cost')::numeric);
  helper numeric:=app_private.purchase_money((p_costs->>'helper_cost')::numeric);
  oil numeric:=app_private.purchase_money((p_costs->>'oil_cost')::numeric);
  others numeric:=app_private.purchase_money((p_costs->>'others_cost')::numeric);
  extra jsonb:=coalesce(p_costs->'additional_costs','[]');
begin
  select purchase_id into pid from public.transits where tenant_id=t and transit_id=p_transit_id;
  if pid is not null then perform 1 from public.purchases where tenant_id=t and purchase_id=pid for update; end if;
  select * into tr from public.transits where tenant_id=t and transit_id=p_transit_id for update;
  if not found then raise exception 'Transit not found'; end if;
  if tr.closed_at is not null then raise exception 'Closed transit costs are locked'; end if;
  if p_revision is distinct from tr.revision then raise exception 'Transit changed. Reload before saving.' using errcode='P0001'; end if;
  if jsonb_typeof(extra)<>'array' or jsonb_array_length(extra)>100 then raise exception 'Additional costs must be an array'; end if;
  total:=driver+helper+oil+others;
  for x in select value from jsonb_array_elements(extra) loop
    if nullif(trim(x->>'name'),'') is null then raise exception 'Additional cost name is required'; end if;
    if length(x->>'name')>80 then raise exception 'Cost name is too long';end if;
    if nullif(x->>'category_id','') is not null and not exists(select 1 from public.vehicle_expense_categories c where c.tenant_id=t and c.category_id=(x->>'category_id')::uuid and c.name=x->>'name' and (c.is_active or tr.additional_costs @> jsonb_build_array(jsonb_build_object('category_id',x->>'category_id')))) then raise exception 'Expense category changed. Reload before saving.';end if;
    total:=total+app_private.purchase_money((x->>'amount')::numeric);
  end loop;
  update public.transits set driver_cost=driver,helper_cost=helper,oil_cost=oil,others_cost=others,
    additional_costs=extra,total_cost=total,updated_at=now(),revision=revision+1 where tenant_id=t and transit_id=p_transit_id;
  if pid is not null then
    insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details)
      values(t,pid,'logistics_updated',auth.uid(),jsonb_build_object('transit_id',p_transit_id,'operating_cost',total,'before',to_jsonb(tr),'after',(select to_jsonb(h) from public.transits h where h.tenant_id=t and h.transit_id=p_transit_id)));
  end if;
  return jsonb_build_object('transit_id',p_transit_id);
end $function$;

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
    left join public.user_profiles u on u.tenant_id=a.tenant_id and u.user_id=a.created_by
    where a.tenant_id=t and a.purchase_id=p_purchase_id
  ), ledger as materialized (
    select x.transaction_id, x.purchase_payment_id, x.wallet_name_snapshot wallet_name,
      x.wallet_method_snapshot method, x.amount, x.type, x.created_at, x.entry_no,
      x.operation_id, x.description, x.counterparty_wallet_id,
      pp.reference, pp.component, pp.obligation_id, u.full_name actor,
      linked.activity_id
    from public.wallet_transactions x
    left join public.purchase_payments pp on pp.tenant_id=t and pp.payment_id=x.purchase_payment_id
    left join public.user_profiles u on u.tenant_id=t and u.user_id=x.created_by
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
  select e.body from (
   select * from events union all
   select coalesce((a.record->>'created_at')::timestamptz,a.archived_at),a.source_id,0::bigint,
    jsonb_build_object('activity_id',a.source_id,'action','archived_accounting_evidence','actor_name','Historical record',
      'created_at',coalesce(a.record->>'created_at',a.archived_at::text),'details',jsonb_build_object('reason',a.reason,'original',a.record),'wallet_entries','[]'::jsonb)
   from public.financial_source_archive a where a.tenant_id=t and a.reference_id=p_purchase_id and a.source_table='wallet_transactions'
  ) e order by e.created_at,e.entry_no,e.id;
end $function$;
