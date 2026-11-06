-- Permit partial transport refunds; request identity still enforces exactly-once posting.
drop index public.transit_close_once;
create unique index transit_close_once on public.wallet_transactions(tenant_id,reference_id,type)
 where type in ('transit_close_cost','transit_client_refund','purchase_cancel_refund');
create unique index purchase_transport_operation_once on public.wallet_transactions(tenant_id,operation_id,type)
 where type in ('purchase_transport_payment','transit_purchase_income','purchase_transport_refund','transit_purchase_refund');

-- Existing posted purchases retain their original recognition dates.
-- Created drafts and all new purchases use receipt recognition and cash transport.
alter table public.purchases add column recognize_on_receipt boolean not null default false;
update public.purchases set recognize_on_receipt=true where status='created';
alter table public.purchases alter column recognize_on_receipt set default true;
alter table app_private.internal_transport_settlements
 add column wallet_id uuid,
 add column refunded_amount numeric(12,2) not null default 0 check(refunded_amount>=0 and refunded_amount<=amount),
 add constraint transport_wallet_fk foreign key(tenant_id,wallet_id) references public.wallets(tenant_id,wallet_id);

CREATE OR REPLACE FUNCTION app_private.recalculate_purchase(p_tenant uuid, p_purchase uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare s numeric;
begin
 select coalesce(sum(line_total),0) into s from public.purchase_items where tenant_id=p_tenant and purchase_id=p_purchase;
 if s=0 and exists(select 1 from public.purchases where tenant_id=p_tenant and purchase_id=p_purchase and status<>'created' and transport_cost+labour_cost>0) then raise exception 'Positive acquisition value is required to allocate transport and labour';end if;
 update public.purchases set subtotal=s where tenant_id=p_tenant and purchase_id=p_purchase;
end$function$;

CREATE OR REPLACE FUNCTION app_private.source_accounting()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare t uuid:=new.tenant_id;id uuid;src text;d date:=(clock_timestamp() at time zone 'Asia/Dhaka')::date;a numeric;cat text:='shared';lines jsonb:='[]';begin
 if tg_table_name='sales' then
  id:=new.sale_id;src:='sale';if tg_op='INSERT' then d:=(new.created_at at time zone 'Asia/Dhaka')::date;end if;cat:=coalesce(to_jsonb(new)->>'business_category','lpg');a:=case when new.status='completed' then new.total_amount+new.additional_charges else 0 end;
  lines:=jsonb_build_array(app_private.accounting_line('customer_receivable',a,cat,new.customer_id),app_private.accounting_line('sales_revenue',-a,cat));
 elsif tg_table_name='purchases' then
  id:=new.purchase_id;src:='purchase';d:=(case when new.status='received' then coalesce(new.received_at,new.dispatched_at,new.created_at) else coalesce(new.dispatched_at,new.created_at) end at time zone 'Asia/Dhaka')::date;cat:=coalesce(to_jsonb(new)->>'business_category','lpg');a:=case when new.status='received' or (not new.recognize_on_receipt and new.status='in_transit') then new.payable_amount else 0 end;
  lines:=jsonb_build_array(app_private.accounting_line('inventory_transit',a,cat,id),app_private.accounting_line('supplier_payable',-a,cat,id));
 elsif tg_table_name='transits' then
  id:=new.transit_id;src:='transit_revenue';if tg_op='INSERT' then d:=(new.created_at at time zone 'Asia/Dhaka')::date;end if;cat:='logistics';a:=case when new.purchase_id is null and new.status<>'cancelled' then new.transport_fee else 0 end;
  lines:=jsonb_build_array(app_private.accounting_line('transport_receivable',a,cat,id),app_private.accounting_line('logistics_revenue',-a,cat));
 elsif tg_table_name='employee_salary_months' then
  id:=new.salary_month_id;src:='salary';a:=new.salary_amount;
  if new.period>(now() at time zone 'Asia/Dhaka')::date then return new;end if;
  lines:=jsonb_build_array(app_private.accounting_line('employee_expense',a,'shared'),app_private.accounting_line('employee_payable',-a,'shared',new.employee_id));
 elsif tg_table_name='employee_payments' then
  if new.kind<>'bonus' then return new;end if;
  id:=new.payment_id;src:='bonus';a:=case when new.reversal_of is null then new.amount else -new.amount end;d:=new.payment_date;
  lines:=jsonb_build_array(app_private.accounting_line('employee_expense',a),app_private.accounting_line('employee_payable',-a,'shared',new.employee_id));
 elsif tg_table_name='operating_cost_events' then
  id:=new.event_id;src:='operating_cost';d:=new.incurred_on;cat:='logistics';a:=new.amount;
  lines:=jsonb_build_array(app_private.accounting_line(case when new.service_trip_id is null then 'logistics_expense' else 'vehicle_expense' end,a,cat),app_private.accounting_line(case when lower(new.category) in ('driver earnings','helper earnings') then 'employee_payable' else 'operating_payable' end,-a,cat,coalesce(new.transit_id,new.service_trip_id)));
 else return new;end if;
 perform app_private.sync_journal(t,src,id,d,replace(src,'_',' ')||' recognition',lines);return new;end $function$;

CREATE OR REPLACE FUNCTION app_private.post_purchase_rebate()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare prior numeric;target numeric;delta numeric;income numeric;available numeric;earned numeric;
 a app_private.purchase_rebate_accounts;eid uuid;d date;label text;entries jsonb;
begin
 target:=case when (new.status='received' or not new.recognize_on_receipt and new.status='in_transit') then new.rebate_amount else 0 end;
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
 d:=case when prior=0 and tg_op='UPDATE' and old.status='created' and (new.status='received' or not new.recognize_on_receipt and new.status='in_transit')
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

CREATE OR REPLACE FUNCTION app_private.account_wallet()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$declare
 other text;entity uuid:=new.reference_id;ep public.employee_payments;e public.financial_entries;entries jsonb;begin
 if new.type='wallet_transfer' then return new;end if;
 if new.type='custom_entry' then select * into e from public.financial_entries where tenant_id=new.tenant_id and entry_id=new.reference_id;
  other:=e.account;entity:=coalesce(e.asset_id,e.entry_id);
 elsif new.type in ('pos_sale_income','customer_collection','sale_refund') then other:='customer_receivable';select customer_id into entity from public.sales where tenant_id=new.tenant_id and sale_id=new.reference_id;
 elsif new.type in ('purchase_transport_payment','purchase_transport_refund') then
  other:=case when new.type='purchase_transport_payment' then 'inventory_transit' else 'operating_expense' end;
 elsif new.type in ('transit_purchase_income','transit_purchase_refund') then other:='internal_logistics_revenue';
 elsif new.type like 'purchase%' then other:='supplier_payable';
 elsif new.type like 'payroll_%' then
  select p.* into ep from public.employee_payment_entries x join public.employee_payments p using(tenant_id,payment_id) where x.tenant_id=new.tenant_id and x.entry_id=new.employee_entry_id;
  other:='employee_payable';entity:=case when ep.kind='trips' then ep.transit_id else ep.employee_id end;
 elsif new.type like 'transit_client_%' then other:='transport_receivable';
 elsif new.type in ('transit_expense','transit_expense_return','vehicle_service_expense','vehicle_service_expense_return') then other:='operating_payable';
 elsif new.type='obligation_settlement' then select o.account,o.entity_id into other,entity from public.finance_obligations o where o.tenant_id=new.tenant_id and o.obligation_id=new.reference_id;
 elsif new.type='owner_withdrawal' then other:='withdrawals';
 elsif new.type='balance_adjustment' then other:='equity_adjustment';
 elsif new.type='owner_capital' then other:='capital';
 elsif new.type='opening_cash' then other:='opening_equity';
 elsif new.type in ('loan_lend','loan_collect') then other:='loan_receivable';
 elsif new.type in ('loan_receipt','loan_repayment') then other:='loan_payable';
 elsif new.type in ('asset_purchase','asset_proceeds','asset_disposal_expense') then other:='other_assets';
 else raise exception 'Wallet entry has no accounting classification: %',new.type;end if;
 if other is null then raise exception 'Wallet source is missing';end if;
 select jsonb_agg(line) into entries from jsonb_each_text(new.business_amounts)b cross join lateral(values
  (app_private.accounting_line('cash',b.value::numeric,b.key,new.wallet_id)||jsonb_build_object('type_id',new.type_id)),
  (app_private.accounting_line(other,-b.value::numeric,b.key,entity,jsonb_build_object('type_name',e.type_name))||jsonb_build_object('type_id',new.type_id)))v(line);
 perform app_private.post_journal(new.tenant_id,'wallet',new.transaction_id,'cash',new.accounting_date,new.description,entries,false,new.type='opening_cash');return new;
end $function$;

CREATE OR REPLACE FUNCTION app_private.settle_internal_transport(t uuid, pid uuid, d date, reverse_entry boolean DEFAULT false)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare p public.purchases;s app_private.internal_transport_settlements;v numeric;lines jsonb; w uuid;trip uuid;
begin
 select * into p from public.purchases where tenant_id=t and purchase_id=pid for update;
 select * into s from app_private.internal_transport_settlements where tenant_id=t and purchase_id=pid;
 if p.recognize_on_receipt then
  if reverse_entry then
   if s.purchase_id is null or s.reversed then return;end if;
   if p.status<>'received' then perform app_private.post_journal(t,'internal_transport',pid,'cancelled',d,'Cancelled purchase transport cost',
    jsonb_build_array(app_private.accounting_line('operating_expense',s.amount,p.business_category,pid),
     app_private.accounting_line('inventory_transit',-s.amount,p.business_category,pid)));end if;
   update app_private.internal_transport_settlements set reversed=true where tenant_id=t and purchase_id=pid;
   return;
  end if;
  if s.purchase_id is not null or p.transport_cost=0 then return;end if;
  select transit_id into trip from public.transits where tenant_id=t and purchase_id=pid;
  if trip is null then raise exception 'Purchase transit is required';end if;
  select wallet_id into w from public.wallets where tenant_id=t and type='cash' and is_active order by wallet_id limit 1 for update;
  if w is null then raise exception 'Active Cash Register is required';end if;
  if not app_private.wallet_allowed(w,'use') then raise insufficient_privilege using message='Cash Register use is required for transport payment';end if;
  insert into app_private.internal_transport_settlements(tenant_id,purchase_id,amount,occurred_on,reversed,wallet_id)
   values(t,pid,p.transport_cost,d,false,w);
  insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description,operation_id,type_id,allocations,accounting_date)
   values(t,w,-p.transport_cost,'purchase_transport_payment',pid,'Purchase transport paid to Logistics',pid,
     app_private.system_type('internal_transport'),jsonb_build_object(p.business_category,100),d),
    (t,w,p.transport_cost,'transit_purchase_income',trip,'Transport payment received from purchase',pid,
     app_private.system_type('internal_transport'),'{"logistics":100}',d);
  return;
 end if;
 if reverse_entry then
  if s.purchase_id is null or s.reversed then return;end if;v:=-s.amount;
 else
  if s.purchase_id is not null or p.transport_cost=0 then return;end if;v:=p.transport_cost;
  insert into app_private.internal_transport_settlements(tenant_id,purchase_id,amount,occurred_on,reversed) values(t,pid,v,d,false);
 end if;
 lines:=jsonb_build_array(
  app_private.accounting_line('inventory_transit',v,p.business_category,pid)||jsonb_build_object('consolidated_amount',0),
  app_private.accounting_line('business_allocation_equity',-v,p.business_category,pid)||jsonb_build_object('consolidated_amount',0),
  app_private.accounting_line('business_allocation_equity',v,'logistics',pid)||jsonb_build_object('consolidated_amount',0),
  app_private.accounting_line('internal_logistics_revenue',-v,'logistics',pid)||jsonb_build_object('consolidated_amount',0));
 perform app_private.post_journal(t,'internal_transport',pid,case when reverse_entry then 'return' else 'allocated' end,d,'Noncash internal purchase transport',lines);
 if reverse_entry then update app_private.internal_transport_settlements set reversed=true where tenant_id=t and purchase_id=pid;end if;
end$function$;

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
 if p.recognize_on_receipt and (
  not exists(select 1 from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id)
  or p.subtotal<=0 and p.transport_cost+p.labour_cost>0) then
  raise exception 'Add products with positive buying values before dispatch or receipt';
 end if;
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
      insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,bottle_quantity_change,notes,created_by,created_at)
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
 if p.recognize_on_receipt and (
  not exists(select 1 from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id)
  or p.subtotal<=0 and p.transport_cost+p.labour_cost>0) then
  raise exception 'Add products with positive buying values before dispatch or receipt';
 end if;
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
    insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,filled_quantity_change,bottle_quantity_change,notes,created_by,created_at)
      values(t,r.item_id,'purchase','purchase_receipt',
      p_purchase_id,r.qty,r.qty,'Expected shipment received',auth.uid(),received_time);
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

CREATE OR REPLACE FUNCTION app_private.fifo_cost_movement(m inventory_movements)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
 c public.inventory_costs;old_cost app_private.fifo_movement_costs;p public.purchases;
 cat text;account text;counter text:='cogs';fc numeric:=0;ec numeric:=0;shell numeric:=0;iv numeric:=0;isv numeric:=0;
 gas_value numeric:=0;gas_internal numeric:=0;bottle_value numeric:=0;bottle_internal numeric:=0;
 gas_piece numeric;gas_internal_piece numeric;basis numeric:=0;variance numeric:=0;expected integer;prior_qty integer;counted integer:=0;slice integer:=0;
 lines jsonb;batch record;component record;f_after numeric;e_after numeric;owned_value numeric:=0;
 d date:=(m.created_at at time zone 'Asia/Dhaka')::date;
begin
 select * into p from public.purchases where tenant_id=m.tenant_id and purchase_id=m.reference_id;
 select * into c from public.inventory_costs where tenant_id=m.tenant_id and item_id=m.item_id for update;
 select business_category into cat from public.items where tenant_id=m.tenant_id and item_id=m.item_id;
 account:=case when cat='stove' then 'inventory_stove' else 'inventory_lpg' end;
 select * into old_cost from app_private.fifo_movement_costs where tenant_id=m.tenant_id and movement_id=m.movement_id;
 if m.reference_type in ('sale_reversal','stove_purchase_cancellation') then
  -- Only the exact incoming customer/receipt batches may be returned.
  if m.empty_quantity_change<0 or m.reference_type='stove_purchase_cancellation' then
   for batch in select l.* from app_private.fifo_layers l join public.inventory_movements im using(tenant_id,movement_id)
    where l.tenant_id=m.tenant_id and l.item_id=m.item_id and im.reference_id=m.reference_id
    and ((m.reference_type='sale_reversal' and im.reference_type='sale' and im.empty_quantity_change>0 and l.component='empty')
      or (m.reference_type='stove_purchase_cancellation' and im.reference_type='stove_purchase_receipt'))
    order by l.acquired_at,l.acquired_order,l.slice_no loop
    if batch.remaining<>batch.quantity or batch.remaining_value<>batch.value or batch.remaining_internal_value<>batch.internal_value then raise exception 'The original received batch has been consumed or changed; cancellation cannot substitute other stock';end if;
    counted:=counted+batch.quantity;
    if batch.component='empty' then ec:=ec-batch.remaining_value;else fc:=fc-batch.remaining_value;end if;
    insert into app_private.fifo_consumptions(tenant_id,movement_id,layer_id,quantity,value,shell_value,internal_value,internal_shell_value) values(m.tenant_id,m.movement_id,batch.layer_id,batch.quantity,batch.value,batch.shell_value,batch.internal_value,batch.internal_shell_value);
    update app_private.fifo_positions set remaining=0,remaining_unit_value=0,remaining_bottle_value=0,
      remaining_internal_unit_value=0,remaining_internal_bottle_value=0 where tenant_id=m.tenant_id and layer_id=batch.layer_id;
   end loop;
   if counted<>(case when m.reference_type='sale_reversal' then -m.empty_quantity_change else -m.filled_quantity_change end) then raise exception 'Original received quantity does not reconcile';end if;
  end if;
  if m.reference_type='sale_reversal' then
   for batch in select x.* from app_private.fifo_consumptions x join public.inventory_movements im on im.tenant_id=x.tenant_id and im.movement_id=x.movement_id join app_private.fifo_layers l on l.tenant_id=x.tenant_id and l.layer_id=x.layer_id
    where im.tenant_id=m.tenant_id and im.item_id=m.item_id and im.reference_id=m.reference_id and im.reference_type='sale' and im.filled_quantity_change<0 and l.component='filled' loop
    fc:=fc+batch.value;
    update app_private.fifo_positions set remaining=remaining+batch.quantity,
      remaining_unit_value=remaining_unit_value+batch.value-batch.shell_value,remaining_bottle_value=remaining_bottle_value+batch.shell_value,
      remaining_internal_unit_value=remaining_internal_unit_value+batch.internal_value-batch.internal_shell_value,
      remaining_internal_bottle_value=remaining_internal_bottle_value+batch.internal_shell_value
    where tenant_id=m.tenant_id and layer_id=batch.layer_id;
    insert into app_private.fifo_consumptions(tenant_id,movement_id,layer_id,quantity,value,shell_value,internal_value,internal_shell_value) values(m.tenant_id,m.movement_id,batch.layer_id,-batch.quantity,-batch.value,-batch.shell_value,-batch.internal_value,-batch.internal_shell_value);
   end loop;
  else counter:='inventory_transit';end if;
 else
  if m.filled_quantity_change<0 then fc:=-app_private.fifo_take(m.tenant_id,m.item_id,m.movement_id,'filled',-m.filled_quantity_change);end if;
  if m.empty_quantity_change<0 then ec:=-app_private.fifo_take(m.tenant_id,m.item_id,m.movement_id,'empty',-m.empty_quantity_change);end if;
  if m.reference_type in ('purchase_receipt','stove_purchase_receipt') then
   select * into p from public.purchases where tenant_id=m.tenant_id and purchase_id=m.reference_id;
   for component in select * from app_private.purchase_components(m.tenant_id,m.reference_id) where item_id=m.item_id loop
    if component.component='bottle' then bottle_value:=component.invoice_value+component.labour_value;bottle_internal:=component.transport_value;
    else gas_value:=component.invoice_value+component.labour_value;gas_internal:=component.transport_value;end if;
   end loop;
   fc:=gas_value+bottle_value;counter:='inventory_transit';
   if cat='lpg' then
    -- Receipt creates one Gas acquisition even when the fill uses several Bottle slices.
    insert into app_private.fifo_component_layers
      (tenant_id,item_id,movement_id,component,origin_state,acquired_at,quantity,value,internal_value)
    values(m.tenant_id,m.item_id,m.movement_id,'gas','filled',m.created_at,m.filled_quantity_change,gas_value,gas_internal);
    -- Dispatched bottles retain their original source and age in linked slices.
    for batch in select h.quantity,h.value,h.internal_value,l.acquired_at,l.shell_acquired_at,l.shell_source_movement_id,l.movement_id source_movement
     from app_private.fifo_purchase_holdings h
     join app_private.fifo_layers l on l.tenant_id=h.tenant_id and l.layer_id=h.position_id
     join public.inventory_movements im on im.tenant_id=h.tenant_id and im.movement_id=h.dispatch_movement_id
     where im.tenant_id=m.tenant_id and im.item_id=m.item_id and im.reference_id=m.reference_id
       and im.reference_type='purchase_dispatch' and h.settled_movement_id is null
     order by l.acquired_at,l.acquired_order,l.slice_no loop
     gas_piece:=round(gas_value*(counted+batch.quantity)/m.filled_quantity_change,2)-round(gas_value*counted/m.filled_quantity_change,2);
     gas_internal_piece:=round(gas_internal*(counted+batch.quantity)/m.filled_quantity_change,2)-round(gas_internal*counted/m.filled_quantity_change,2);
     perform app_private.fifo_component_layer(m.tenant_id,m.item_id,m.movement_id,'filled',m.created_at,batch.quantity,gas_piece+batch.value,batch.value,gas_internal_piece+batch.internal_value,batch.internal_value,slice,coalesce(batch.shell_source_movement_id,batch.source_movement),coalesce(batch.shell_acquired_at,batch.acquired_at));
     counted:=counted+batch.quantity;slice:=slice+1;fc:=fc+batch.value;owned_value:=owned_value+batch.value;
    end loop;
    select bottle_quantity into expected from public.purchase_items where tenant_id=m.tenant_id and purchase_id=m.reference_id and item_id=m.item_id;
    if counted+expected<>m.filled_quantity_change then raise exception 'Received filled units do not match dispatched and newly purchased bottle evidence';end if;
    if expected>0 then
     perform app_private.fifo_component_layer(m.tenant_id,m.item_id,m.movement_id,'filled',m.created_at,expected,gas_value-round(gas_value*counted/m.filled_quantity_change,2)+bottle_value,bottle_value,gas_internal-round(gas_internal*counted/m.filled_quantity_change,2)+bottle_internal,bottle_internal,slice);
    end if;
   else perform app_private.fifo_component_layer(m.tenant_id,m.item_id,m.movement_id,'filled',m.created_at,m.filled_quantity_change,fc,0,gas_internal,0);end if;
  elsif m.reference_type='purchase_dispatch' then counter:='inventory_transit';
  elsif m.reference_type='purchase_cancellation' then
   counter:='inventory_transit';
   for batch in select h.* from app_private.fifo_purchase_holdings h
    join public.inventory_movements im on im.tenant_id=h.tenant_id and im.movement_id=h.dispatch_movement_id
    where im.tenant_id=m.tenant_id and im.item_id=m.item_id and im.reference_id=m.reference_id
      and im.reference_type='purchase_dispatch' and h.settled_movement_id is null loop
    ec:=ec+batch.value;counted:=counted+batch.quantity;
    update app_private.fifo_positions set remaining=remaining+batch.quantity,
      remaining_bottle_value=remaining_bottle_value+batch.value,
      remaining_internal_bottle_value=remaining_internal_bottle_value+batch.internal_value
    where tenant_id=m.tenant_id and layer_id=batch.position_id;
   end loop;
   if counted<>m.empty_quantity_change then raise exception 'Dispatched bottle quantity does not reconcile';end if;
  elsif m.valuation->>'counter_account' is not null then
   counter:=m.valuation->>'counter_account';
   if counter not in ('opening_equity','inventory_loss','other_income','capital') then raise exception 'Invalid stock adjustment classification';end if;
   if m.filled_quantity_change>0 then
    fc:=round(m.filled_quantity_change*app_private.purchase_money((m.valuation->>'filled_unit_cost')::numeric),2);
    shell:=case when cat='lpg' then round(m.filled_quantity_change*app_private.purchase_money((m.valuation->>'filled_shell_unit_cost')::numeric),2) else 0 end;
    perform app_private.fifo_component_layer(m.tenant_id,m.item_id,m.movement_id,'filled',m.created_at,m.filled_quantity_change,fc,shell,0,0);
   end if;
   if m.empty_quantity_change>0 then ec:=round(m.empty_quantity_change*app_private.purchase_money((m.valuation->>'empty_unit_cost')::numeric),2);end if;
  elsif m.reference_type='sale' then
   if m.filled_quantity_change<0 and cat='lpg' and m.valuation->>'sale_type'='refill' then
    select coalesce(sum(x.shell_value),0),coalesce(sum(x.internal_shell_value),0) into shell,isv from app_private.fifo_consumptions x where x.tenant_id=m.tenant_id and x.movement_id=m.movement_id;
    perform app_private.sync_journal(m.tenant_id,'bottle_obligation',m.movement_id,d,'Historical bottle replacement claim',jsonb_build_array(app_private.accounting_line('bottle_receivable',shell+isv,'lpg',m.reference_id)||jsonb_build_object('consolidated_amount',shell),app_private.accounting_line('cogs',-shell-isv,'lpg')||jsonb_build_object('consolidated_amount',-shell)));
   end if;
   if m.empty_quantity_change>0 then
    ec:=round(m.empty_quantity_change*app_private.purchase_money((m.valuation->>'bottle_unit_cost')::numeric),2);
    select coalesce(sum(quantity),0) into expected from public.sale_items where tenant_id=m.tenant_id and sale_id=m.reference_id and type='empty_return';
    select coalesce(sum(empty_quantity_change),0) into prior_qty from public.inventory_movements where tenant_id=m.tenant_id and reference_type='sale' and reference_id=m.reference_id and empty_quantity_change>0 and (created_at,movement_no)<(m.created_at,m.movement_no);
    select coalesce(sum(x.shell_value+x.internal_shell_value),0),coalesce(sum(x.shell_value),0) into shell,gas_value from app_private.fifo_consumptions x join public.inventory_movements issued using(tenant_id,movement_id) where x.tenant_id=m.tenant_id and issued.reference_type='sale' and issued.reference_id=m.reference_id and issued.filled_quantity_change<0 and issued.valuation->>'sale_type'='refill';
    basis:=case when expected>0 then round(shell*least(expected,prior_qty+m.empty_quantity_change)/expected,2)-round(shell*least(expected,prior_qty)/expected,2) else 0 end;
    gas_value:=case when expected>0 then round(gas_value*least(expected,prior_qty+m.empty_quantity_change)/expected,2)-round(gas_value*least(expected,prior_qty)/expected,2) else 0 end;
    lines:=jsonb_build_array(app_private.accounting_line(account,ec,cat,m.item_id),app_private.accounting_line('bottle_receivable',-basis,cat,m.reference_id)||jsonb_build_object('consolidated_amount',-gas_value),app_private.accounting_line('bottle_exchange',basis-ec,cat,m.reference_id)||jsonb_build_object('consolidated_amount',gas_value-ec));
   end if;
  else raise exception 'Stock movement requires recorded acquisition evidence';end if;
  if m.empty_quantity_change>0 and m.reference_type<>'purchase_cancellation' then perform app_private.fifo_component_layer(m.tenant_id,m.item_id,m.movement_id,'empty',m.created_at,m.empty_quantity_change,ec,ec,0,0);end if;
 end if;
 if m.reference_type in ('purchase_receipt','purchase_cancellation') then
  update app_private.fifo_purchase_holdings h set settled_movement_id=m.movement_id
  from public.inventory_movements d
  where h.tenant_id=m.tenant_id and h.tenant_id=d.tenant_id and h.dispatch_movement_id=d.movement_id
    and d.item_id=m.item_id and d.reference_id=m.reference_id and d.reference_type='purchase_dispatch'
    and h.settled_movement_id is null;
 end if;
 if fc is null or ec is null then raise exception 'Missing FIFO acquisition evidence';end if;
 f_after:=c.filled_value+fc;e_after:=c.empty_value+ec;
 update public.inventory_costs set filled_quantity=filled_quantity+m.filled_quantity_change,empty_quantity=empty_quantity+m.empty_quantity_change,filled_value=f_after,empty_value=e_after where tenant_id=m.tenant_id and item_id=m.item_id;
 if old_cost.movement_id is null then
  insert into public.inventory_cost_entries(tenant_id,item_id,movement_id,occurred_on,filled_change,empty_change,filled_value,empty_value,filled_after,empty_after,reason,estimated,created_by)
  values(m.tenant_id,m.item_id,m.movement_id,d,m.filled_quantity_change,m.empty_quantity_change,fc,ec,f_after,e_after,coalesce(m.notes,'FIFO component carrying cost'),c.estimated,m.created_by);
 elsif old_cost.filled_value<>fc or old_cost.empty_value<>ec then
  insert into public.inventory_cost_entries(tenant_id,item_id,occurred_on,filled_change,empty_change,filled_value,empty_value,filled_after,empty_after,reason,estimated,created_by)
  values(m.tenant_id,m.item_id,d,0,0,fc-old_cost.filled_value,ec-old_cost.empty_value,f_after,e_after,'FIFO recalculation of '||m.movement_id,c.estimated,auth.uid());
 end if;
 insert into app_private.fifo_movement_costs values(m.tenant_id,m.movement_id,m.item_id,m.created_at,fc,ec) on conflict(tenant_id,movement_id) do update set filled_value=excluded.filled_value,empty_value=excluded.empty_value;
 if p.recognize_on_receipt and m.reference_type in ('purchase_dispatch','purchase_cancellation') then return;end if;
 if p.recognize_on_receipt and m.reference_type='purchase_receipt' then fc:=fc-owned_value;end if;
 if lines is null then lines:=jsonb_build_array(app_private.accounting_line(account,fc+ec,cat,m.item_id),app_private.accounting_line(counter,-fc-ec,cat,m.reference_id));end if;
 perform app_private.sync_journal(m.tenant_id,'inventory',m.movement_id,d,coalesce(m.notes,'FIFO component carrying cost'),lines,counter='opening_equity');
 perform app_private.sync_internal_fifo(m);
end$function$;

CREATE OR REPLACE FUNCTION app_private.sync_internal_fifo(m inventory_movements)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$declare
 owned_internal numeric:=0; p public.purchases; a numeric:=0;c numeric:=0;cat text;account text;counter text;lines jsonb;begin
 select * into p from public.purchases where tenant_id=m.tenant_id and purchase_id=m.reference_id;
 if p.recognize_on_receipt and m.reference_type in ('purchase_dispatch','purchase_cancellation') then return;end if;
 if p.recognize_on_receipt and m.reference_type='purchase_receipt' then
  select coalesce(sum(h.internal_value),0) into owned_internal
  from app_private.fifo_purchase_holdings h where h.tenant_id=m.tenant_id and h.settled_movement_id=m.movement_id;
 end if;
 select coalesce(sum(internal_value),0) into a from app_private.fifo_layers where tenant_id=m.tenant_id and movement_id=m.movement_id;
 select coalesce(sum(internal_value),0) into c from app_private.fifo_position_effects where tenant_id=m.tenant_id and movement_id=m.movement_id;
 a:=a-owned_internal;
 if a=0 and c=0 and not exists(select 1 from app_private.accounting_source_state where tenant_id=m.tenant_id and source in ('internal_inventory','internal_cogs') and source_id=m.movement_id and revision>0) then return;end if;
 select business_category into cat from public.items where tenant_id=m.tenant_id and item_id=m.item_id;
 account:=case when cat='stove' then 'inventory_stove' else 'inventory_lpg' end;
 counter:=case when m.reference_type in ('purchase_receipt','stove_purchase_receipt','purchase_dispatch','purchase_cancellation') then 'inventory_transit' when m.reference_type='stove_purchase_cancellation' then 'operating_expense' when m.reference_type in ('sale','sale_reversal') then 'cogs' else 'inventory_loss' end;
 lines:=jsonb_build_array(app_private.accounting_line(account,a-c,cat,m.item_id)||jsonb_build_object('consolidated_amount',0),
  app_private.accounting_line(counter,c-a,cat,case when counter='inventory_transit' then m.reference_id end)||jsonb_build_object('consolidated_amount',0));
 perform app_private.sync_journal(m.tenant_id,case when a<>0 then 'internal_inventory' else 'internal_cogs' end,m.movement_id,(m.created_at at time zone 'Asia/Dhaka')::date,'Internal transport FIFO carrying cost',lines);
end $function$;

CREATE OR REPLACE FUNCTION app_private.reconcile_record(t uuid, k text, id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare observed jsonb;expected jsonb;safe boolean:=false;note text:='Canonical source comparison';v numeric;v2 numeric;salary_period record;d date;pos jsonb;hash text;begin
 if k='customer' then
  if not exists(select 1 from public.customers where tenant_id=t and customer_id=id) then return false;end if;
  insert into app_private.customer_metrics(tenant_id,customer_id) values(t,id) on conflict do nothing;
  perform 1 from app_private.customer_metrics where tenant_id=t and customer_id=id for update nowait;
  select to_jsonb(c)-'tenant_id'-'customer_id' into observed from app_private.customer_metrics c where tenant_id=t and customer_id=id;
  select jsonb_build_object('ledger_balance',coalesce((select sum(amount) from public.customer_transactions where tenant_id=t and customer_id=id),0),
   'transactions',count(*),'refill',coalesce(sum(q.refill),0),'package',coalesce(sum(q.package),0),
   'total_sold_amount',coalesce(sum(s.total_amount+s.additional_charges),0),'total_due',coalesce(sum(greatest(0,s.total_amount+s.additional_charges-s.paid_amount)),0),'last_transaction_at',max(s.created_at)) into expected
  from public.sales s left join lateral(select coalesce(sum(quantity) filter(where type='refill'),0) refill,coalesce(sum(quantity) filter(where type='package'),0) package from public.sale_items i where i.tenant_id=t and i.sale_id=s.sale_id)q on true
  where s.tenant_id=t and s.customer_id=id and s.status='completed';
  if observed is distinct from expected then
   update app_private.customer_metrics set ledger_balance=(expected->>'ledger_balance')::numeric,transactions=(expected->>'transactions')::bigint,refill=(expected->>'refill')::bigint,package=(expected->>'package')::bigint,total_sold_amount=(expected->>'total_sold_amount')::numeric,total_due=(expected->>'total_due')::numeric,last_transaction_at=(expected->>'last_transaction_at')::timestamptz where tenant_id=t and customer_id=id;
   safe:=found;end if;
 elsif k='wallet' then
  perform 1 from public.wallets where tenant_id=t and wallet_id=id for update nowait;
  if not found then return false;end if;
  select balance,opening_balance+coalesce((select sum(amount) from public.wallet_transactions where tenant_id=t and wallet_id=id),0) into v,v2 from public.wallets where tenant_id=t and wallet_id=id;
  observed:=jsonb_build_object('balance',v,'combined_cash',(select coalesce(sum(balance),0) from public.wallets where tenant_id=t));
  expected:=jsonb_build_object('balance',v2,'combined_cash',(select coalesce(sum(amount),0) from public.accounting_lines where tenant_id=t and account='cash'));
  -- A wallet is reconciled to its own ledger; only the pooled total is compared
  -- with journal Cash. Treasury transfers deliberately have no business journal.
  if v<>v2 and (select coalesce(sum(opening_balance),0)+coalesce((select sum(amount) from public.wallet_transactions where tenant_id=t),0) from public.wallets where tenant_id=t)=(expected->>'combined_cash')::numeric then
   update public.wallets set balance=v2 where tenant_id=t and wallet_id=id;safe:=true;
  end if;
 elsif k='inventory' then
  -- Never repair physical stock from a financial discrepancy. Cost evidence and
  -- movement coverage must agree before an operator can investigate a count.
  perform 1 from public.items where tenant_id=t and item_id=id for update nowait;
  if not found then return false;end if;
  perform 1 from public.inventory_costs where tenant_id=t and item_id=id for update nowait;
  select jsonb_build_object('filled',i.filled_quantity,'empty',i.empty_quantity,'pool_filled',c.filled_quantity,'pool_empty',c.empty_quantity,'filled_value',c.filled_value,'empty_value',c.empty_value,'journal_value',c.filled_value+c.empty_value,'missing_movements',0) into observed from public.items i join public.inventory_costs c using(tenant_id,item_id) where i.tenant_id=t and i.item_id=id;
  select jsonb_build_object('filled',coalesce(sum(filled_change),0),'empty',coalesce(sum(empty_change),0),'pool_filled',coalesce(sum(filled_change),0),'pool_empty',coalesce(sum(empty_change),0),'filled_value',coalesce(sum(filled_value),0),'empty_value',coalesce(sum(empty_value),0),
   'journal_value',coalesce((select sum(filled_value+empty_value) from public.inventory_cost_entries where tenant_id=t and item_id=id),0),
   'missing_movements',(select count(*) from public.inventory_movements m where m.tenant_id=t and m.item_id=id and not exists(select 1 from public.inventory_cost_entries e where e.tenant_id=t and e.movement_id=m.movement_id))) into expected from public.inventory_cost_entries where tenant_id=t and item_id=id;
 observed:=observed||jsonb_build_object('fifo_consistent',app_private.fifo_components_consistent(t,id) and
  not exists(select 1 from app_private.fifo_layers l left join lateral(select coalesce(sum(x.quantity),0) q,coalesce(sum(x.value),0) v,coalesce(sum(x.shell_value),0) s,coalesce(sum(x.internal_value),0) iv,coalesce(sum(x.internal_shell_value),0) ish from app_private.fifo_position_effects x where x.tenant_id=t and x.layer_id=l.layer_id)x on true where l.tenant_id=t and l.item_id=id and (l.quantity<>l.remaining+x.q or l.value<>l.remaining_value+x.v or l.shell_value<>l.remaining_shell_value+x.s or l.internal_value<>l.remaining_internal_value+x.iv or l.internal_shell_value<>l.remaining_internal_shell_value+x.ish))
  and coalesce((select c.filled_quantity=x.f and c.empty_quantity=x.e and c.filled_value=x.fv and c.empty_value=x.ev from public.inventory_costs c cross join lateral(select coalesce(sum(remaining) filter(where component='filled'),0) f,coalesce(sum(remaining) filter(where component='empty'),0) e,coalesce(sum(remaining_value) filter(where component='filled'),0) fv,coalesce(sum(remaining_value) filter(where component='empty'),0) ev from app_private.fifo_layers where tenant_id=t and item_id=id and remaining>0)x where c.tenant_id=t and c.item_id=id),true));
 expected:=expected||jsonb_build_object('fifo_consistent',true);
 observed:=observed||jsonb_build_object('inventory_control',coalesce((select sum(l.consolidated_amount) from public.accounting_lines l where l.tenant_id=t and l.account=case when (select business_category from public.items where tenant_id=t and item_id=id)='stove' then 'inventory_stove' else 'inventory_lpg' end),0));
 expected:=expected||jsonb_build_object('inventory_control',coalesce((select sum(h.value) from app_private.fifo_purchase_holdings h
 join public.inventory_movements m on m.tenant_id=h.tenant_id and m.movement_id=h.dispatch_movement_id
 join public.purchases p on p.tenant_id=m.tenant_id and p.purchase_id=m.reference_id
 join public.items i on i.tenant_id=m.tenant_id and i.item_id=m.item_id
 where h.tenant_id=t and h.settled_movement_id is null and p.recognize_on_receipt
 and i.business_category=(select business_category from public.items where tenant_id=t and item_id=id)),0)+coalesce((select sum(c.filled_value+c.empty_value) from public.inventory_costs c join public.items i using(tenant_id,item_id) where c.tenant_id=t and i.business_category=(select business_category from public.items where tenant_id=t and item_id=id)),0));
 observed:=observed||jsonb_build_object('full_inventory_control',coalesce((select sum(l.amount) from public.accounting_lines l where l.tenant_id=t and l.account=case when (select business_category from public.items where tenant_id=t and item_id=id)='stove' then 'inventory_stove' else 'inventory_lpg' end),0));
 expected:=expected||jsonb_build_object('full_inventory_control',coalesce((select sum(h.value+h.internal_value) from app_private.fifo_purchase_holdings h
 join public.inventory_movements m on m.tenant_id=h.tenant_id and m.movement_id=h.dispatch_movement_id
 join public.purchases p on p.tenant_id=m.tenant_id and p.purchase_id=m.reference_id
 join public.items i on i.tenant_id=m.tenant_id and i.item_id=m.item_id
 where h.tenant_id=t and h.settled_movement_id is null and p.recognize_on_receipt
 and i.business_category=(select business_category from public.items where tenant_id=t and item_id=id)),0)+coalesce((select sum(c.filled_value+c.empty_value+coalesce((select sum(l.remaining_internal_value) from app_private.fifo_layers l where l.tenant_id=c.tenant_id and l.item_id=c.item_id),0)) from public.inventory_costs c join public.items i using(tenant_id,item_id) where c.tenant_id=t and i.business_category=(select business_category from public.items where tenant_id=t and item_id=id)),0));
 elsif k='loan' then
  perform 1 from public.loans where tenant_id=t and loan_id=id for update nowait;
  if not found then return false;end if;
  select jsonb_build_object('outstanding',outstanding) into observed from public.loans where tenant_id=t and loan_id=id;
  select jsonb_build_object('outstanding',principal-coalesce((select sum(amount) from public.loan_activity where tenant_id=t and loan_id=id and action in ('principal repayment','repayment received')),0)) into expected from public.loans where tenant_id=t and loan_id=id;
 elsif k='asset' then
  perform 1 from public.business_assets where tenant_id=t and asset_id=id for update nowait;
  if not found then return false;end if;
  select jsonb_build_object('book_value',case when status='active' then cost-accumulated_depreciation else 0 end) into observed from public.business_assets where tenant_id=t and asset_id=id;
  select jsonb_build_object('book_value',coalesce(sum(amount),0)) into expected from public.accounting_lines where tenant_id=t and entity_id=id and account in ('vehicles','equipment','other_assets');
 elsif k='obligation' then
  perform 1 from public.finance_obligations where tenant_id=t and obligation_id=id for update nowait;
  if not found then return false;end if;
  select jsonb_build_object('settled',settled) into observed from public.finance_obligations where tenant_id=t and obligation_id=id;
  select jsonb_build_object('settled',coalesce(sum(abs(amount)),0)) into expected from public.wallet_transactions where tenant_id=t and reference_id=id and type='obligation_settlement';
 elsif k='payroll' then
  perform 1 from public.employees where tenant_id=t and employee_id=id for update nowait;
  if not found then return false;end if;
  -- Compare each actual payment header with its immutable wallet allocations.
  select jsonb_build_object('payments',coalesce(sum(amount),0)) into observed from public.employee_payments where tenant_id=t and employee_id=id;
  select jsonb_build_object('payments',coalesce(sum(e.amount),0)) into expected from public.employee_payment_entries e join public.employee_payments p using(tenant_id,payment_id) where p.tenant_id=t and p.employee_id=id;
  for salary_period in select date_trunc('month',x)::date period from generate_series((select min(effective_from)::timestamp from public.employee_terms where tenant_id=t and employee_id=id),date_trunc('month',now() at time zone 'Asia/Dhaka'),'1 month')x loop
   v:=(app_private.employee_month_balance(t,id,salary_period.period)->>'salary_amount')::numeric;
   v2:=coalesce((select sum(l.amount) from public.accounting_lines l join public.accounting_journals j using(tenant_id,journal_id) where j.tenant_id=t and j.source='salary_accrual' and j.source_id=md5(id::text||salary_period.period::text)::uuid and l.account='employee_expense'),0);
   if v<>v2 then observed:=observed||jsonb_build_object(salary_period.period::text,v2);expected:=expected||jsonb_build_object(salary_period.period::text,v);end if;
  end loop;
 elsif k='sale' then
  perform 1 from public.sales where tenant_id=t and sale_id=id for update nowait;
  if not found then return false;end if;
  select jsonb_build_object('recognized_invoice',case when status='completed' then total_amount+additional_charges else 0 end) into expected from public.sales where tenant_id=t and sale_id=id;
  select jsonb_build_object('recognized_invoice',coalesce(sum((l->>'amount')::numeric),0)) into observed from app_private.accounting_source_state s cross join lateral jsonb_array_elements(s.lines)l where s.tenant_id=t and s.source='sale' and s.source_id=id and l->>'account'='customer_receivable';
 elsif k='purchase' then
  perform 1 from public.purchases where tenant_id=t and purchase_id=id for update nowait;
  if not found then return false;end if;
  select jsonb_build_object('recognized_invoice',case when status='received' or not recognize_on_receipt and status='in_transit' then payable_amount else 0 end) into expected from public.purchases where tenant_id=t and purchase_id=id;
  select jsonb_build_object('recognized_invoice',coalesce(-sum((l->>'amount')::numeric),0)) into observed from app_private.accounting_source_state s cross join lateral jsonb_array_elements(s.lines)l where s.tenant_id=t and s.source='purchase' and s.source_id=id and l->>'account'='supplier_payable';
 elsif k='transit' then
  perform 1 from public.transits where tenant_id=t and transit_id=id for update nowait;
  if not found then return false;end if;
  select jsonb_build_object('earned_revenue',case when purchase_id is null and status<>'cancelled' then transport_fee else 0 end,
   'incurred_costs',coalesce((select sum(amount) from public.operating_cost_events where tenant_id=t and transit_id=id),0)) into expected from public.transits where tenant_id=t and transit_id=id;
  select jsonb_build_object('earned_revenue',coalesce((select -sum((l->>'amount')::numeric) from app_private.accounting_source_state s cross join lateral jsonb_array_elements(s.lines)l where s.tenant_id=t and s.source='transit_revenue' and s.source_id=id and l->>'account'='logistics_revenue'),0),
   'incurred_costs',coalesce((select sum((l->>'amount')::numeric) from public.operating_cost_events e join app_private.accounting_source_state s on s.tenant_id=e.tenant_id and s.source='operating_cost' and s.source_id=e.event_id cross join lateral jsonb_array_elements(s.lines)l join public.accounting_accounts a on a.code=l->>'account' where e.tenant_id=t and e.transit_id=id and a.kind='expense'),0)) into observed;
 elsif k='journal' then
  select jsonb_build_object('imbalance',coalesce(sum(amount),0),'has_lines',count(*)>0) into observed from public.accounting_lines where tenant_id=t and journal_id=id;
  expected:=jsonb_build_object('imbalance',0,'has_lines',true);
 elsif k='snapshot' then
  -- Validate one month per queue item; requeue the next month through its audit
  -- revision in the sweep. Exact rows, not just the equation, must agree.
  select min(month_end) into d from app_private.accounting_snapshots s where s.tenant_id=t and md5(s.month_end::text)::uuid=id;
  if d is null then return false;end if;
  if exists(select 1 from app_private.accounting_snapshot_state where tenant_id=t and invalid_from<=d) then return false;end if;
  select checksum into hash from app_private.accounting_snapshots where tenant_id=t and month_end=d;
  observed:=jsonb_build_object('checksum',hash,'difference',0);
  with full_history as(select l.account,l.business_category,l.entity_id,l.type_id,sum(l.amount) amount,sum(l.consolidated_amount) consolidated_amount from public.accounting_lines l join public.accounting_journals j using(tenant_id,journal_id) where j.tenant_id=t and j.occurred_on<=d group by 1,2,3,4),
 diff as(select * from full_history except select account,business_category,entity_id,type_id,amount,consolidated_amount from app_private.accounting_snapshot_lines where tenant_id=t and month_end=d),
 reverse_diff as(select account,business_category,entity_id,type_id,amount,consolidated_amount from app_private.accounting_snapshot_lines where tenant_id=t and month_end=d except select * from full_history)
 select jsonb_build_object('checksum',md5(coalesce((select string_agg(concat_ws(':',account,business_category,entity_id,type_id,amount,consolidated_amount),'|' order by account,business_category,entity_id,type_id) from full_history),'')),'difference',(select count(*) from diff)+(select count(*) from reverse_diff)) into expected;
  if observed is distinct from expected then update app_private.accounting_snapshot_state set invalid_from=least(invalid_from,d) where tenant_id=t;note:='Savepoint invalidated; canonical journals remain unchanged';end if;
 else raise exception 'Unknown reconciliation kind';end if;
 if observed is null and expected is null then return false;end if;
 if observed is distinct from expected then
  insert into app_private.reconciliation_findings(tenant_id,kind,entity_id,observed,expected,status,diagnostic) values(t,k,id,coalesce(observed,'null'),coalesce(expected,'null'),case when safe then 'repaired' else 'unresolved' end,note);return true;
 end if;return false;end $function$;

create function public.get_purchase_transport(p_transit_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['logistics:view','logistics:manage']);r jsonb;
begin
 select jsonb_build_object('paid',s.amount,'refunded',s.refunded_amount,
 'remaining',s.amount-s.refunded_amount,'can_refund',p.status='cancelled' and s.wallet_id is not null,
 'wallet_name',case when app_private.wallet_allowed(s.wallet_id,'history') then w.name end)
 into r from public.transits tr join public.purchases p using(tenant_id,purchase_id)
 join app_private.internal_transport_settlements s using(tenant_id,purchase_id)
 left join public.wallets w on w.tenant_id=s.tenant_id and w.wallet_id=s.wallet_id
 where tr.tenant_id=t and tr.transit_id=p_transit_id;
 return r;
end $$;
create function public.refund_purchase_transport(p_transit_id uuid,p_amount numeric,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('logistics:pay');pid uuid;p public.purchases;
 s app_private.internal_transport_settlements;tr public.transits;prior public.finance_requests;
 payload jsonb;result jsonb;d date:=(clock_timestamp() at time zone 'Asia/Dhaka')::date;
begin
 if not public.can_cancel_purchases() then raise insufficient_privilege using message='Only the OWNER can approve a transport refund';end if;
 if p_request_id is null then raise exception 'Request ID is required';end if;
 if p_amount is null or not(p_amount>0 and p_amount=round(p_amount,2) and p_amount<1000000000) then raise exception 'Enter a positive exact-cent refund';end if;
 payload:=jsonb_build_object('action','purchase_transport_refund','transit',p_transit_id,'amount',p_amount,'actor',auth.uid());
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then
  if prior.payload is distinct from payload then raise exception 'Request ID already used with different details';end if;
  return prior.result;
 end if;
 select purchase_id into pid from public.transits where tenant_id=t and transit_id=p_transit_id;
 select * into p from public.purchases where tenant_id=t and purchase_id=pid for update;
 if not found or p.status<>'cancelled' then raise exception 'A cancelled purchase is required';end if;
 perform 1 from public.vehicles where tenant_id=t and vehicle_id=p.vehicle_id for update;
 select * into tr from public.transits where tenant_id=t and transit_id=p_transit_id for update;
 select * into s from app_private.internal_transport_settlements where tenant_id=t and purchase_id=pid for update;
 if s.wallet_id is null or not s.reversed then raise exception 'No paid cancelled transport is available';end if;
 if p_amount>s.amount-s.refunded_amount then raise exception 'Refund exceeds the unrefunded transport payment';end if;
 perform 1 from public.wallets where tenant_id=t and wallet_id=s.wallet_id for update;
 perform app_private.begin_accounting_action('refund_purchase_transport',p_request_id);
 insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description,operation_id,type_id,allocations,accounting_date)
 values(t,s.wallet_id,-p_amount,'transit_purchase_refund',p_transit_id,'Approved transport refund to purchase',p_request_id,
 app_private.system_type('internal_transport'),'{"logistics":100}',d),
 (t,s.wallet_id,p_amount,'purchase_transport_refund',pid,'Transport refund received from Logistics',p_request_id,
 app_private.system_type('internal_transport'),jsonb_build_object(p.business_category,100),d);
 update app_private.internal_transport_settlements set refunded_amount=refunded_amount+p_amount where tenant_id=t and purchase_id=pid;
 result:=jsonb_build_object('refunded',p_amount,'remaining',s.amount-s.refunded_amount-p_amount);
 insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,payload,result,auth.uid());
 insert into public.purchase_activity(tenant_id,purchase_id,created_by,message)
 values(t,pid,auth.uid(),format('Logistics approved and paid a transport refund of Tk %s.',p_amount));
 perform app_private.finish_accounting_action();
 return result;
end $$;
alter function public.get_purchase_transport(uuid) owner to postgres;
alter function public.refund_purchase_transport(uuid,numeric,uuid) owner to postgres;
revoke all on function public.get_purchase_transport(uuid),public.refund_purchase_transport(uuid,numeric,uuid) from public,anon;
grant execute on function public.get_purchase_transport(uuid),public.refund_purchase_transport(uuid,numeric,uuid) to authenticated,service_role;

CREATE OR REPLACE FUNCTION app_private.logistics_result(t uuid, transit_ids uuid[], service_ids uuid[] DEFAULT '{}'::uuid[])
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
 with sources as (
  select 'transit_revenue' source,unnest(transit_ids) id,false service
  union select 'operating_cost',e.event_id,e.service_trip_id is not null from public.operating_cost_events e
   where e.tenant_id=t and (e.transit_id=any(transit_ids) or e.service_trip_id=any(service_ids))
 ), facts as (
  select a.kind,(l->>'amount')::numeric amount,s.service from sources s
   join app_private.accounting_source_state state on state.tenant_id=t and state.source=s.source and state.source_id=s.id
   cross join lateral jsonb_array_elements(state.lines)l join public.accounting_accounts a on a.code=l->>'account'
  union all
  select 'income',-(settlement.amount-settlement.refunded_amount),false from app_private.internal_transport_settlements settlement
   where settlement.tenant_id=t and (not settlement.reversed or settlement.wallet_id is not null) and exists(select 1 from public.transits tr
    where tr.tenant_id=t and tr.transit_id=any(transit_ids) and tr.purchase_id=settlement.purchase_id)
 )
 select jsonb_build_object('revenue',coalesce(-sum(amount) filter(where kind='income'),0),
  'transit_expenses',coalesce(sum(amount) filter(where kind='expense' and not service),0),
  'service_expenses',coalesce(sum(amount) filter(where kind='expense' and service),0),
  'profit',coalesce(-sum(amount) filter(where kind in ('income','expense')),0)) from facts;
$function$
;

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
  if r.empties<>0 then insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,bottle_quantity_change,notes,created_by)
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
 if p.status<>'received' or p.recognize_on_receipt then perform app_private.settle_internal_transport(t,p_purchase_id,(now() at time zone 'Asia/Dhaka')::date,true);end if; if p.status<>'received' then update public.transits set status='cancelled',revision=revision+1,updated_at=now() where tenant_id=t and purchase_id=p_purchase_id;end if;
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
end $function$
;
