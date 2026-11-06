-- Purchase history stores operational messages. Payment and refund history reads the original sources.
alter table public.purchase_activity add column message text;

create function app_private.purchase_edit_message(t uuid, old_header jsonb, new_header jsonb, old_items jsonb, new_items jsonb)
returns text language sql stable set search_path='' as $$
 with header_changes as (
   select f.position, case
     when f.field='notes' then 'Purchase notes updated.'
     when f.field='vehicle_id' then format('Vehicle assignment changed from %s to %s.',
       coalesce(old_vehicle.name, 'unassigned'), coalesce(new_vehicle.name, 'unassigned'))
     else format('%s changed from Tk %s to Tk %s.', f.label, old_header->>f.field, new_header->>f.field)
   end as message
   from (values (1,'vehicle_id','Vehicle'),(2,'transport_cost','Transport cost'),
     (3,'labour_cost','Labour cost'),(4,'rebate_amount','Company rebate'),(5,'notes','Notes')) f(position,field,label)
   left join public.vehicles old_vehicle on old_vehicle.tenant_id=t
     and old_vehicle.vehicle_id::text=old_header->>f.field and f.field='vehicle_id'
   left join public.vehicles new_vehicle on new_vehicle.tenant_id=t
     and new_vehicle.vehicle_id::text=new_header->>f.field and f.field='vehicle_id'
   where old_header ? f.field and new_header ? f.field
     and nullif(old_header->>f.field,'') is distinct from nullif(new_header->>f.field,'')
 ), lines as (
   select coalesce(o.item_id,n.item_id) item_id, o.item_id is null added, n.item_id is null removed,
     o.quantity old_quantity, n.quantity new_quantity, o.unit_price old_price, n.unit_price new_price,
     o.bottle_quantity old_bottles, n.bottle_quantity new_bottles,
     o.bottle_unit_price old_bottle_price, n.bottle_unit_price new_bottle_price
   from jsonb_to_recordset(old_items) o(item_id uuid, quantity integer, unit_price numeric,
     bottle_quantity integer, bottle_unit_price numeric)
   full join jsonb_to_recordset(new_items) n(item_id uuid, quantity integer, unit_price numeric,
     bottle_quantity integer, bottle_unit_price numeric) using(item_id)
   where old_items is not null and new_items is not null
 ), line_changes as (
   select l.item_id, f.position, concat(product.label, ' — ', f.message) message
   from lines l
   left join public.items i on i.tenant_id=t and i.item_id=l.item_id
   left join public.lpg_brands b on b.tenant_id=t and b.brand_id=i.brand_id
   cross join lateral (select coalesce(i.product_name,nullif(concat_ws(' ',b.brand_name,i.size_kg||' kg',i.mouth_size),''),'Product') label,
     coalesce(i.business_category,new_header->>'business_category','lpg')='lpg' as lpg) product
   cross join lateral (values
     (1, case when l.added then concat(
       format('added %s %s at Tk %s each.',l.new_quantity,case when product.lpg then 'Gas' else 'units' end,l.new_price),
       case when product.lpg and l.new_bottles>0 then format(' Added %s Bottle at Tk %s each.',l.new_bottles,l.new_bottle_price) end) end),
     (2, case when l.removed then format('removed %s %s%s.',l.old_quantity,case when product.lpg then 'Gas' else 'units' end,
       case when product.lpg and l.old_bottles>0 then format(' and %s Bottle',l.old_bottles) else '' end) end),
     (3, case when not (l.added or l.removed) and l.old_quantity is distinct from l.new_quantity then
       format('%s quantity changed from %s to %s.',case when product.lpg then 'Gas' else 'Product' end,l.old_quantity,l.new_quantity) end),
     (4, case when not (l.added or l.removed) and l.old_price is distinct from l.new_price then
       format('%s unit price changed from Tk %s to Tk %s.',case when product.lpg then 'Gas' else 'Product' end,l.old_price,l.new_price) end),
     (5, case when not (l.added or l.removed) and product.lpg and l.old_bottles is distinct from l.new_bottles then
       format('Bottle quantity changed from %s to %s.',l.old_bottles,l.new_bottles) end),
     (6, case when not (l.added or l.removed) and product.lpg and l.old_bottle_price is distinct from l.new_bottle_price then
       format('Bottle unit price changed from Tk %s to Tk %s.',l.old_bottle_price,l.new_bottle_price) end)
   ) f(position,message)
   where f.message is not null
 )
 select string_agg(changes.message, E'\n' order by changes.item_id nulls first, changes.position)
 from (
   select null::uuid item_id, h.position, h.message from header_changes h
   union all
   select l.item_id,l.position,l.message from line_changes l
 ) changes;
$$;
alter function app_private.purchase_edit_message(uuid,jsonb,jsonb,jsonb,jsonb) owner to postgres;
revoke all on function app_private.purchase_edit_message(uuid,jsonb,jsonb,jsonb,jsonb) from public,anon,authenticated,service_role;

-- A recorded payment/refund activity can be discarded only when its source
-- operation is still present. All journals, payments and wallet legs stay intact.
do $$
begin
  if exists (
    select 1 from public.purchase_activity a
    where a.action in ('payment_recorded','refund_recorded','paid')
      and not exists (
        select 1 from public.purchase_payments p where p.tenant_id=a.tenant_id and p.purchase_id=a.purchase_id
          and p.kind=case when a.action='refund_recorded' then 'refund' else 'payment' end
          and p.operation_id::text=a.details->>'operation_id'
      )
  ) then
    raise exception 'Purchase activity has financial history without a matching source operation';
  end if;
end
$$;

alter table public.purchase_activity disable trigger purchase_activity_immutable;
delete from public.purchase_activity
where action in ('payment_recorded','refund_recorded','paid','refund_completed','financially_closed');
delete from public.purchase_activity a
where a.action='cancellation_confirmed' and exists (
  select 1 from public.purchase_activity b
  where b.tenant_id=a.tenant_id and b.purchase_id=a.purchase_id and b.action='cancellation_initiated'
    and b.created_by is not distinct from a.created_by and b.created_at=a.created_at
);

update public.purchase_activity a set message=case a.action
  when 'updated' then app_private.purchase_edit_message(a.tenant_id,a.details->'before',a.details->'after',
    case when jsonb_typeof(a.details->'before_items')='array' then a.details->'before_items' end,
    case when jsonb_typeof(a.details->'items')='array' then a.details->'items' end)
  when 'created' then 'Purchase created.'
  when 'dispatched' then case when coalesce((a.details->>'empty_cylinders')::integer,0)>0
    then format('Vehicle dispatched. %s empty cylinders sent.',a.details->>'empty_cylinders') else 'Vehicle dispatched.' end
  when 'received' then 'Shipment received into inventory.'
  when 'cancellation_confirmed' then 'Purchase cancellation confirmed.'
  when 'cancellation_initiated' then 'Purchase cancelled.'
  when 'cancelled' then 'Purchase cancelled.'
  when 'logistics_updated' then 'Transit operating costs updated.'
  when 'transit_closed' then 'Transit completed.'
  when 'rebate_settled' then 'Company rebate settled.'
  when 'legacy_import' then 'Historical purchase imported.'
  else initcap(replace(a.action,'_',' '))||'.' end;
-- Historic revisions without comparable snapshots retain the fact that they were edited.
update public.purchase_activity set message='Purchase edited.' where message is null;
alter table public.purchase_activity enable trigger purchase_activity_immutable;
alter table public.purchase_activity alter column message set not null;
alter table public.purchase_activity alter column created_at set default clock_timestamp();
alter table public.purchase_activity add constraint purchase_activity_message_present check (btrim(message)<>'');

CREATE OR REPLACE FUNCTION app_private.action_create_purchase(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid := app_private.require_permission('purchases:manage'); id uuid; b uuid; request uuid; plant uuid; original jsonb;
begin perform app_private.require_permission('purchases:create');
  if p_payload - array['request_id','business_category','supplier_name','plant_id','vehicle_id','transport_cost','labour_cost','notes','items','rebate_amount'] <> '{}'::jsonb then raise exception 'Unsupported purchase fields';end if;
  if app_private.rebate_money(p_payload->'rebate_amount')>0 then perform app_private.require_permission('purchases:rebates');end if;
  request := (p_payload->>'request_id')::uuid;
  if request is null then raise exception 'Creation request ID is required'; end if;
  -- Transaction lock makes repeated creation requests return the same result.
  perform pg_advisory_xact_lock(hashtextextended(t::text || request::text,0));
  select purchase_id into id from public.purchases where tenant_id=t and request_id=request;
  if found then
    select request_payload into original from public.purchases where tenant_id=t and purchase_id=id;
    if original is not null and original is distinct from (p_payload-'request_id') then
      raise exception 'Purchase request ID was already used with different purchase details';
    end if;
    return jsonb_build_object('purchase_id',id);
  end if;
  if coalesce(p_payload->>'business_category','lpg') not in ('lpg','stove') then raise exception 'Invalid business category';end if;
  if p_payload->>'business_category'='stove' then
    insert into public.purchases(tenant_id,business_category,supplier_name,vehicle_id,status,transport_cost,labour_cost,notes,created_by,request_id,request_payload)
    values(t,'stove',trim(p_payload->>'supplier_name'),(p_payload->>'vehicle_id')::uuid,'created',app_private.purchase_money(coalesce((p_payload->>'transport_cost')::numeric,0)),app_private.purchase_money(coalesce((p_payload->>'labour_cost')::numeric,0)),p_payload->>'notes',auth.uid(),request,p_payload-'request_id') returning purchase_id into id;
    perform app_private.save_purchase_lines(t,id,p_payload->'items');perform app_private.recalculate_purchase(t,id);
    update public.purchases set rebate_amount=app_private.rebate_money(p_payload->'rebate_amount') where tenant_id=t and purchase_id=id;
    insert into public.purchase_activity(tenant_id,purchase_id,created_by,message)
    values(t,id,auth.uid(),'Purchase created.');
    return jsonb_build_object('purchase_id',id);
  end if;
  plant := (p_payload->>'plant_id')::uuid;
  select gp.brand_id into b from public.gas_plants gp join public.lpg_brands lb
    on lb.tenant_id=gp.tenant_id and lb.brand_id=gp.brand_id
    where gp.tenant_id=t and gp.plant_id=plant and gp.is_active and lb.is_active for share of gp,lb;
  if b is null then raise exception 'Select an active plant with an active company'; end if;
  if p_payload->>'vehicle_id' is not null and not exists(select 1 from public.vehicles where tenant_id=t and vehicle_id=(p_payload->>'vehicle_id')::uuid) then
    raise exception 'Vehicle not found'; end if;
  insert into public.purchases(tenant_id,plant_id,brand_id,vehicle_id,status,transport_cost,labour_cost,notes,created_by,request_id,request_payload)
  values(t,plant,b,(p_payload->>'vehicle_id')::uuid,'created',
    app_private.purchase_money(coalesce((p_payload->>'transport_cost')::numeric,0)),
    app_private.purchase_money(coalesce((p_payload->>'labour_cost')::numeric,0)),
    p_payload->>'notes',auth.uid(),request,p_payload-'request_id')
  returning purchase_id into id;
  perform app_private.save_purchase_lines(t,id,coalesce(p_payload->'items','[]'::jsonb));
  perform app_private.recalculate_purchase(t,id);
    update public.purchases set rebate_amount=app_private.rebate_money(p_payload->'rebate_amount') where tenant_id=t and purchase_id=id;
  insert into public.purchase_activity(tenant_id,purchase_id,created_by,message)
    values(t,id,auth.uid(),'Purchase created.');
  return jsonb_build_object('purchase_id',id);
end $function$;

CREATE OR REPLACE FUNCTION app_private.action_dispatch_purchase(p_purchase_id uuid, p_revision integer, p_dispatched_on date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid := app_private.require_permission('purchases:manage'); p public.purchases; tr public.vehicles; x record; dispatch_time timestamptz:=case when p_dispatched_on is null then clock_timestamp() else (p_dispatched_on+time '09:00') at time zone 'Asia/Dhaka' end;
begin perform app_private.require_permission('purchases:dispatch');
  select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id for update;
  if not found then raise exception 'Purchase not found'; end if; if p_dispatched_on is not null and (not isfinite(p_dispatched_on) or p_dispatched_on>(now() at time zone 'Asia/Dhaka')::date) then raise exception 'Invalid dispatch date';end if;
  if p.business_category='stove' and p.transport_cost=0 then raise exception 'Stove orders without internal transport are received directly';end if;
  if p.status='in_transit' or p.status='received' then return jsonb_build_object('purchase_id',p_purchase_id,'already_dispatched',true); end if;
  if p.status<>'created' then raise exception 'Only a Created purchase can be dispatched'; end if;
  if p_revision is distinct from p.revision then raise exception 'Purchase changed. Reload before dispatch.' using errcode='P0001'; end if;
  select * into tr from public.vehicles where tenant_id=t and vehicle_id=p.vehicle_id for update;
  if not found or tr.status<>'idle' then raise exception 'Select an idle truck before dispatch'; end if;
  if exists(select 1 from public.transits where tenant_id=t and vehicle_id=p.vehicle_id and status='active')
    or exists(select 1 from public.purchases where tenant_id=t and vehicle_id=p.vehicle_id and status='in_transit') then
    raise exception 'Vehicle already has an active shipment'; end if;
  if not exists(select 1 from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id) then raise exception 'Add at least one product before dispatch'; end if;
  perform 1 from public.employees where tenant_id=t and employee_id in(select employee_id from public.vehicle_assignments where tenant_id=t and vehicle_id=p.vehicle_id and ended_at is null) order by employee_id for update;
  if p.business_category='lpg' then perform 1 from public.gas_plants gp join public.lpg_brands b on b.tenant_id=gp.tenant_id and b.brand_id=gp.brand_id
    where gp.tenant_id=t and gp.plant_id=p.plant_id and gp.brand_id=p.brand_id and gp.is_active and b.is_active for share of gp,b;
  if not found then raise exception 'Plant company is unavailable'; end if;
  perform app_private.check_purchase_empties(t,(select jsonb_agg(to_jsonb(pi)) from public.purchase_items pi where tenant_id=t and purchase_id=p_purchase_id));end if;
  if p_dispatched_on<(now() at time zone 'Asia/Dhaka')::date then perform 1 from public.items where tenant_id=t order by item_id for update;end if;
 perform 1 from public.items where tenant_id=t and item_id in(select item_id from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id) order by item_id for update;
 if p_dispatched_on is null or p_dispatched_on=(now() at time zone 'Asia/Dhaka')::date then dispatch_time:=clock_timestamp();end if;
  -- Acquire stock locks in SKU order. Movement inserts apply the stock once.
  update public.purchase_items set empty_dispatched=case when p.business_category='lpg' then quantity-bottle_quantity else 0 end where tenant_id=t and purchase_id=p_purchase_id;
  for x in select i.item_id,i.empty_quantity,i.brand_id,sum(pi.empty_dispatched) outgoing
    from public.purchase_items pi join public.items i on i.tenant_id=pi.tenant_id and i.item_id=pi.item_id
    where pi.tenant_id=t and pi.purchase_id=p_purchase_id group by i.tenant_id,i.item_id order by i.item_id loop
    perform 1 from public.items where tenant_id=t and item_id=x.item_id for update;
    if p.business_category='lpg' and x.brand_id is distinct from p.brand_id then raise exception 'All products must belong to the plant company'; end if;
    if (select empty_quantity from public.items where tenant_id=t and item_id=x.item_id) < x.outgoing then
      raise exception 'Insufficient empty cylinder stock'; end if;
    if x.outgoing>0 then
      insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,empty_quantity_change,notes,created_by,created_at)
      values(t,x.item_id,'purchase','purchase_dispatch',p_purchase_id,-x.outgoing,'Empty cylinders dispatched to plant',auth.uid(),dispatch_time);
    end if;
  end loop;
  insert into public.transits(tenant_id,vehicle_id,purchase_id,status,transport_fee,created_at,client_name,destination)
    values(t,p.vehicle_id,p_purchase_id,'active',p.transport_cost,dispatch_time,case when p.business_category='stove' then p.supplier_name end,case when p.business_category='stove' then 'Stove supplier collection' end);
  update public.vehicles set status='going',updated_at=now() where tenant_id=t and vehicle_id=p.vehicle_id;
  update public.purchases set status='in_transit',dispatched_at=dispatch_time,payment_status=case when paid_amount>=payable_amount then 'paid' when paid_amount>0 then 'partial' else 'unpaid' end,paid_at=case when paid_amount>=payable_amount then now() end,updated_at=now(),revision=revision+1
    where tenant_id=t and purchase_id=p_purchase_id;
  perform app_private.settle_internal_transport(t,p_purchase_id,(dispatch_time at time zone 'Asia/Dhaka')::date); insert into public.purchase_activity(tenant_id,purchase_id,created_by,message)
    values(t,p_purchase_id,auth.uid(),case when p.business_category='lpg' then
      format('Vehicle dispatched. %s empty cylinders sent.', (select coalesce(sum(empty_dispatched),0) from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id))
      else 'Vehicle dispatched.' end);
  return jsonb_build_object('purchase_id',p_purchase_id);
end $function$;

CREATE OR REPLACE FUNCTION app_private.action_initiate_purchase_cancellation(p_purchase_id uuid, p_revision integer, p_confirmation text, p_request_id uuid)
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
 insert into public.purchase_activity(tenant_id,purchase_id,created_by,message)
    values(t,p_purchase_id,auth.uid(),'Purchase cancelled.');
 insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,payload,result,auth.uid());
 return result;
end $function$;

CREATE OR REPLACE FUNCTION app_private.action_receive_purchase(p_purchase_id uuid, p_revision integer, p_received_on date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_permission('purchases:manage'); p public.purchases; r record; received_time timestamptz:=case when p_received_on is null then clock_timestamp() else (p_received_on+time '12:00') at time zone 'Asia/Dhaka' end;
begin perform app_private.require_permission('purchases:receive');
  select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id for update;
  if not found then raise exception 'Purchase not found'; end if;
  if p_received_on is not null and (not isfinite(p_received_on) or p_received_on>(now() at time zone 'Asia/Dhaka')::date or p.dispatched_at is not null and p_received_on<(p.dispatched_at at time zone 'Asia/Dhaka')::date) then raise exception 'Receipt date must be finite, not future, and on or after dispatch';end if;
 if p.status='received' then if p_received_on is not null and p_received_on<>(p.received_at at time zone 'Asia/Dhaka')::date then raise exception 'Shipment already received with different dates';end if;return jsonb_build_object('already_received',true); end if;
 perform 1 from public.vehicles where tenant_id=t and vehicle_id=p.vehicle_id for update;perform 1 from public.transits where tenant_id=t and purchase_id=p_purchase_id order by transit_id for update; if p_received_on<(now() at time zone 'Asia/Dhaka')::date then perform 1 from public.items where tenant_id=t order by item_id for update;else perform 1 from public.items where tenant_id=t and brand_id=p.brand_id order by item_id for update;end if; perform 1 from public.items where tenant_id=t and item_id in(select item_id from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id) order by item_id for update;
 if p_received_on is null or p_received_on=(now() at time zone 'Asia/Dhaka')::date then received_time:=clock_timestamp();end if;
  if p.business_category='stove' then
    if p.status not in ('created','in_transit') or p.status='created' and p.transport_cost>0 or p_revision is distinct from p.revision then raise exception 'Purchase changed or cannot be received';end if;
    -- Establish the supplier obligation before the receipt clears it.
    update public.purchases set status='in_transit',dispatched_at=coalesce(dispatched_at,received_time) where tenant_id=t and purchase_id=p_purchase_id;
    for r in select * from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id order by item_id loop
      perform 1 from public.items where tenant_id=t and item_id=r.item_id for update;
      insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,filled_quantity_change,notes,created_by,created_at)
      values(t,r.item_id,'purchase','stove_purchase_receipt',p_purchase_id,r.quantity,'Stove purchase received',auth.uid(),received_time);
    end loop;
    update public.purchases set status='received',received_at=received_time,revision=revision+1,updated_at=clock_timestamp() where tenant_id=t and purchase_id=p_purchase_id;
    update public.transits set status='returned',revision=revision+1,updated_at=clock_timestamp() where tenant_id=t and purchase_id=p_purchase_id and status='active';
 if p.vehicle_id is not null and not exists(select 1 from public.transits where tenant_id=t and vehicle_id=p.vehicle_id and status='active') and not exists(select 1 from public.purchases where tenant_id=t and vehicle_id=p.vehicle_id and status='in_transit') then update public.vehicles set status='idle',updated_at=clock_timestamp() where tenant_id=t and vehicle_id=p.vehicle_id;end if;
 insert into public.purchase_activity(tenant_id,purchase_id,created_by,message)
    values(t,p_purchase_id,auth.uid(),'Shipment received into inventory.');
    return jsonb_build_object('purchase_id',p_purchase_id);
  end if;
  if p.status<>'in_transit' then raise exception 'Only an In Transit purchase can be received'; end if;
  if p_revision is distinct from p.revision then raise exception 'Purchase changed. Reload before receipt.' using errcode='P0001'; end if;
  perform 1 from public.vehicles where tenant_id=t and vehicle_id=p.vehicle_id for update;
  perform 1 from public.transits where tenant_id=t and purchase_id=p_purchase_id order by transit_id for update;
  for r in select item_id,sum(quantity) qty from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id
    group by item_id order by item_id loop
    perform 1 from public.items where tenant_id=t and item_id=r.item_id for update;
    insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,filled_quantity_change,notes,created_by,created_at)
      values(t,r.item_id,'purchase','purchase_receipt',
      p_purchase_id,r.qty,'Expected shipment received',auth.uid(),received_time);
  end loop;
  update public.transits set status='returned',revision=revision+1,updated_at=now()
    where tenant_id=t and purchase_id=p_purchase_id and status='active';
  update public.purchases set status='received',received_at=received_time,updated_at=now(),revision=revision+1
    where tenant_id=t and purchase_id=p_purchase_id;
  if not exists(select 1 from public.transits where tenant_id=t and vehicle_id=p.vehicle_id and status='active')
    and not exists(select 1 from public.purchases where tenant_id=t and vehicle_id=p.vehicle_id and status='in_transit') then
    update public.vehicles set status='idle',updated_at=now() where tenant_id=t and vehicle_id=p.vehicle_id;
  end if;
  insert into public.purchase_activity(tenant_id,purchase_id,created_by,message)
    values(t,p_purchase_id,auth.uid(),'Shipment received into inventory.');
  return jsonb_build_object('purchase_id',p_purchase_id);
end $function$;

CREATE OR REPLACE FUNCTION app_private.action_record_purchase_payment(p_purchase_id uuid, p_payments jsonb, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_permission('purchases:manage'); p public.purchases; payload jsonb; prior public.finance_requests; result jsonb;
 x jsonb; w public.wallets; a numeric; part numeric; remaining numeric; company_left numeric; labour_left numeric; component text; id uuid; paid numeric:=0;
begin perform app_private.require_permission('purchases:pay');
 if p_request_id is null then raise exception 'Payment request ID is required'; end if;
 payload:=jsonb_build_object('action','purchase_payment','purchase',p_purchase_id,'payments',p_payments,'actor',auth.uid());
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from payload then raise exception 'Request ID already used with different details'; end if; return prior.result; end if;
 select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id for update;
 if not found then raise exception 'Purchase not found'; end if;
 if p.status not in ('in_transit','received') and not (p.business_category='stove' and p.status='created') then raise exception 'Payments require a dispatched, non-cancelled purchase'; end if;
 if p.payment_status='paid' or p.payable_amount-p.rebate_amount<=p.paid_amount then raise exception 'Purchase is already fully paid'; end if;
 if p_payments is null or jsonb_typeof(p_payments)<>'array' or jsonb_array_length(p_payments) not between 1 and 20 then raise exception 'Add between 1 and 20 payment entries'; end if;
 perform 1 from public.wallets where tenant_id=t and wallet_id in(select (value->>'wallet_id')::uuid from jsonb_array_elements(p_payments)) order by wallet_id for update;
 for x in select value from jsonb_array_elements(p_payments) loop
  if jsonb_typeof(x)<>'object' or jsonb_typeof(x->'amount') is distinct from 'number' then raise exception 'Payment amounts must be numbers'; end if;
  a:=app_private.purchase_money((x->>'amount')::numeric);
  if a<=0 or a<>(x->>'amount')::numeric then raise exception 'Enter a positive amount with at most two decimals'; end if;
  select * into w from public.wallets where tenant_id=t and wallet_id=(x->>'wallet_id')::uuid and is_active ;
  if not found then raise exception 'Select an active payment wallet belonging to this business'; end if;
  if length(coalesce(x->>'reference',''))>200 then raise exception 'Payment reference is too long'; end if;
  paid:=paid+a; if p.paid_amount+paid>p.payable_amount-p.rebate_amount then raise exception 'Payments exceed the remaining purchase balance'; end if;
  insert into public.purchase_payments(tenant_id,purchase_id,wallet_id,wallet_name,method,amount,kind,component,operation_id,reference,created_by)
   values(t,p_purchase_id,w.wallet_id,w.name,w.kind,a,'payment','purchase',p_request_id,coalesce(x->>'reference',''),auth.uid()) returning payment_id into id;
  insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description,operation_id,purchase_payment_id)
   values(t,w.wallet_id,-a,'purchase_payment',p_purchase_id,'Purchase payment · '||w.name||' · '||coalesce(x->>'reference',''),p_request_id,id);
 end loop;
 update public.purchases set paid_amount=paid_amount+paid,payment_status=case when paid_amount+paid>=payable_amount then 'paid' else 'partial' end,
 paid_at=case when paid_amount+paid>=payable_amount then now() else null end,revision=revision+1,updated_at=now() where tenant_id=t and purchase_id=p_purchase_id;
 result:=jsonb_build_object('purchase_id',p_purchase_id,'paid',paid,'paid_amount',p.paid_amount+paid,'due',p.payable_amount-p.rebate_amount-p.paid_amount-paid);

 insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,payload,result,auth.uid());
 return result;
end $function$;

CREATE OR REPLACE FUNCTION app_private.action_refund_purchase(p_purchase_id uuid, p_obligation_id uuid, p_payments jsonb, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_permission('purchases:manage'); p public.purchases; o public.purchase_refund_obligations;
 payload jsonb; prior public.finance_requests; result jsonb; x jsonb; w public.wallets; a numeric; id uuid;
 refunded numeric; total numeric:=0;
begin perform app_private.require_permission('purchases:refund');
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
    values(t,w.wallet_id,a,'purchase_refund',p_purchase_id,'Purchase '||o.component||' refund · '||w.name||' · '||coalesce(x->>'reference',''),p_request_id,id);
  total:=total+a;
 end loop;
 update public.purchases set refund_due=refund_due-total,refunded_amount=refunded_amount+total,
  financial_closed_at=case when refund_due=total then now() end,revision=revision+1,updated_at=now() where tenant_id=t and purchase_id=p_purchase_id;
 result:=jsonb_build_object('purchase_id',p_purchase_id,'refunded',total,'refund_due',p.refund_due-total,'financially_closed',p.refund_due=total);

 insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,payload,result,auth.uid());
 return result;
end $function$;

CREATE OR REPLACE FUNCTION app_private.action_save_transit_costs(p_transit_id uuid, p_costs jsonb, p_revision integer)
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
begin perform app_private.require_permission('logistics:costs');
  if jsonb_typeof(p_costs) is distinct from 'object' or p_costs-array['driver_cost','helper_cost','oil_cost','others_cost','additional_costs']<>'{}'::jsonb then raise exception 'Unsupported transit cost fields';end if;
  select purchase_id into pid from public.transits where tenant_id=t and transit_id=p_transit_id;
  if pid is not null then perform 1 from public.purchases where tenant_id=t and purchase_id=pid for update; end if;
  select * into tr from public.transits where tenant_id=t and transit_id=p_transit_id for update;
  if not found then raise exception 'Transit not found'; end if;
  if tr.closed_at is not null then raise exception 'Closed transit costs are locked'; end if;
  if p_revision is distinct from tr.revision then raise exception 'Transit changed. Reload before saving.' using errcode='P0001'; end if;
  if jsonb_typeof(extra)<>'array' or jsonb_array_length(extra)>100 then raise exception 'Additional costs must be an array'; end if;
  total:=driver+helper+oil+others;
  for x in select value from jsonb_array_elements(extra) loop
    if jsonb_typeof(x)<>'object' or x-array['name','amount','category_id']<>'{}'::jsonb then raise exception 'Unsupported additional cost fields';end if;
    if nullif(trim(x->>'name'),'') is null then raise exception 'Additional cost name is required'; end if;
    if length(x->>'name')>80 then raise exception 'Cost name is too long';end if;
    if nullif(x->>'category_id','') is not null and not exists(select 1 from public.vehicle_expense_categories c where c.tenant_id=t and c.category_id=(x->>'category_id')::uuid and c.name=x->>'name' and (c.is_active or tr.additional_costs @> jsonb_build_array(jsonb_build_object('category_id',x->>'category_id')))) then raise exception 'Expense category changed. Reload before saving.';end if;
    total:=total+app_private.purchase_money((x->>'amount')::numeric);
  end loop;
  update public.transits set driver_cost=driver,helper_cost=helper,oil_cost=oil,others_cost=others,
    additional_costs=extra,total_cost=total,updated_at=now(),revision=revision+1 where tenant_id=t and transit_id=p_transit_id;
  if pid is not null and row(tr.driver_cost,tr.helper_cost,tr.oil_cost,tr.others_cost,tr.additional_costs)
     is distinct from row(driver,helper,oil,others,extra) then
    insert into public.purchase_activity(tenant_id,purchase_id,created_by,message)
    values(t,pid,auth.uid(),'Transit operating costs updated.');
  end if;
  return jsonb_build_object('transit_id',p_transit_id);
end $function$;

CREATE OR REPLACE FUNCTION app_private.action_transition_transit(p_transit_id uuid, p_action text, p_revision integer, p_costs jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_permission('logistics:manage');tr public.transits;pid uuid;wid uuid;driver_due numeric;helper_due numeric;expense_due numeric;client_due numeric;
 today date:=(now() at time zone 'Asia/Dhaka')::date;
begin perform app_private.require_permission('logistics:transits');
 select purchase_id into pid from public.transits where tenant_id=t and transit_id=p_transit_id;
 if pid is not null then perform 1 from public.purchases where tenant_id=t and purchase_id=pid for update;end if;
 select * into tr from public.transits where tenant_id=t and transit_id=p_transit_id;if not found then raise exception 'Transit not found';end if;
 perform 1 from public.vehicles where tenant_id=t and vehicle_id=tr.vehicle_id for update;
 select * into tr from public.transits where tenant_id=t and transit_id=p_transit_id for update;
 if p_action='return' then raise exception 'Use Complete transit to settle costs and return the vehicle Home'; end if;
 if p_action is null or p_action not in ('complete','cancel') then raise exception 'Invalid transit action';end if;
 if p_action='complete' and tr.closed_at is not null or p_action='cancel' and tr.status='cancelled' then
  if tr.completion_intent is distinct from jsonb_build_object('action',p_action,'revision',p_revision,'costs',p_costs) then raise exception 'Transit was already changed with different completion details. Reload before continuing.';end if;
  return jsonb_build_object('already_applied',true);end if;
 if tr.closed_at is not null then raise exception 'Completed transit is locked';end if;
 if p_revision is distinct from tr.revision then raise exception 'Transit changed. Reload before continuing.';end if;
 if pid is not null and (p_action='cancel' or tr.status='active') then raise exception 'Receive or cancel this shipment in Purchases before completing its transit';end if;
 if p_action='complete' then
 -- All payment sources precede cost journals and snapshot invalidation.
 perform 1 from public.employees where tenant_id=t and employee_id in(tr.driver_employee_id,tr.helper_employee_id) order by employee_id for update;
 perform 1 from public.wallets where tenant_id=t and type='cash' and is_active order by wallet_id for update;
 if p_costs is not null then
  perform public.save_transit_costs(p_transit_id,p_costs,p_revision);
  select * into tr from public.transits where tenant_id=t and transit_id=p_transit_id;
 end if;
 -- Lock the complete source set before wallets; existing payments count at their net amount.
 if tr.status='cancelled' and app_private.transit_client_paid(t,p_transit_id)>0 then raise exception 'Refund outstanding client collections before completing';end if;
 driver_due:=greatest(0,tr.driver_cost-app_private.transit_employee_paid(t,p_transit_id,'driver'));
 helper_due:=greatest(0,tr.helper_cost-app_private.transit_employee_paid(t,p_transit_id,'helper'));
 expense_due:=greatest(0,tr.total_cost-tr.driver_cost-tr.helper_cost-app_private.transit_operating_paid(t,p_transit_id));
 client_due:=case when pid is null and tr.status<>'cancelled' then greatest(0,tr.transport_fee-app_private.transit_client_paid(t,p_transit_id)) else 0 end;
 if driver_due+helper_due>0 then perform app_private.require_permission('payroll:pay'); end if;
 if expense_due+client_due>0 then perform app_private.require_permission('logistics:pay'); end if;
 if driver_due+helper_due+expense_due+client_due>0 then
  perform 1 from public.employees where tenant_id=t and employee_id in (tr.driver_employee_id,tr.helper_employee_id) order by employee_id for update;
  select wallet_id into wid from public.wallets where tenant_id=t and type='cash' and is_active for update;
  if wid is null then raise exception 'Activate Cash Register before completing this transit'; end if;
 end if;
 if client_due>0 then
  perform public.record_operating_payment(jsonb_build_object('transit_id',p_transit_id,'kind','client_receipt','payment_date',today,
   'payments',jsonb_build_array(jsonb_build_object('wallet_id',wid,'amount',client_due))),gen_random_uuid());
 end if;
 if driver_due>0 then
  perform public.employee_payment_operation(jsonb_build_object('action','pay','items',jsonb_build_array(jsonb_build_object(
   'employee_id',tr.driver_employee_id,'kind','trips','trip_count',1,'transit_id',p_transit_id,'trip_role','driver','payment_date',today,
   'payments',jsonb_build_array(jsonb_build_object('wallet_id',wid,'amount',driver_due))))),gen_random_uuid());
 end if;
 if helper_due>0 then
  perform public.employee_payment_operation(jsonb_build_object('action','pay','items',jsonb_build_array(jsonb_build_object(
   'employee_id',tr.helper_employee_id,'kind','trips','trip_count',1,'transit_id',p_transit_id,'trip_role','helper','payment_date',today,
   'payments',jsonb_build_array(jsonb_build_object('wallet_id',wid,'amount',helper_due))))),gen_random_uuid());
 end if;
 if expense_due>0 then
  perform public.record_operating_payment(jsonb_build_object('transit_id',p_transit_id,'kind','expense','payment_date',today,
   'payments',jsonb_build_array(jsonb_build_object('wallet_id',wid,'amount',expense_due))),gen_random_uuid());
 end if;
 update public.transits set completion_intent=jsonb_build_object('action',p_action,'revision',p_revision,'costs',p_costs),status=case when status='cancelled' then status else 'completed' end,closed_at=clock_timestamp(),revision=revision+1,updated_at=clock_timestamp() where tenant_id=t and transit_id=p_transit_id;
 else update public.transits set completion_intent=jsonb_build_object('action',p_action,'revision',p_revision,'costs',p_costs),status='cancelled',revision=revision+1,updated_at=clock_timestamp() where tenant_id=t and transit_id=p_transit_id;end if;
 if not exists(select 1 from public.transits where tenant_id=t and vehicle_id=tr.vehicle_id and status='active') and not exists(select 1 from public.purchases where tenant_id=t and vehicle_id=tr.vehicle_id and status='in_transit') then update public.vehicles set status='idle',updated_at=clock_timestamp() where tenant_id=t and vehicle_id=tr.vehicle_id;end if;
 if pid is not null then insert into public.purchase_activity(tenant_id,purchase_id,created_by,message)
    values(t,pid,auth.uid(),'Transit completed.');end if;
 return jsonb_build_object('transit_id',p_transit_id);
end $function$;

CREATE OR REPLACE FUNCTION app_private.action_update_purchase(p_purchase_id uuid, p_payload jsonb, p_revision integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid := app_private.require_permission('purchases:manage'); p public.purchases; truck uuid; before_items jsonb; message text;
begin perform app_private.require_permission('purchases:edit');
  if p_payload - array['vehicle_id','transport_cost','labour_cost','notes','items','rebate_amount'] <> '{}'::jsonb then raise exception 'Unsupported purchase fields';end if;
  select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id for update;
  if not found then raise exception 'Purchase not found'; end if;
  if p_payload ? 'rebate_amount' and app_private.rebate_money(p_payload->'rebate_amount')<>p.rebate_amount then perform app_private.require_permission('purchases:rebates');end if;
  if p_revision is distinct from p.revision then raise exception 'Purchase changed. Reload it before saving.' using errcode='P0001'; end if;
  if p.status='received' and p_payload ?| array['items','transport_cost','labour_cost'] then raise exception 'Received purchase costs and quantities are immutable';end if;
  if p.status='cancelled' or (p.status='received' and p.payment_status='paid') then raise exception 'Purchase is completed and locked'; end if;
  if p_payload ? 'plant_id' and (p_payload->>'plant_id')::uuid is distinct from p.plant_id
    or p_payload ? 'brand_id' and (p_payload->>'brand_id')::uuid is distinct from p.brand_id then
    raise exception 'Plant and company cannot change'; end if;
  if p.status<>'created' and p_payload ? 'transport_cost' and (p_payload->>'transport_cost')::numeric is distinct from p.transport_cost then raise exception 'Transport fee is fixed at dispatch';end if;
  if p_payload ? 'items' then
    select coalesce(jsonb_agg(to_jsonb(pi)), '[]'::jsonb) into before_items
    from public.purchase_items pi where pi.tenant_id=t and pi.purchase_id=p_purchase_id;
  end if;
  truck := case when p_payload ? 'vehicle_id' then (p_payload->>'vehicle_id')::uuid else p.vehicle_id end;
  if p.status<>'created' and truck is distinct from p.vehicle_id then raise exception 'Vehicle is locked after dispatch'; end if;
  if truck is not null and not exists(select 1 from public.vehicles where tenant_id=t and vehicle_id=truck) then raise exception 'Vehicle not found'; end if;
  if p.paid_amount>0 or p.payment_status='paid' or exists(select 1 from public.wallet_transactions where tenant_id=t and reference_id=p_purchase_id and amount<0 and type in ('purchase_expense','purchase_company_payment','purchase_logistics_payment','purchase_payment_company','purchase_payment_labour','purchase_payment_transport','purchase_payment')) then
    if p_payload ? 'items' or p_payload ? 'transport_cost' or p_payload ? 'labour_cost' then
      raise exception 'Financial values lock after the first payment'; end if;
  else
    update public.purchases set vehicle_id=truck where tenant_id=t and purchase_id=p_purchase_id;
    if p_payload ?| array['items','transport_cost','labour_cost'] then
    if p.status<>'created' then
      perform 1 from public.vehicles where tenant_id=t and vehicle_id=p.vehicle_id for update;
      perform 1 from public.transits where tenant_id=t and purchase_id=p_purchase_id order by transit_id for update;
    end if;
    if p_payload ? 'items' then perform app_private.save_purchase_lines(t,p_purchase_id,p_payload->'items'); end if;
    update public.purchases set vehicle_id=truck,
      transport_cost=app_private.purchase_money(coalesce((p_payload->>'transport_cost')::numeric,transport_cost,0)),
      labour_cost=app_private.purchase_money(coalesce((p_payload->>'labour_cost')::numeric,labour_cost,0))
      where tenant_id=t and purchase_id=p_purchase_id;
    perform app_private.recalculate_purchase(t,p_purchase_id);
    if exists(select 1 from public.transits where tenant_id=t and purchase_id=p_purchase_id and closed_at is not null)
      and (select transport_cost from public.purchases where tenant_id=t and purchase_id=p_purchase_id) is distinct from p.transport_cost then
      raise exception 'Transport fee is locked because the transit is closed'; end if;
    update public.transits set transport_fee=(select transport_cost from public.purchases where tenant_id=t and purchase_id=p_purchase_id)
      where tenant_id=t and purchase_id=p_purchase_id;

    end if;
  end if;
 update public.purchases set rebate_amount=case when p_payload ? 'rebate_amount' then app_private.rebate_money(p_payload->'rebate_amount') else rebate_amount end,payment_status=case when status='created' then payment_status when paid_amount>=payable_amount then 'paid' when paid_amount>0 then 'partial' else 'unpaid' end,
    paid_at=case when status<>'created' and paid_amount>=payable_amount then coalesce(paid_at,now()) else paid_at end,notes=case when p_payload ? 'notes' then p_payload->>'notes' else notes end,
    updated_at=now(),revision=revision+1 where tenant_id=t and purchase_id=p_purchase_id;
  message := app_private.purchase_edit_message(t, to_jsonb(p),
    (select to_jsonb(h) from public.purchases h where h.tenant_id=t and h.purchase_id=p_purchase_id), before_items,
    case when p_payload ? 'items' then (select coalesce(jsonb_agg(to_jsonb(pi)), '[]'::jsonb)
      from public.purchase_items pi where pi.tenant_id=t and pi.purchase_id=p_purchase_id) end);
  if message is not null then
    insert into public.purchase_activity(tenant_id,purchase_id,created_by,message)
    values(t,p_purchase_id,auth.uid(),message);
  end if;
  return jsonb_build_object('purchase_id',p_purchase_id);
end $function$;

CREATE OR REPLACE FUNCTION public.get_dashboard_activity(p_offset integer DEFAULT 0, p_limit integer DEFAULT 6)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_permission('dashboard:view');r jsonb;n integer;
begin
 if p_offset is null or p_limit is null or p_offset<0 or p_offset>10000 or p_limit not between 1 and 30 then raise exception 'Invalid activity page';end if;
 n:=p_offset+p_limit+1;
 with events as (
 (select 'sale:'||s.sale_id id,'sale' kind,s.sale_id record_id,'sale' record_kind,
  case when s.status='completed' then 'POS sale' else 'Sale (cancelled)' end title,
  coalesce(c.shop_name,c.name,'Customer') description,s.total_amount+s.additional_charges amount,s.created_at
  from public.sales s left join public.customers c using(tenant_id,customer_id) where s.tenant_id=t
  order by s.created_at desc,s.sale_id desc limit n)
 union all
 (select 'purchase:'||a.activity_id,'purchase',a.purchase_id,'purchase',
  'Purchase activity',concat_ws(' · ',p.supplier_name,g.plant_name,left(a.message,120)),null::numeric,a.created_at
  from public.purchase_activity a join public.purchases p using(tenant_id,purchase_id) left join public.gas_plants g on g.tenant_id=p.tenant_id and g.plant_id=p.plant_id
  where a.tenant_id=t and app_private.has_any_permission(array['purchases:view','purchases:manage'])
  order by a.created_at desc,a.activity_id desc limit n)
 union all
 (select 'purchase-payment:'||pp.operation_id,'purchase',pp.purchase_id,'purchase',
  case pp.kind when 'payment' then 'Purchase payment recorded' else 'Purchase refund recorded' end,
  coalesce(p.supplier_name,g.plant_name,'Purchase'),null::numeric,min(pp.created_at) created_at
  from public.purchase_payments pp join public.purchases p using(tenant_id,purchase_id)
  left join public.gas_plants g on g.tenant_id=p.tenant_id and g.plant_id=p.plant_id
  where pp.tenant_id=t and app_private.has_any_permission(array['purchases:view','purchases:manage'])
  group by pp.operation_id,pp.purchase_id,pp.kind,p.supplier_name,g.plant_name
  order by min(pp.created_at) desc,pp.operation_id desc limit n)
 union all
 (select 'payment:'||p.payment_id,'payment',p.sale_id,'sale','Customer payment',coalesce(c.shop_name,c.name,'Customer')||' · '||p.wallet_name,p.amount,p.created_at
  from public.sale_payments p join public.sales s using(tenant_id,sale_id) left join public.customers c using(tenant_id,customer_id)
  where p.tenant_id=t and p.phase='collection' and app_private.has_any_permission(array['sales:view','finance:view','finance:manage'])
  order by p.created_at desc,p.payment_id desc limit n)
 union all
 (select 'entry:'||e.entry_id,'financial_entry',e.entry_id,'financial_entry','Financial entry · '||e.type_name,e.description,e.amount,e.created_at
  from public.financial_entries e where e.tenant_id=t and app_private.has_any_permission(array['finance:view','finance:manage'])
  order by e.created_at desc,e.entry_id desc limit n)
 union all
 (select 'cancel:'||r.sale_id,'sale',r.sale_id,'sale','Sale cancelled',r.reason,null::numeric,r.created_at
  from public.sale_reversals r where r.tenant_id=t and app_private.has_any_permission(array['sales:view','pos:sell'])
  order by r.created_at desc,r.sale_id desc limit n)
 ), page as materialized(select * from events order by created_at desc,id desc offset p_offset limit p_limit+1)
 select jsonb_build_object('hasMore',(select count(*)>p_limit from page),'entries',coalesce((select jsonb_agg(p) from
  (select * from page order by created_at desc,id desc limit p_limit)p),'[]')) into r;return r;
end $function$;

CREATE OR REPLACE FUNCTION app_private.post_purchase_rebate()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare prior numeric;target numeric;delta numeric;income numeric;available numeric;earned numeric;
 a app_private.purchase_rebate_accounts;eid uuid;d date;label text;entries jsonb;
begin
 target:=case when new.status in ('in_transit','received') then new.rebate_amount else 0 end;
 if target=0 and not exists(select 1 from app_private.purchase_rebate_events where tenant_id=new.tenant_id and purchase_id=new.purchase_id) then return new;end if;
 -- Match the existing journal/snapshot lock order before serializing company credit.
 insert into app_private.accounting_snapshot_state(tenant_id,invalid_from)
 values(new.tenant_id,(clock_timestamp() at time zone 'Asia/Dhaka')::date) on conflict do nothing;
 perform 1 from app_private.accounting_snapshot_state where tenant_id=new.tenant_id for update;
 select coalesce(b.brand_name,new.supplier_name,'Supplier') into label from public.purchases p
 left join public.lpg_brands b on b.tenant_id=p.tenant_id and b.brand_id=p.brand_id
 where p.tenant_id=new.tenant_id and p.purchase_id=new.purchase_id;
 insert into app_private.purchase_rebate_accounts(tenant_id,company_key,company_name,business_category)
 values(new.tenant_id,app_private.rebate_company_key(new),label,new.business_category) on conflict do nothing;
 select * into strict a from app_private.purchase_rebate_accounts where tenant_id=new.tenant_id and company_key=app_private.rebate_company_key(new) for update;
 select coalesce(sum(applied_delta),0),coalesce(sum(income_delta),0) into prior,earned
 from app_private.purchase_rebate_events where tenant_id=new.tenant_id and purchase_id=new.purchase_id;
 delta:=target-prior;if delta=0 then return new;end if;
 select coalesce(sum(income_delta-applied_delta),0) into available from app_private.purchase_rebate_events where tenant_id=new.tenant_id and account_id=a.account_id;
 if available<0 then raise exception 'Company rebate credit is inconsistent';end if;
 if delta>0 then income:=greatest(0,delta-available);
 elsif new.status='cancelled' then income:=0;
 else income:=-least(-delta,earned);end if;
 d:=case when prior=0 and tg_op='UPDATE' and old.status='created' and new.status in ('in_transit','received')
 then (coalesce(new.dispatched_at,new.received_at,clock_timestamp()) at time zone 'Asia/Dhaka')::date
 else (clock_timestamp() at time zone 'Asia/Dhaka')::date end;
 insert into app_private.purchase_rebate_events(tenant_id,account_id,purchase_id,applied_delta,income_delta,occurred_on,created_by)
 values(new.tenant_id,a.account_id,new.purchase_id,delta,income,d,auth.uid()) returning event_id into eid;
 entries:=jsonb_build_array(
  app_private.accounting_line('supplier_payable',delta,new.business_category,new.purchase_id),
  app_private.accounting_line('supplier_receivable',income-delta,new.business_category,a.account_id),
  app_private.accounting_line('other_income',-income,new.business_category,new.purchase_id));
 perform app_private.post_journal(new.tenant_id,'purchase_rebate',new.purchase_id,eid::text,d,'Company rebate · '||label,entries);

 insert into public.purchase_activity(tenant_id,purchase_id,created_by,message)
 values(new.tenant_id,new.purchase_id,auth.uid(),'Company rebate settled.');
 return new;
end $function$;

drop function public.get_purchase_activity(uuid);
create function public.get_purchase_activity(p_purchase_id uuid,p_offset integer default 0,p_limit integer default 30)
returns setof jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['purchases:view','purchases:manage']);
begin
  if p_offset is null or p_limit is null or p_offset not between 0 and 10000 or p_limit not between 1 and 30 then
    raise exception 'Invalid activity page';
  end if;
  return query
  with event_keys as (
    select a.activity_id id,'activity' kind,a.created_at,a.created_by,a.message,null::numeric amount
    from public.purchase_activity a where a.tenant_id=t and a.purchase_id=p_purchase_id
    union all
    select p.operation_id,p.kind,min(p.created_at),p.created_by,null::text,sum(p.amount)
    from public.purchase_payments p where p.tenant_id=t and p.purchase_id=p_purchase_id
    group by p.operation_id,p.kind,p.created_by
  ), page as materialized (
    select * from event_keys order by created_at,id,kind offset p_offset limit p_limit
  )
  select jsonb_build_object('activity_id',e.id,'kind',e.kind,'message',e.message,
    'amount',e.amount,'created_at',e.created_at,
    'actor_name',coalesce(nullif(u.full_name,''),u.email,'Historical user'),
    'wallet_entries',case when e.kind='activity' then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object(
        'transaction_id',w.transaction_id,'purchase_payment_id',p.payment_id,
        'wallet_name',w.wallet_name_snapshot,'method',w.wallet_method_snapshot,
        'amount',w.amount,'created_at',w.created_at,'description',w.description,
        'reference',p.reference,'operation_id',p.operation_id
      ) order by w.entry_no,w.transaction_id)
      from public.purchase_payments p
      join public.wallet_transactions w on w.tenant_id=p.tenant_id and w.purchase_payment_id=p.payment_id
      where p.tenant_id=t and p.purchase_id=p_purchase_id and p.operation_id=e.id
        and p.kind=e.kind and app_private.wallet_allowed(w.wallet_id,'history')
    ),'[]'::jsonb) end)
  from page e left join app_private.tenant_actors u on u.tenant_id=t and u.user_id=e.created_by
  order by e.created_at,e.id,e.kind;
end
$$;
alter function public.get_purchase_activity(uuid,integer,integer) owner to postgres;
revoke all on function public.get_purchase_activity(uuid,integer,integer) from public,anon;
grant execute on function public.get_purchase_activity(uuid,integer,integer) to authenticated,service_role;

alter table public.purchase_activity drop column action, drop column details;
