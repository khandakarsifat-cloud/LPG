-- Development baseline: applied only after the explicitly authorized,
-- independently restored full backup and scoped business-data reset.
do $$begin
 if exists(select 1 from public.tenants) then
  raise exception 'Core overhaul requires the reviewed empty business baseline; no business data is removed by this migration';
 end if;
end$$;

-- Purchase quantities represent gas units (or stove units), not sale types.
alter table public.purchase_items
 drop column type,
 drop column shell_unit_cost,
 drop column billed_quantity,
 drop column received_quantity,
 drop column line_total,
 add column bottle_quantity integer not null default 0 check(bottle_quantity>=0 and bottle_quantity<=quantity),
 add column bottle_unit_price numeric(12,2) not null default 0 check(bottle_unit_price>=0),
 add constraint purchase_component_prices_valid check(unit_price>=0 and unit_price<10000000000),
 add constraint purchase_custody_quantity_valid check(empty_dispatched<=quantity-bottle_quantity),
 add constraint purchase_product_unique unique(tenant_id,purchase_id,item_id);
alter table public.purchase_items add column line_total numeric(14,2) generated always as(quantity*unit_price+bottle_quantity*bottle_unit_price) stored;
drop trigger guard_transport_terms on public.purchases;
alter table public.purchases drop constraint purchase_business_shape;
alter table public.purchases
 drop column commission,
 drop column commission_month,
 drop column transport_wallet_id;
drop trigger accounting_purchase on public.purchases;
drop trigger reconciliation_source on public.purchases;
alter table public.purchases drop column payable_amount,drop column company_payable,drop column total_cost;
alter table public.purchases
 add column company_payable numeric(14,2) generated always as(subtotal) stored,
 add column payable_amount numeric(14,2) generated always as(subtotal+labour_cost) stored,
 add column total_cost numeric(14,2) generated always as(subtotal+labour_cost+transport_cost) stored;
create trigger accounting_purchase after insert or update of status,subtotal,labour_cost,received_at,dispatched_at on public.purchases for each row execute function app_private.source_accounting();
create trigger reconciliation_source after insert or update of status,subtotal,labour_cost on public.purchases for each row execute function app_private.mark_reconciliation('purchase','purchase_id');
create or replace function app_private.guard_transport_terms()
returns trigger language plpgsql set search_path='' as $$begin
 if old.status<>'created' and new.transport_cost<>old.transport_cost then raise exception 'Dispatched transport allocation is fixed; cancel an unreceived purchase to reverse it';end if;return new;
end$$;
create trigger guard_transport_terms before update of transport_cost on public.purchases for each row execute function app_private.guard_transport_terms();
alter table public.purchases add constraint purchase_business_shape check(
 (business_category='lpg' and plant_id is not null) or
 (business_category='stove' and plant_id is null and brand_id is null and length(trim(supplier_name)) between 1 and 150));

-- Each physical filled batch can contain multiple historical bottle sources.
-- Gas cost is value-shell_value. Internal transport stays separately identified
-- for consolidation, including the portion that belongs to the bottle.
alter table app_private.fifo_layers
 drop constraint fifo_layers_tenant_id_movement_id_component_key,
 add column slice_no integer not null default 0,
 add column shell_source_movement_id uuid,
 add column shell_acquired_at timestamptz,
 add column internal_shell_value numeric(14,2) not null default 0,
 add column remaining_internal_shell_value numeric(14,2) not null default 0,
 add constraint fifo_layer_slice_unique unique(tenant_id,movement_id,component,slice_no),
 add constraint fifo_internal_shell_valid check(internal_shell_value>=0 and internal_shell_value<=internal_value and remaining_internal_shell_value between 0 and internal_shell_value and remaining_internal_shell_value<=remaining_internal_value),
 add constraint fifo_shell_value_valid check(shell_value between 0 and value and remaining_shell_value between 0 and shell_value and remaining_shell_value<=remaining_value),
 add constraint fifo_internal_value_valid check(internal_value>=0 and remaining_internal_value between 0 and internal_value),
 add constraint fifo_exhausted_value_zero check(remaining>0 or remaining_value+remaining_shell_value+remaining_internal_value+remaining_internal_shell_value=0),
 add constraint fifo_shell_source_fk foreign key(tenant_id,shell_source_movement_id) references public.inventory_movements(tenant_id,movement_id);
alter table app_private.fifo_consumptions add column internal_shell_value numeric(14,2) not null default 0;
-- The old last-empty-price fallback is superseded by component price history.
alter table public.inventory_costs drop column empty_unit_cost;

-- New history is component-specific. Actual acquisition remains in immutable
-- purchase evidence/FIFO; this history is an operational current-price reference.
alter table public.product_buying_price_history
 drop constraint product_buying_price_history_price_type_check,
 drop constraint product_buying_price_history_source_check,
 drop column commission_per_unit,
 drop column commission_id,
 drop column commission_month,
 drop column commission_revision;
alter table public.product_buying_price_history drop column reconstructed;
alter table public.product_buying_price_history rename column bottle_cost to invoice_unit_price;
alter table public.product_buying_price_history
 add constraint product_buying_price_history_price_type_check check(price_type in ('gas','bottle')),
 add constraint product_buying_price_history_source_check check(source in ('purchase','manual','restore_automatic'));

-- Wallets hold physical money once; allocation belongs only to operations.
alter table public.wallets drop column business_balances;
alter table public.wallet_transactions drop column business_balance_after;
alter table public.wallet_transactions
 alter column allocations drop not null,
 alter column business_amounts drop not null,
 drop constraint wallet_transactions_allocations_check,
 drop constraint wallet_transactions_check,
 add constraint wallet_transaction_attribution check(
  (type='wallet_transfer' and allocations is null and business_amounts is null) or
  (type<>'wallet_transfer' and allocations is not null and business_amounts is not null
   and app_private.valid_business_allocation(allocations)
   and app_private.valid_business_amounts(amount,business_amounts)));
alter table app_private.internal_transport_settlements drop column source_wallet_id,drop column destination_wallet_id;
insert into public.accounting_accounts(code,name,kind) values('bottle_exchange','Cylinder exchange gain / loss','expense');
alter table public.transits add column completion_intent jsonb;
alter table public.accounting_lines drop constraint accounting_lines_amount_check;
alter table public.accounting_lines add constraint accounting_lines_amount_check check(
 (amount<>0 or consolidated_amount<>0) and abs(amount)<100000000000000000 and abs(consolidated_amount)<100000000000000000);

-- Remaining canonical routines and reviewed obsolete dependencies follow.

drop trigger initialize_internal_layer on app_private.fifo_layers;
drop trigger aa_monthly_commission on public.purchases;
drop trigger monthly_buying_prices on public.monthly_commission_rates;
drop trigger product_commission_immutable on public.product_commission_rates;
drop function app_private.effective_commission(t uuid, id uuid, day date);
drop function app_private.fifo_add(t uuid, id uuid, mid uuid, part text, at_time timestamp with time zone, qty integer, cost numeric, shell numeric);
drop function app_private.infer_monthly_commissions(t uuid, brand uuid, period date);
drop function app_private.initialize_internal_layer();
drop function app_private.internal_layer_value(t uuid, mid uuid);
drop function app_private.monthly_buying_prices();
drop function app_private.product_commission_immutable();
drop function app_private.receive_monthly_commission();
drop function app_private.snapshot_purchase_shells(t uuid, pid uuid);
drop function public.correct_commission_deduction(p_payload jsonb, p_request_id uuid);
drop function public.get_monthly_commissions(p_item_id uuid, p_month date, p_offset integer);
drop function public.get_product_commission_history(p_item_id uuid, p_offset integer, p_limit integer);
drop function public.receive_purchase(p_purchase_id uuid, p_revision integer, p_received_on date, p_commission_month date);
drop function public.set_monthly_commission(p_payload jsonb, p_request_id uuid);
drop table public.monthly_commission_deduction_history,public.monthly_commission_deductions,public.monthly_commission_history,public.monthly_commission_rates,public.product_commission_rates;
drop type public.purchase_type;
delete from public.financial_types where origin='system' and (code ilike '%commission%' or account='commission_pending');
delete from public.accounting_accounts where code='commission_pending';
drop function app_private.refresh_buying_price(t uuid, id uuid, kind text, source_name text, as_of timestamp with time zone, actor uuid, reconstructed boolean);
delete from public.financial_types where origin='system' and code in ('internal_transport_payment','internal_transport_receipt','internal_transport_return');

create or replace function app_private.purchase_components(t uuid,pid uuid)
returns table(purchase_item_id uuid,item_id uuid,component text,quantity integer,invoice_value numeric,labour_value numeric,transport_value numeric)
language sql stable set search_path='' as $$
 with components as (
  select pi.purchase_item_id,pi.item_id,case when p.business_category='stove' then 'product' else 'gas' end::text component,pi.quantity,pi.quantity*pi.unit_price invoice_value
  from public.purchase_items pi join public.purchases p using(tenant_id,purchase_id) where pi.tenant_id=t and pi.purchase_id=pid
  union all
  select pi.purchase_item_id,pi.item_id,'bottle',pi.bottle_quantity,pi.bottle_quantity*pi.bottle_unit_price
  from public.purchase_items pi where pi.tenant_id=t and pi.purchase_id=pid and pi.bottle_quantity>0
 ), ordered as (
  select c.*,sum(c.invoice_value) over() total,
   sum(c.invoice_value) over(order by c.item_id,c.component) boundary
  from components c
 )
 select c.purchase_item_id,c.item_id,c.component,c.quantity,c.invoice_value,
  case when c.total>0 then round(p.labour_cost*c.boundary/c.total,2)-round(p.labour_cost*(c.boundary-c.invoice_value)/c.total,2) else 0 end,
  case when c.total>0 then round(p.transport_cost*c.boundary/c.total,2)-round(p.transport_cost*(c.boundary-c.invoice_value)/c.total,2) else 0 end
 from ordered c join public.purchases p on p.tenant_id=t and p.purchase_id=pid;
$$;

create or replace function app_private.save_purchase_lines(p_tenant uuid,p_purchase uuid,p_lines jsonb)
returns void language plpgsql set search_path='' as $$
declare p public.purchases;x jsonb;q integer;b integer;price numeric;bp numeric;line_id uuid;seen uuid[]:='{}';
begin
 select * into p from public.purchases where tenant_id=p_tenant and purchase_id=p_purchase;
 if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines)>100 then raise exception 'Use up to 100 product lines';end if;
 if p.status not in ('created','in_transit') or p.paid_amount>0 then raise exception 'Received or paid purchase lines are immutable';end if;
 if p.business_category='stove' and (p.status<>'created' or jsonb_array_length(p_lines)=0) then raise exception 'Select stove products before dispatch';end if;
 if p.status='created' then delete from public.purchase_items where tenant_id=p_tenant and purchase_id=p_purchase;
 elsif jsonb_array_length(p_lines)<>(select count(*) from public.purchase_items where tenant_id=p_tenant and purchase_id=p_purchase) then raise exception 'Dispatched products are locked';end if;
 for x in select value from jsonb_array_elements(p_lines) loop
  if jsonb_typeof(x)<>'object' or x-array['purchase_item_id','item_id','quantity','bottle_quantity','unit_price','bottle_unit_price']<>'{}'::jsonb then raise exception 'Unsupported purchase product fields';end if;
  line_id:=(x->>'item_id')::uuid;
  if line_id=any(seen) then raise exception 'Use one line per product';end if;
  seen:=array_append(seen,line_id);
  if not exists(select 1 from public.items i where i.tenant_id=p_tenant and i.item_id=line_id and i.business_category=p.business_category and (p.business_category='stove' or i.brand_id=p.brand_id)) then raise exception 'Product must belong to this supplier and business';end if;
  q:=app_private.purchase_integer(x->'quantity');b:=app_private.purchase_integer(coalesce(x->'bottle_quantity','0'::jsonb));
  price:=app_private.purchase_money((x->>'unit_price')::numeric);bp:=app_private.purchase_money(coalesce((x->>'bottle_unit_price')::numeric,0));
  if q<=0 or b<0 or b>q then raise exception 'Gas quantity must be positive; Bottle quantity must be between zero and Gas quantity';end if;
  if p.business_category='stove' and (b<>0 or bp<>0) then raise exception 'Stoves do not have Bottle purchase components';end if;
  if b=0 and bp<>0 then raise exception 'Bottle price requires a purchased Bottle quantity';end if;
  if p.status='created' then
   insert into public.purchase_items(tenant_id,purchase_id,item_id,quantity,bottle_quantity,unit_price,bottle_unit_price,empty_dispatched)
   values(p_tenant,p_purchase,line_id,q,b,price,bp,0);
  else
   if not exists(select 1 from public.purchase_items pi where pi.tenant_id=p_tenant and pi.purchase_id=p_purchase and pi.purchase_item_id=(x->>'purchase_item_id')::uuid and pi.item_id=line_id and pi.quantity=q and pi.bottle_quantity=b) then raise exception 'Dispatched products and quantities are locked';end if;
   update public.purchase_items set unit_price=price,bottle_unit_price=bp where tenant_id=p_tenant and purchase_id=p_purchase and item_id=line_id;
  end if;
 end loop;
end$$;

create or replace function app_private.recalculate_purchase(p_tenant uuid,p_purchase uuid)
returns void language plpgsql set search_path='' as $$
declare s numeric;
begin
 select coalesce(sum(line_total),0) into s from public.purchase_items where tenant_id=p_tenant and purchase_id=p_purchase;
 if s=0 and exists(select 1 from public.purchases where tenant_id=p_tenant and purchase_id=p_purchase and transport_cost+labour_cost>0) then raise exception 'Positive acquisition value is required to allocate transport and labour';end if;
 update public.purchases set subtotal=s where tenant_id=p_tenant and purchase_id=p_purchase;
end$$;

create or replace function app_private.buying_price_reference(t uuid,id uuid,kind text,as_of timestamptz)
returns jsonb language sql stable set search_path='' as $$
 select coalesce((select jsonb_build_object('invoice_unit_price',c.invoice_value/c.quantity,'overhead_per_unit',(c.labour_value+c.transport_value)/c.quantity,
 'purchase_id',p.purchase_id,'automatic_price',round((c.invoice_value+c.labour_value+c.transport_value)/c.quantity,2),'received_at',p.received_at)
 from public.purchases p cross join lateral app_private.purchase_components(t,p.purchase_id)c
 where p.tenant_id=t and p.status='received' and p.received_at<=as_of and c.item_id=id and c.component=kind
 order by p.received_at desc,p.created_at desc,p.purchase_id desc limit 1),'{}'::jsonb);
$$;

create or replace function app_private.refresh_buying_price(t uuid,id uuid,kind text,as_of timestamptz,actor uuid)
returns void language plpgsql set search_path='' as $$
declare prev public.product_buying_price_history;reference jsonb;automatic numeric;receipt_time timestamptz;
begin
 if not exists(select 1 from public.items where tenant_id=t and item_id=id and business_category='lpg') then return;end if;
 reference:=app_private.buying_price_reference(t,id,kind,as_of);
 if reference->>'purchase_id' is null then return;end if;
 select * into prev from public.product_buying_price_history where tenant_id=t and item_id=id and price_type=kind order by effective_at desc,entry_no desc limit 1;
 receipt_time:=(reference->>'received_at')::timestamptz;
 -- A delayed/backdated receipt cannot supersede a later receipt or manual edit.
 if prev.history_id is not null and (prev.effective_at>receipt_time or prev.purchase_id=(reference->>'purchase_id')::uuid) then return;end if;
 automatic:=(reference->>'automatic_price')::numeric;
 insert into public.product_buying_price_history(tenant_id,item_id,price_type,previous_price,new_price,automatic_price,is_manual,invoice_unit_price,overhead_per_unit,purchase_id,source,reason,effective_at,created_by)
 values(t,id,kind,prev.new_price,automatic,automatic,false,(reference->>'invoice_unit_price')::numeric,(reference->>'overhead_per_unit')::numeric,(reference->>'purchase_id')::uuid,'purchase','Received acquisition including allocated transport and labour',receipt_time,actor);
end$$;

create or replace function app_private.purchase_buying_prices()
returns trigger language plpgsql set search_path='' as $$
declare id uuid;k text;
begin
 if new.business_category='lpg' and new.status='received' and old.status<>'received' then
  for id in select item_id from public.purchase_items where tenant_id=new.tenant_id and purchase_id=new.purchase_id order by item_id loop
   foreach k in array array['gas','bottle'] loop perform app_private.refresh_buying_price(new.tenant_id,id,k,clock_timestamp(),auth.uid());end loop;
  end loop;
 end if;return new;
end$$;

-- Replace the old automatic internal-cost trigger: each linked slice explicitly
-- carries gas, bottle and internal-transport evidence without multiplying costs.


create or replace function app_private.sync_sale_bottle_reversal(t uuid,sid uuid,d date)
returns void language plpgsql set search_path='' as $$
declare claim numeric;consolidated_claim numeric;variance numeric;consolidated_variance numeric;
begin
 select coalesce(sum(l.amount),0),coalesce(sum(l.consolidated_amount),0) into claim,consolidated_claim
 from public.accounting_lines l join public.accounting_journals j using(tenant_id,journal_id)
 where l.tenant_id=t and l.account='bottle_receivable' and l.entity_id=sid and j.source<>'sale_bottle_claim_reversal';
 perform app_private.sync_journal(t,'sale_bottle_claim_reversal',sid,d,'Cancel historical bottle replacement claim',jsonb_build_array(
  app_private.accounting_line('bottle_receivable',-claim,'lpg',sid)||jsonb_build_object('consolidated_amount',-consolidated_claim),
  app_private.accounting_line('cogs',claim,'lpg')||jsonb_build_object('consolidated_amount',consolidated_claim)));
 select coalesce(sum(l.amount),0),coalesce(sum(l.consolidated_amount),0) into variance,consolidated_variance
 from public.accounting_lines l join public.accounting_journals j using(tenant_id,journal_id)
 join public.inventory_movements m on m.tenant_id=j.tenant_id and m.movement_id=j.source_id
 where l.tenant_id=t and l.account='bottle_exchange' and j.source='inventory' and m.reference_type='sale' and m.reference_id=sid;
 perform app_private.sync_journal(t,'sale_exchange_reversal',sid,d,'Reverse cancelled cylinder exchange difference',jsonb_build_array(
  app_private.accounting_line('bottle_exchange',-variance,'lpg',sid)||jsonb_build_object('consolidated_amount',-consolidated_variance),
  app_private.accounting_line('cogs',variance,'lpg')||jsonb_build_object('consolidated_amount',consolidated_variance)));
end$$;

create or replace function app_private.fifo_take(t uuid,id uuid,mid uuid,part text,qty integer)
returns numeric language plpgsql set search_path='' as $$
declare r record;n integer:=qty;take integer;v numeric;shell numeric;iv numeric;isv numeric;total numeric:=0;
begin
 for r in select * from app_private.fifo_layers where tenant_id=t and item_id=id and component=part and remaining>0 order by acquired_at,acquired_order,slice_no,layer_id for update loop
  exit when n=0;take:=least(n,r.remaining);
  v:=case when take=r.remaining then r.remaining_value else round(r.remaining_value*take/r.remaining,2) end;
  shell:=case when take=r.remaining then r.remaining_shell_value else round(r.remaining_shell_value*take/r.remaining,2) end;
  iv:=case when take=r.remaining then r.remaining_internal_value else round(r.remaining_internal_value*take/r.remaining,2) end;
  isv:=case when take=r.remaining then r.remaining_internal_shell_value else round(r.remaining_internal_shell_value*take/r.remaining,2) end;
  update app_private.fifo_layers set remaining=remaining-take,remaining_value=remaining_value-v,remaining_shell_value=remaining_shell_value-shell,remaining_internal_value=remaining_internal_value-iv,remaining_internal_shell_value=remaining_internal_shell_value-isv where tenant_id=t and layer_id=r.layer_id;
  insert into app_private.fifo_consumptions(tenant_id,movement_id,layer_id,quantity,value,shell_value,internal_value,internal_shell_value) values(t,mid,r.layer_id,take,v,shell,iv,isv);
  total:=total+v;n:=n-take;
 end loop;
 if n<>0 then raise exception 'Insufficient FIFO % stock for product',part;end if;return total;
end$$;

create or replace function app_private.fifo_component_layer(t uuid,id uuid,mid uuid,part text,at_time timestamptz,qty integer,cost numeric,shell numeric,internal_cost numeric,internal_shell numeric,slice integer default 0,shell_source uuid default null,shell_time timestamptz default null)
returns void language plpgsql set search_path='' as $$
begin
 if qty<=0 then return;end if;
 if cost<0 or shell<0 or shell>cost or internal_cost<0 or internal_shell<0 or internal_shell>internal_cost then raise exception 'Invalid component acquisition evidence';end if;
 insert into app_private.fifo_layers(tenant_id,item_id,movement_id,component,acquired_at,acquired_order,quantity,remaining,value,remaining_value,shell_value,remaining_shell_value,internal_value,remaining_internal_value,internal_shell_value,remaining_internal_shell_value,slice_no,shell_source_movement_id,shell_acquired_at)
 values(t,id,mid,part,at_time,(select movement_no from public.inventory_movements where tenant_id=t and movement_id=mid),qty,qty,cost,cost,shell,shell,internal_cost,internal_cost,internal_shell,internal_shell,slice,coalesce(shell_source,mid),coalesce(shell_time,at_time));
end$$;

create or replace function app_private.snapshot_inventory_components()
returns trigger language plpgsql set search_path='' as $$
declare price numeric;
begin
 if new.reference_type='sale' and new.empty_quantity_change>0 then
  select new_price into price from public.product_buying_price_history where tenant_id=new.tenant_id and item_id=new.item_id and price_type='bottle' and effective_at<=new.created_at order by effective_at desc,entry_no desc limit 1;
  if price is null then raise exception 'Set this received brand''s Bottle buying price before accepting its empty cylinders';end if;
  new.valuation:=coalesce(new.valuation,'{}'::jsonb)||jsonb_build_object('bottle_unit_cost',price);
 end if;
 if new.valuation->>'counter_account' is not null and new.filled_quantity_change>0 and exists(select 1 from public.items where tenant_id=new.tenant_id and item_id=new.item_id and business_category='lpg') then
  if new.valuation->>'filled_shell_unit_cost' is null then raise exception 'A valued filled-stock contribution requires its Gas and Bottle acquisition split';end if;
 end if;
 return new;
end$$;
create trigger inventory_component_snapshot before insert on public.inventory_movements for each row execute function app_private.snapshot_inventory_components();

create or replace function app_private.fifo_cost_movement(m public.inventory_movements)
returns void language plpgsql set search_path='' as $$
declare
 c public.inventory_costs;old_cost app_private.fifo_movement_costs;p public.purchases;
 cat text;account text;counter text:='cogs';fc numeric:=0;ec numeric:=0;shell numeric:=0;iv numeric:=0;isv numeric:=0;
 gas_value numeric:=0;gas_internal numeric:=0;bottle_value numeric:=0;bottle_internal numeric:=0;
 gas_piece numeric;gas_internal_piece numeric;basis numeric:=0;variance numeric:=0;expected integer;prior_qty integer;counted integer:=0;slice integer:=0;
 lines jsonb;batch record;component record;f_after numeric;e_after numeric;
 d date:=(m.created_at at time zone 'Asia/Dhaka')::date;
begin
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
    order by l.acquired_at,l.acquired_order,l.slice_no for update of l loop
    if batch.remaining<>batch.quantity or batch.remaining_value<>batch.value or batch.remaining_internal_value<>batch.internal_value then raise exception 'The original received batch has been consumed or changed; cancellation cannot substitute other stock';end if;
    counted:=counted+batch.quantity;
    if batch.component='empty' then ec:=ec-batch.remaining_value;else fc:=fc-batch.remaining_value;end if;
    insert into app_private.fifo_consumptions(tenant_id,movement_id,layer_id,quantity,value,shell_value,internal_value,internal_shell_value) values(m.tenant_id,m.movement_id,batch.layer_id,batch.quantity,batch.value,batch.shell_value,batch.internal_value,batch.internal_shell_value);
    update app_private.fifo_layers set remaining=0,remaining_value=0,remaining_shell_value=0,remaining_internal_value=0,remaining_internal_shell_value=0 where tenant_id=m.tenant_id and layer_id=batch.layer_id;
   end loop;
   if counted<>(case when m.reference_type='sale_reversal' then -m.empty_quantity_change else -m.filled_quantity_change end) then raise exception 'Original received quantity does not reconcile';end if;
  end if;
  if m.reference_type='sale_reversal' then
   for batch in select x.* from app_private.fifo_consumptions x join public.inventory_movements im on im.tenant_id=x.tenant_id and im.movement_id=x.movement_id join app_private.fifo_layers l on l.tenant_id=x.tenant_id and l.layer_id=x.layer_id
    where im.tenant_id=m.tenant_id and im.item_id=m.item_id and im.reference_id=m.reference_id and im.reference_type='sale' and im.filled_quantity_change<0 and l.component='filled' loop
    fc:=fc+batch.value;
    update app_private.fifo_layers set remaining=remaining+batch.quantity,remaining_value=remaining_value+batch.value,remaining_shell_value=remaining_shell_value+batch.shell_value,remaining_internal_value=remaining_internal_value+batch.internal_value,remaining_internal_shell_value=remaining_internal_shell_value+batch.internal_shell_value where tenant_id=m.tenant_id and layer_id=batch.layer_id;
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
    -- Dispatched bottles retain their original source and age in linked slices.
    for batch in select x.*,l.acquired_at,l.shell_acquired_at,l.shell_source_movement_id,l.movement_id source_movement from app_private.fifo_consumptions x
     join app_private.fifo_layers l using(tenant_id,layer_id) join public.inventory_movements im on im.tenant_id=x.tenant_id and im.movement_id=x.movement_id
     where im.tenant_id=m.tenant_id and im.item_id=m.item_id and im.reference_id=m.reference_id and im.reference_type='purchase_dispatch'
     order by l.acquired_at,l.acquired_order,l.slice_no loop
     gas_piece:=round(gas_value*(counted+batch.quantity)/m.filled_quantity_change,2)-round(gas_value*counted/m.filled_quantity_change,2);
     gas_internal_piece:=round(gas_internal*(counted+batch.quantity)/m.filled_quantity_change,2)-round(gas_internal*counted/m.filled_quantity_change,2);
     perform app_private.fifo_component_layer(m.tenant_id,m.item_id,m.movement_id,'filled',m.created_at,batch.quantity,gas_piece+batch.value,batch.value,gas_internal_piece+batch.internal_value,batch.internal_value,slice,coalesce(batch.shell_source_movement_id,batch.source_movement),coalesce(batch.shell_acquired_at,batch.acquired_at));
     counted:=counted+batch.quantity;slice:=slice+1;fc:=fc+batch.value;
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
   for batch in select x.* from app_private.fifo_consumptions x join public.inventory_movements im on im.tenant_id=x.tenant_id and im.movement_id=x.movement_id where im.tenant_id=m.tenant_id and im.item_id=m.item_id and im.reference_id=m.reference_id and im.reference_type='purchase_dispatch' loop
    ec:=ec+batch.value;counted:=counted+batch.quantity;
    update app_private.fifo_layers set remaining=remaining+batch.quantity,remaining_value=remaining_value+batch.value,remaining_shell_value=remaining_shell_value+batch.shell_value,remaining_internal_value=remaining_internal_value+batch.internal_value,remaining_internal_shell_value=remaining_internal_shell_value+batch.internal_shell_value where tenant_id=m.tenant_id and layer_id=batch.layer_id;
    insert into app_private.fifo_consumptions(tenant_id,movement_id,layer_id,quantity,value,shell_value,internal_value,internal_shell_value) values(m.tenant_id,m.movement_id,batch.layer_id,-batch.quantity,-batch.value,-batch.shell_value,-batch.internal_value,-batch.internal_shell_value);
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
    select coalesce(sum(l.amount),0),coalesce(sum(l.consolidated_amount),0) into shell,gas_value from public.accounting_lines l join public.accounting_journals j using(tenant_id,journal_id) where l.tenant_id=m.tenant_id and l.account='bottle_receivable' and l.entity_id=m.reference_id and j.source='bottle_obligation';
    basis:=case when expected>0 then round(shell*least(expected,prior_qty+m.empty_quantity_change)/expected,2)-round(shell*least(expected,prior_qty)/expected,2) else 0 end;
    gas_value:=case when expected>0 then round(gas_value*least(expected,prior_qty+m.empty_quantity_change)/expected,2)-round(gas_value*least(expected,prior_qty)/expected,2) else 0 end;
    lines:=jsonb_build_array(app_private.accounting_line(account,ec,cat,m.item_id),app_private.accounting_line('bottle_receivable',-basis,cat,m.reference_id)||jsonb_build_object('consolidated_amount',-gas_value),app_private.accounting_line('bottle_exchange',basis-ec,cat,m.reference_id)||jsonb_build_object('consolidated_amount',gas_value-ec));
   end if;
  else raise exception 'Stock movement requires recorded acquisition evidence';end if;
  if m.empty_quantity_change>0 and m.reference_type<>'purchase_cancellation' then perform app_private.fifo_component_layer(m.tenant_id,m.item_id,m.movement_id,'empty',m.created_at,m.empty_quantity_change,ec,ec,0,0);end if;
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
 if lines is null then lines:=jsonb_build_array(app_private.accounting_line(account,fc+ec,cat,m.item_id),app_private.accounting_line(counter,-fc-ec,cat,m.reference_id));end if;
 perform app_private.sync_journal(m.tenant_id,'inventory',m.movement_id,d,coalesce(m.notes,'FIFO component carrying cost'),lines,counter='opening_equity');
 perform app_private.sync_internal_fifo(m);
end$$;

create or replace function app_private.guard_wallet_archive()
returns trigger language plpgsql set search_path='' as $$
begin
 if not new.is_active and new.balance<>0 then raise exception 'Clear the wallet balance before archiving';end if;return new;
end$$;

create or replace function public.move_wallet_money(p_payload jsonb,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 t uuid:=app_private.require_permission('finance:manage');prior public.finance_requests;body jsonb:=p_payload||jsonb_build_object('actor',auth.uid());
 src uuid:=(p_payload->>'wallet_id')::uuid;dest uuid:=(p_payload->>'destination_id')::uuid;a numeric:=(p_payload->>'amount')::numeric;
 action text:=p_payload->>'action';reason text:=trim(p_payload->>'reason');b text:=p_payload->>'business';result jsonb;
 d date:=coalesce((p_payload->>'date')::date,(now() at time zone 'Asia/Dhaka')::date);
begin
 perform app_private.require_permission(case when action='transfer' then 'wallets:transfer' else 'wallets:adjust' end);
 if p_request_id is null then raise exception 'Request ID is required';end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from body then raise exception 'Request ID already used with different details';end if;return prior.result;end if;
 if action is null or action not in ('transfer','adjustment') or reason is null or length(reason) not between 3 and 500 or jsonb_typeof(p_payload->'amount') is distinct from 'number' or a=0 or abs(a)<>app_private.purchase_money(abs(a)) or not isfinite(d) or d>(now() at time zone 'Asia/Dhaka')::date then raise exception 'Choose a valid operation, amount, date and reason';end if;
 perform 1 from public.wallets where tenant_id=t and wallet_id in(src,dest) order by wallet_id for update;
 if not exists(select 1 from public.wallets where tenant_id=t and wallet_id=src and is_active) then raise exception 'Active source wallet not found';end if;
 if action='transfer' then
  if p_payload-array['action','wallet_id','destination_id','amount','date','reason']<>'{}'::jsonb or a<0 or dest is null or src=dest then raise exception 'Choose two different wallets and a positive transfer principal';end if;
  if not exists(select 1 from public.wallets where tenant_id=t and wallet_id=dest and is_active) then raise exception 'Active destination wallet not found';end if;
  insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,description,counterparty_wallet_id,operation_id,accounting_date) values
   (t,src,-a,'wallet_transfer',reason,dest,p_request_id,d),(t,dest,a,'wallet_transfer',reason,src,p_request_id,d);
 else
  if p_payload-array['action','wallet_id','amount','date','reason','business','classification']<>'{}'::jsonb or b is null or b not in ('lpg','stove','logistics') or coalesce(p_payload->>'classification','correction') not in ('correction','capital') then raise exception 'Choose a business and adjustment classification';end if;
  if p_payload->>'classification'='capital' then perform app_private.require_owner('finance:manage');if a<0 then raise exception 'Capital contribution must be positive';end if;end if;
  insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,description,operation_id,accounting_date,allocations)
  values(t,src,a,case p_payload->>'classification' when 'capital' then 'owner_capital' else 'balance_adjustment' end,reason,p_request_id,d,jsonb_build_object(b,100));
 end if;
 result:=jsonb_build_object('operation_id',p_request_id);insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,result,auth.uid());return result;
end$$;

create or replace function app_private.settle_internal_transport(t uuid,pid uuid,d date,reverse_entry boolean default false)
returns void language plpgsql set search_path='' as $$
declare p public.purchases;s app_private.internal_transport_settlements;v numeric;lines jsonb;
begin
 select * into p from public.purchases where tenant_id=t and purchase_id=pid for update;
 select * into s from app_private.internal_transport_settlements where tenant_id=t and purchase_id=pid;
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
end$$;

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
 elsif new.type in ('loan_receipt','loan_repayment') then other:='loan_payable';
 elsif new.type in ('asset_purchase','asset_proceeds','asset_disposal_expense') then other:='other_assets';
 else raise exception 'Wallet entry has no accounting classification: %',new.type;end if;
 if other is null then raise exception 'Wallet source is missing';end if;
 select jsonb_agg(line) into entries from jsonb_each_text(new.business_amounts)b cross join lateral(values
  (app_private.accounting_line('cash',b.value::numeric,b.key,new.wallet_id)||jsonb_build_object('type_id',new.type_id)),
  (app_private.accounting_line(other,-b.value::numeric,b.key,entity,jsonb_build_object('type_name',e.type_name))||jsonb_build_object('type_id',new.type_id)))v(line);
 perform app_private.post_journal(new.tenant_id,'wallet',new.transaction_id,'cash',new.accounting_date,new.description,entries,false,new.type='opening_cash');return new;
end $function$;

CREATE OR REPLACE FUNCTION app_private.analysis_entity(t uuid, code text, id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare label text;k text;ref uuid:=id;begin
 if id is null and code='cash' then label:='Pooled business cash';
 elsif id is null then select a.name into label from public.accounting_accounts a where a.code=analysis_entity.code;
 elsif code='cash' then select name,'wallet' into label,k from public.wallets where tenant_id=t and wallet_id=id;
 elsif code in ('inventory_lpg','inventory_stove') then
  select coalesce(i.product_name,concat_ws(' ',b.brand_name,i.size_kg||' kg',i.mouth_size)),'product' into label,k from public.items i left join public.lpg_brands b using(tenant_id,brand_id) where i.tenant_id=t and i.item_id=id;
 elsif code='customer_receivable' then select coalesce(nullif(shop_name,''),name),'customer' into label,k from public.customers where tenant_id=t and customer_id=id;
 elsif code='loan_payable' then select lender,'loan' into label,k from public.loans where tenant_id=t and loan_id=id;
 elsif code in ('vehicles','equipment','other_assets') then select name,'asset' into label,k from public.business_assets where tenant_id=t and asset_id=id;
 elsif code in ('supplier_payable','inventory_transit') then select coalesce(supplier_name,'Supplier')||' · Purchase #'||left(id::text,8),'purchase' into label,k from public.purchases where tenant_id=t and purchase_id=id;
 elsif code='bottle_receivable' then select 'Cylinders · Sale #'||left(id::text,8),'sale' into label,k from public.sales where tenant_id=t and sale_id=id;
 elsif code='supplier_receivable' then select brand_name||' · Supplier advance/refund' into label from public.lpg_brands where tenant_id=t and brand_id=id; 
 elsif code='employee_payable' then select name,'employee' into label,k from public.employees where tenant_id=t and employee_id=id;
 end if;
 if label is null then select description,'obligation' into label,k from public.finance_obligations where tenant_id=t and obligation_id=id;end if;
 if label is null then select 'Journey · '||destination||' #'||left(id::text,8),'transit' into label,k from public.transits where tenant_id=t and transit_id=id;end if;
 if label is null then select a.name into label from public.accounting_accounts a where a.code=analysis_entity.code;end if;
 return jsonb_build_object('entity_name',label,'record_kind',k,'record_id',ref);end $function$;

CREATE OR REPLACE FUNCTION app_private.check_purchase_empties(t uuid, lines jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare x record; shortages jsonb := '[]';
begin
  for x in select i.item_id from public.items i where i.tenant_id=t and i.item_id in
    (select (value->>'item_id')::uuid from jsonb_array_elements(lines))
    order by i.item_id for update loop null; end loop;
  select coalesce(jsonb_agg(jsonb_build_object('item_id',s.item_id,'product',s.product,
    'required',s.required,'available',s.available,'missing',s.required-s.available)),'[]') into shortages
  from (select i.item_id,concat(b.brand_name,' ',i.size_kg,' kg ',i.mouth_size) product,
    sum((app_private.purchase_integer(l.value->'quantity')-app_private.purchase_integer(coalesce(l.value->'bottle_quantity','0'::jsonb)))) required,i.empty_quantity available
    from jsonb_array_elements(lines) l join public.items i on i.tenant_id=t and i.item_id=(l.value->>'item_id')::uuid
    left join public.lpg_brands b on b.tenant_id=i.tenant_id and b.brand_id=i.brand_id
    group by i.item_id,b.brand_name,i.size_kg,i.mouth_size,i.empty_quantity
    having sum((app_private.purchase_integer(l.value->'quantity')-app_private.purchase_integer(coalesce(l.value->'bottle_quantity','0'::jsonb))))>i.empty_quantity) s;
  if jsonb_array_length(shortages)>0 then
    raise exception 'Not enough empty cylinders' using detail=shortages::text;
  end if;
end $function$;

CREATE OR REPLACE FUNCTION app_private.dimension_entries(t uuid, src text, id uuid, entries jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$declare result jsonb;begin
 select coalesce(jsonb_agg(x || jsonb_build_object('amount',s.amount,'consolidated_amount',s.consolidated_amount,
  'business_category',s.business,'type_id',coalesce((x->>'type_id')::uuid,app_private.source_type(t,src,id,x->>'account')))),'[]') into result
 from jsonb_array_elements(entries)x cross join lateral(
 select a.business,a.amount,c.amount consolidated_amount from app_private.allocate_money((x->>'amount')::numeric,
  case when coalesce(x->>'business_category','shared')='shared' then coalesce(x->'allocations',app_private.source_allocation(t,src,id)) else jsonb_build_object(x->>'business_category',100) end)a
 join app_private.allocate_money(coalesce((x->>'consolidated_amount')::numeric,(x->>'amount')::numeric),
  case when coalesce(x->>'business_category','shared')='shared' then coalesce(x->'allocations',app_private.source_allocation(t,src,id)) else jsonb_build_object(x->>'business_category',100) end)c using(business)
 )s where s.amount<>0 or s.consolidated_amount<>0;
 return result;
end $function$;

CREATE OR REPLACE FUNCTION app_private.finance_analysis_report(p_filters jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare ids uuid[]:=app_private.analysis_scope(p_filters);f date:=(p_filters->>'from')::date;u date:=(p_filters->>'to')::date;cat text:=coalesce(p_filters->>'category','all');
 grain text:=coalesce(p_filters->>'grain','month');opening jsonb;closing jsonb;result jsonb;r record;coverage boolean;estimated boolean;missing bigint;original boolean:=coalesce((p_filters->>'all_time')::boolean,false);begin

 if f is null or u is null or not isfinite(f) or not isfinite(u) or f>u or u>(now() at time zone 'Asia/Dhaka')::date or u-f>36525 or grain not in ('day','month','year') or grain='day' and u-f>730 or cat not in ('all','lpg','stove','logistics') then raise exception 'Choose a valid reporting period and business activity';end if;
 if original then select min((started_at at time zone 'Asia/Dhaka')::date) into f from public.accounting_periods where tenant_id=any(ids);f:=least(f,u);if grain='day' and u-f>730 then grain:='month';end if;end if;
 select bool_and(true),bool_or(a.estimated) into coverage,estimated from public.accounting_periods a where tenant_id=any(ids);
 select count(*) into missing from public.vehicles v where v.tenant_id=any(ids) and v.availability<>'retired' and not exists(select 1 from public.business_assets a where a.tenant_id=v.tenant_id and a.vehicle_id=v.vehicle_id);
 coverage:=coalesce(coverage,false) and missing=0;
 opening:=app_private.scoped_position(ids,f,cat,true,original);closing:=app_private.scoped_position(ids,u,cat);
 with period_lines as materialized(
 select j.tenant_id,j.journal_id,j.occurred_on,j.source,j.source_id,j.description,l.account,case when cat='all' then l.consolidated_amount else l.amount end amount,l.amount business_amount,l.business_category,l.entity_id,a.kind,a.name
 from public.accounting_journals j join public.accounting_lines l using(tenant_id,journal_id) join public.accounting_accounts a on a.code=l.account
 where j.tenant_id=any(ids) and j.occurred_on between f and u and not j.is_opening),
 attributed as materialized(select * from period_lines where cat='all' or business_category=cat),
 totals as(select coalesce(-sum(amount) filter(where kind='income'),0) revenue,coalesce(sum(amount) filter(where kind='expense'),0) expenses,
 coalesce(-sum(amount) filter(where account='capital'),0) contributions,coalesce(sum(amount) filter(where account='withdrawals'),0) withdrawals,
 coalesce(-sum(amount) filter(where account in ('opening_equity','equity_adjustment','business_allocation_equity','retained_earnings')),0)+coalesce((
 select -sum(case when cat='all' then l.consolidated_amount else l.amount end) from public.accounting_journals j join public.accounting_lines l using(tenant_id,journal_id)
 where j.tenant_id=any(ids) and j.is_opening and j.occurred_on>=f and j.occurred_on<=u and not(original and j.occurred_on=f)
 and l.account in ('opening_equity','equity_adjustment','business_allocation_equity','retained_earnings','capital') and (cat='all' or l.business_category=cat)),0) equity_adjustments,
 coalesce(sum(amount) filter(where account='cash' and amount>0 and description is not null and source='wallet'),0) gross_cash_in,
 coalesce(-sum(amount) filter(where account='cash' and amount<0 and source='wallet'),0) gross_cash_out from attributed),
 cash as materialized(select l.*,x.type,
 case when x.type='custom_entry' then (select case when e.account in ('capital','withdrawals') then 'financing' when e.account in ('equipment','other_assets') then 'investing' else 'operating' end from public.financial_entries e where e.tenant_id=x.tenant_id and e.entry_id=x.reference_id) when x.type='obligation_settlement' then coalesce((select o.cash_activity from public.finance_obligations o where o.tenant_id=x.tenant_id and o.obligation_id=x.reference_id),'unclassified') when x.type in ('loan_receipt','loan_repayment','owner_capital','balance_adjustment','owner_withdrawal') then 'financing'
 when x.type in ('asset_purchase','asset_proceeds','asset_disposal_expense') then 'investing' else 'operating' end cash_category
 from attributed l join public.wallet_transactions x on x.tenant_id=l.tenant_id and x.transaction_id=l.source_id where l.account='cash' and l.source='wallet'),
 buckets as(select d::date period from generate_series(date_trunc(grain,f::timestamp),date_trunc(grain,u::timestamp),('1 '||grain)::interval)d),
 activity_trend as(select date_trunc(grain,occurred_on)::date period,coalesce(-sum(amount) filter(where kind='income'),0) revenue,coalesce(sum(amount) filter(where kind='expense'),0) expenses
 from attributed group by 1),
 cash_trend as(select date_trunc(grain,occurred_on)::date period,sum(greatest(0,amount)) cash_in,-sum(least(0,amount)) cash_out,sum(amount) cash_flow from cash group by 1),
 position_events as (
 select b.tenant_id,b.account,case when b.account='cash' then null::uuid else b.entity_id end entity_id,date_trunc(grain,f::timestamp)::date period,case when cat='all' then b.consolidated_amount else b.amount end amount
 from app_private.dimensional_balances(ids,f,true,original)b join public.accounting_accounts a on a.code=b.account where (cat='all' or b.business_category=cat) and a.kind in ('asset','liability')
 union all
 select l.tenant_id,l.account,case when l.account='cash' then null::uuid else l.entity_id end,date_trunc(grain,j.occurred_on)::date,case when cat='all' then l.consolidated_amount else l.amount end
 from public.accounting_journals j join public.accounting_lines l using(tenant_id,journal_id) join public.accounting_accounts a on a.code=l.account
 where j.tenant_id=any(ids) and j.occurred_on between f and u and not(original and j.is_opening and j.occurred_on=f) and (cat='all' or l.business_category=cat) and a.kind in ('asset','liability')),
 position_deltas as(select tenant_id,account,entity_id,period,sum(amount) amount from position_events group by 1,2,3,4),
 position_running as(select *,sum(amount) over(partition by tenant_id,account,entity_id order by period) balance from position_deltas),
 position_changes as(select *,case when account='cash' then balance-lag(balance,1,0::numeric) over(partition by tenant_id,account,entity_id order by period) else greatest(balance,0)-greatest(lag(balance,1,0::numeric) over(partition by tenant_id,account,entity_id order by period),0) end asset_change,
 case when account='cash' then 0 else -least(balance,0)+least(lag(balance,1,0::numeric) over(partition by tenant_id,account,entity_id order by period),0) end liability_change from position_running),
 position_trend as(select period,sum(asset_change) asset_change,sum(liability_change) liability_change from position_changes group by period),
 trend as(select b.period,greatest(f,b.period) period_start,least(u,(b.period+('1 '||grain)::interval-interval '1 day')::date) period_end,
 coalesce(a.revenue,0) revenue,coalesce(a.expenses,0) expenses,coalesce(a.revenue,0)-coalesce(a.expenses,0) profit,
 coalesce(c.cash_in,0) cash_in,coalesce(c.cash_out,0) cash_out,coalesce(c.cash_flow,0) cash_flow,
 sum(coalesce(p.asset_change,0)) over(order by b.period) assets,sum(coalesce(p.liability_change,0)) over(order by b.period) liabilities,
 sum(coalesce(p.asset_change,0)-coalesce(p.liability_change,0)) over(order by b.period) net_worth
 from buckets b left join activity_trend a using(period) left join cash_trend c using(period) left join position_trend p using(period)),
 categories as(select account,name,kind,sum(case when kind='income' then -amount else amount end) amount from attributed where kind in ('income','expense') group by 1,2,3),
 business as(select tenant_id,business_category,coalesce(-sum(business_amount) filter(where kind='income'),0) revenue,coalesce(sum(business_amount) filter(where kind='expense'),0) expenses from period_lines where kind in ('income','expense') group by 1,2)
 select jsonb_build_object('from',f,'to',u,'category',cat,'opening',opening,'closing',closing,'complete',coverage,'estimated',estimated,'missing_asset_values',missing,
 'coverage',coalesce((select jsonb_agg(jsonb_build_object('tenant_id',a.tenant_id,'started_at',a.started_at,'note',a.opening_note)) from public.accounting_periods a where a.tenant_id=any(ids)),'[]'),
 'totals',jsonb_build_object('revenue',revenue,'expenses',expenses,'profit',case when coverage then revenue-expenses end,
 'contributions',contributions,'withdrawals',withdrawals,'equity_adjustments',equity_adjustments,
 'cash_in',coalesce((select sum(amount) from cash where amount>0),0),'cash_out',coalesce((select -sum(amount) from cash where amount<0),0),
 'cash_flow',coalesce((select sum(amount) from cash),0),'transfers',case when cat='all' then coalesce((select sum(x.amount) from public.wallet_transactions x where x.tenant_id=any(ids) and x.type='wallet_transfer' and x.amount>0 and x.accounting_date between f and u),0) else 0 end,
 'position_profit',case when coverage then (closing->>'assets')::numeric-(closing->>'liabilities')::numeric-(opening->>'assets')::numeric+(opening->>'liabilities')::numeric-contributions+withdrawals-equity_adjustments end),
 'categories',coalesce((select jsonb_agg(to_jsonb(c) order by kind,amount desc) from categories c),'[]'),
 'cash_categories',coalesce((select jsonb_agg(to_jsonb(c)) from(select cash_category category,sum(greatest(0,amount)) received,-sum(least(0,amount)) spent,sum(amount) net from cash group by cash_category)c),'[]'),
 'trend',coalesce((select jsonb_agg(to_jsonb(t) order by period) from trend t),'[]'),
 'businesses',coalesce((select jsonb_agg(to_jsonb(b)) from business b),'[]'),
 'all_time',original,'period_income',(closing->>'accumulated_income')::numeric-(opening->>'accumulated_income')::numeric,
 'invested_capital',closing->'capital','retained_earnings',(closing->>'accumulated_income')::numeric+coalesce((closing->>'historical_earnings')::numeric,0),'capital_recorded',closing->'capital','withdrawals_to_date',closing->'withdrawals') into result from totals;
 return result||jsonb_build_object('business_positions',(select jsonb_agg(jsonb_build_object('category',b,'opening',case when b=cat then opening else app_private.scoped_position(ids,f,b,true,original) end,'closing',case when b=cat then closing else app_private.scoped_position(ids,u,b) end)) from unnest(array['lpg','stove','logistics','all'])b),'period_values',app_private.period_financial_values(p_filters||jsonb_build_object('from',result->>'from')));end $function$;

CREATE OR REPLACE FUNCTION app_private.financial_source_link(t uuid, src text, id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$declare
 k text;ref uuid:=id;x public.wallet_transactions;m public.inventory_movements;cost_event public.operating_cost_events;result_id uuid;begin
 if src in ('sale','sale_bottle_claim_reversal','sale_exchange_reversal') then k:='sale';
 elsif src in ('purchase','internal_transport') then k:='purchase';
 elsif src in ('inventory','bottle_obligation','internal_inventory','internal_cogs') then
  select * into m from public.inventory_movements where tenant_id=t and movement_id=id;
  ref:=m.reference_id;k:=case when m.reference_type in ('sale','sale_reversal') then 'sale' when m.reference_type like '%purchase%' then 'purchase' else 'product' end;if k='product' then ref:=m.item_id;end if;
 elsif src='transit_revenue' then k:='transit';
 elsif src='operating_cost' then select * into cost_event from public.operating_cost_events where tenant_id=t and event_id=id;ref:=cost_event.transit_id;k:='transit';
 elsif src='salary_accrual' then select employee_id into ref from app_private.salary_business_allocations where tenant_id=t and source_id=id;k:='employee';
 elsif src='bonus' then select employee_id into ref from public.employee_payments where tenant_id=t and payment_id=id;k:='employee';
 elsif src='owner_operation' then
  select (result->>'id')::uuid into result_id from public.finance_requests where tenant_id=t and request_id=id;ref:=result_id;
  if exists(select 1 from public.business_assets where tenant_id=t and asset_id=ref) then k:='asset';elsif exists(select 1 from public.loans where tenant_id=t and loan_id=ref) then k:='loan';end if;
 elsif src='wallet' then
  select * into x from public.wallet_transactions where tenant_id=t and transaction_id=id;ref:=x.reference_id;
  if x.type in ('pos_sale_income','customer_collection','sale_refund') then k:='sale';
  elsif x.type like 'purchase%' then k:='purchase';
  elsif x.type like 'transit_%' then k:='transit';
  elsif x.type like 'payroll_%' then select p.employee_id into ref from public.employee_payment_entries e join public.employee_payments p using(tenant_id,payment_id) where e.tenant_id=t and e.entry_id=x.employee_entry_id;k:='employee';
  elsif x.type like 'asset_%' then k:='asset';elsif x.type like 'loan_%' then k:='loan';
  elsif x.type='custom_entry' or exists(select 1 from public.financial_entries where tenant_id=t and entry_id=ref) then k:='financial_entry';end if;
 end if;
 return case when k is not null and ref is not null then jsonb_build_object('record_kind',k,'record_id',ref) else '{}'::jsonb end;
end $function$;

CREATE OR REPLACE FUNCTION app_private.period_financial_values(p_filters jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$declare
 ids uuid[]:=app_private.analysis_scope(p_filters);cat text:=coalesce(p_filters->>'category','all');r jsonb;begin
 with lines as(select j.source,l.account,case when cat='all' then l.consolidated_amount else l.amount end amount,t.code,t.origin
 from public.accounting_journals j join public.accounting_lines l using(tenant_id,journal_id) join public.financial_types t using(type_id)
 where j.tenant_id=any(ids) and j.occurred_on between (p_filters->>'from')::date and (p_filters->>'to')::date and not j.is_opening and (cat='all' or l.business_category=cat))
 select jsonb_build_object(
 'stock_acquisitions',coalesce(sum(case when account='inventory_transit' and code in ('purchase','internal_transport') then amount when account in ('inventory_lpg','inventory_stove') and code in ('inventory_capital','inventory_gain') then amount else 0 end),0),
 'stock_change',coalesce(sum(amount) filter(where account in ('inventory_lpg','inventory_stove','inventory_transit','bottle_receivable')),0),
 'equipment_acquisitions',coalesce(sum(amount) filter(where account in ('equipment','vehicles','other_assets') and (code in ('asset_register','asset_improve') or origin='custom') and amount>0),0),
 'receivable_change',coalesce(sum(amount) filter(where account in ('customer_receivable','transport_receivable','supplier_receivable')),0),
 'payable_change',coalesce(-sum(amount) filter(where account in ('supplier_payable','employee_payable','operating_payable','other_liability')),0),
 'loan_movement',coalesce(-sum(amount) filter(where account='loan_payable'),0),
 'wallet_movement',coalesce(sum(amount) filter(where account='cash'),0)) into r from lines;return r;end $function$;

CREATE OR REPLACE FUNCTION app_private.position_from_balances(balances jsonb)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
 with b as(select x.tenant_id,x.account,case when x.account='cash' then null::uuid else x.entity_id end entity_id,a.name,a.kind,sum(x.amount) balance from jsonb_to_recordset(balances)x(tenant_id uuid,account text,entity_id uuid,amount numeric) join public.accounting_accounts a on a.code=x.account group by 1,2,3,4,5),
 classified as(select *,case when kind='liability' and balance>0 then 'asset' when kind='asset' and account<>'cash' and balance<0 then 'liability' else kind end reported_kind from b),
 s as(select tenant_id,account,name,kind,reported_kind,case when account='cash' then entity_id end entity_id,sum(balance) balance from classified group by 1,2,3,4,5,6)
 select jsonb_build_object('assets',coalesce(sum(s.balance) filter(where reported_kind='asset'),0),'liabilities',coalesce(-sum(s.balance) filter(where reported_kind='liability'),0),
 'equity',coalesce(-sum(s.balance) filter(where s.kind in ('equity','income','expense')),0),'cash',coalesce(sum(s.balance) filter(where account='cash'),0),
 'capital',coalesce(-sum(s.balance) filter(where account in ('capital','opening_equity')),0),
 'revenue',coalesce(-sum(s.balance) filter(where s.kind='income'),0),'expenses',coalesce(sum(s.balance) filter(where s.kind='expense'),0),
 'withdrawals',coalesce(sum(s.balance) filter(where account='withdrawals'),0),'other_equity',coalesce(-sum(s.balance) filter(where account in ('equity_adjustment','business_allocation_equity','retained_earnings')),0),
 'historical_earnings',coalesce(-sum(s.balance) filter(where account='retained_earnings'),0),'accumulated_income',coalesce(-sum(s.balance) filter(where s.kind in ('income','expense')),0),
 'accounts',coalesce(jsonb_agg(jsonb_build_object('tenant_id',s.tenant_id,'account',account,'name',s.name,'kind',reported_kind,'entity_id',s.entity_id,'entity_name',case when account='cash' then 'Pooled business cash' else w.name end,
 'amount',case when reported_kind in ('asset','expense') then s.balance else -s.balance end) order by reported_kind,s.name,s.tenant_id,s.entity_id) filter(where s.balance<>0),'[]'))
 from s left join public.wallets w on w.tenant_id=s.tenant_id and w.wallet_id=s.entity_id and account='cash';$function$;

CREATE OR REPLACE FUNCTION app_private.post_wallet_entry()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
 if new.amount is null or new.amount in ('NaN'::numeric,'Infinity'::numeric,'-Infinity'::numeric) then raise exception 'Invalid wallet amount'; end if;
 select name,kind into new.wallet_name_snapshot,new.wallet_method_snapshot from public.wallets where tenant_id=new.tenant_id and wallet_id=new.wallet_id;
 new.created_by:=auth.uid();
 update public.wallets set balance=balance+new.amount,updated_at=clock_timestamp() where tenant_id=new.tenant_id and wallet_id=new.wallet_id and is_active returning balance into new.balance_after;
 if not found then raise exception 'Wallet not found'; end if;
 new.created_at:=clock_timestamp();
 select lower(concat_ws(' ',new.description,new.type,new.reference_id,new.operation_id,new.transaction_id,w.name,sp.reference,c.name,c.phone,c.shop_name))
 into new.search_document from public.wallets w
 left join public.sale_payments sp on sp.tenant_id=new.tenant_id and sp.payment_id=new.payment_id
 left join public.sales s on s.tenant_id=new.tenant_id and s.sale_id=case when new.type='sale_bottle_expense' then new.reference_id else sp.sale_id end
 left join public.customers c on c.tenant_id=new.tenant_id and c.customer_id=s.customer_id
 where w.tenant_id=new.tenant_id and w.wallet_id=new.wallet_id;
 return new;
end $function$;

CREATE OR REPLACE FUNCTION app_private.rebuild_fifo_set(t uuid, ids uuid[])
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$declare m public.inventory_movements;r record;begin
 -- Callers already hold item locks in UUID order. Never acquire a purchase or
 -- snapshot lock here: journal invalidation is always the final lock boundary.
 perform 1 from public.items where tenant_id=t and item_id=any(ids) order by item_id for update;
 delete from app_private.fifo_consumptions where tenant_id=t and layer_id in(select layer_id from app_private.fifo_layers where tenant_id=t and item_id=any(ids));
 delete from app_private.fifo_layers where tenant_id=t and item_id=any(ids);
 update public.inventory_costs set filled_quantity=0,empty_quantity=0,filled_value=0,empty_value=0 where tenant_id=t and item_id=any(ids);
 for m in select im.* from public.inventory_movements im where im.tenant_id=t and im.item_id=any(ids) order by im.created_at,case when im.reference_type='sale' then (select min(x.movement_no) from public.inventory_movements x where x.tenant_id=t and x.reference_type='sale' and x.reference_id=im.reference_id) else im.movement_no end,case when im.reference_type='sale' and im.filled_quantity_change<0 then 0 else 1 end,im.movement_no loop perform app_private.fifo_cost_movement(m);end loop;
 for r in select s.sale_id,(s.created_at at time zone 'Asia/Dhaka')::date d from public.sale_reversals s where s.tenant_id=t and exists(select 1 from public.inventory_movements im where im.tenant_id=t and im.reference_id=s.sale_id and im.reference_type='sale' and im.item_id=any(ids)) loop perform app_private.sync_sale_bottle_reversal(t,r.sale_id,r.d);end loop;
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
   'journal_value',coalesce((select sum(consolidated_amount) from public.accounting_lines where tenant_id=t and entity_id=id and account in ('inventory_lpg','inventory_stove')),0),
   'missing_movements',(select count(*) from public.inventory_movements m where m.tenant_id=t and m.item_id=id and not exists(select 1 from public.inventory_cost_entries e where e.tenant_id=t and e.movement_id=m.movement_id))) into expected from public.inventory_cost_entries where tenant_id=t and item_id=id;
 observed:=observed||jsonb_build_object('fifo_consistent',
  not exists(select 1 from app_private.fifo_layers l left join lateral(select coalesce(sum(x.quantity),0) q,coalesce(sum(x.value),0) v,coalesce(sum(x.shell_value),0) s from app_private.fifo_consumptions x where x.tenant_id=t and x.layer_id=l.layer_id)x on true where l.tenant_id=t and l.item_id=id and (l.quantity<>l.remaining+x.q or l.value<>l.remaining_value+x.v or l.shell_value<>l.remaining_shell_value+x.s))
  and coalesce((select c.filled_quantity=x.f and c.empty_quantity=x.e and c.filled_value=x.fv and c.empty_value=x.ev from public.inventory_costs c cross join lateral(select coalesce(sum(remaining) filter(where component='filled'),0) f,coalesce(sum(remaining) filter(where component='empty'),0) e,coalesce(sum(remaining_value) filter(where component='filled'),0) fv,coalesce(sum(remaining_value) filter(where component='empty'),0) ev from app_private.fifo_layers where tenant_id=t and item_id=id and remaining>0)x where c.tenant_id=t and c.item_id=id),true));
 expected:=expected||jsonb_build_object('fifo_consistent',true);
 elsif k='loan' then
  perform 1 from public.loans where tenant_id=t and loan_id=id for update nowait;
  if not found then return false;end if;
  select jsonb_build_object('outstanding',outstanding) into observed from public.loans where tenant_id=t and loan_id=id;
  select jsonb_build_object('outstanding',principal-coalesce((select sum(amount) from public.loan_activity where tenant_id=t and loan_id=id and action='principal repayment'),0)) into expected from public.loans where tenant_id=t and loan_id=id;
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
  select jsonb_build_object('recognized_invoice',coalesce(sum(l.amount),0)) into observed from public.accounting_journals j join public.accounting_lines l using(tenant_id,journal_id) where j.tenant_id=t and j.source='sale' and j.source_id=id and l.account='customer_receivable';
 elsif k='purchase' then
  perform 1 from public.purchases where tenant_id=t and purchase_id=id for update nowait;
  if not found then return false;end if;
  select jsonb_build_object('recognized_invoice',case when status in ('in_transit','received') then payable_amount else 0 end) into expected from public.purchases where tenant_id=t and purchase_id=id;
  select jsonb_build_object('recognized_invoice',coalesce(-sum(l.amount),0)) into observed from public.accounting_journals j join public.accounting_lines l using(tenant_id,journal_id) where j.tenant_id=t and j.source='purchase' and j.source_id=id and l.account='supplier_payable';
 elsif k='transit' then
  perform 1 from public.transits where tenant_id=t and transit_id=id for update nowait;
  if not found then return false;end if;
  select jsonb_build_object('earned_revenue',case when purchase_id is null and status<>'cancelled' then transport_fee else 0 end,
   'incurred_costs',coalesce((select sum(amount) from public.operating_cost_events where tenant_id=t and transit_id=id),0)) into expected from public.transits where tenant_id=t and transit_id=id;
  select jsonb_build_object('earned_revenue',coalesce((select -sum(l.amount) from public.accounting_journals j join public.accounting_lines l using(tenant_id,journal_id) where j.tenant_id=t and j.source='transit_revenue' and j.source_id=id and l.account='logistics_revenue'),0),
   'incurred_costs',coalesce((select sum(l.amount) from public.operating_cost_events e join public.accounting_journals j on j.tenant_id=e.tenant_id and j.source='operating_cost' and j.source_id=e.event_id join public.accounting_lines l on l.tenant_id=j.tenant_id and l.journal_id=j.journal_id join public.accounting_accounts a on a.code=l.account where e.tenant_id=t and e.transit_id=id and a.kind='expense'),0)) into observed;
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
  id:=new.purchase_id;src:='purchase';d:=(case when new.status='received' then coalesce(new.received_at,new.dispatched_at,new.created_at) else coalesce(new.dispatched_at,new.created_at) end at time zone 'Asia/Dhaka')::date;cat:=coalesce(to_jsonb(new)->>'business_category','lpg');a:=case when new.status in ('in_transit','received') then new.payable_amount else 0 end;
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

CREATE OR REPLACE FUNCTION app_private.source_type(t uuid, src text, id uuid, account text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$declare c text:=src;m public.inventory_movements;e public.operating_cost_events;begin
 if src='wallet' then select type into c from public.wallet_transactions where tenant_id=t and transaction_id=id;
 elsif src='inventory' then
  select * into m from public.inventory_movements where tenant_id=t and movement_id=id;
  c:=case when m.reference_type in ('purchase_receipt','stove_purchase_receipt') then 'purchase_receipt'
   when m.reference_type='purchase_dispatch' then 'purchase_dispatch' when m.reference_type='purchase_cancellation' then 'purchase_cancellation'
   when m.reference_type='stove_purchase_cancellation' then 'stove_purchase_cancellation'
   when m.reference_type='sale_reversal' then 'inventory_return'
   when m.reference_type='sale' then case when m.filled_quantity_change>0 or m.empty_quantity_change>0 then 'bottle_return' else 'inventory_sale' end
   when m.valuation->>'counter_account'='opening_equity' then 'inventory_opening'
   when m.valuation->>'counter_account'='capital' then 'inventory_capital'
   when m.filled_quantity_change<0 or m.empty_quantity_change<0 then 'inventory_loss' else 'inventory_gain' end;
 elsif src='operating_cost' then
  select * into e from public.operating_cost_events where tenant_id=t and event_id=id;
  c:=case when e.service_trip_id is not null then 'vehicle_service' when lower(e.category)='driver earnings' then 'transit_driver'
   when lower(e.category)='helper earnings' then 'transit_helper' when lower(e.category) in ('diesel','oil','fuel') then 'transit_diesel' else 'operating_cost' end;
 elsif src in ('sale_bottle_claim_reversal','sale_exchange_reversal') then c:='sale_reversal'; elsif src='development_opening' then c:='opening';
 elsif src='owner_operation' then
  select coalesce(payload->'body'->>'action',payload->>'action') into c from public.finance_requests where tenant_id=t and request_id=id;
  c:=coalesce(c,case when account='depreciation_expense' then 'asset_depreciate' else 'opening_entry' end);
 elsif src='salary' then c:='salary_accrual';
 end if;
 return app_private.system_type(c);
end $function$;

CREATE OR REPLACE FUNCTION app_private.sync_internal_fifo(m inventory_movements)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$declare
 a numeric:=0;c numeric:=0;cat text;account text;counter text;lines jsonb;begin
 select coalesce(sum(internal_value),0) into a from app_private.fifo_layers where tenant_id=m.tenant_id and movement_id=m.movement_id;
 select coalesce(sum(internal_value),0) into c from app_private.fifo_consumptions where tenant_id=m.tenant_id and movement_id=m.movement_id;
 if a=0 and c=0 and not exists(select 1 from app_private.accounting_source_state where tenant_id=m.tenant_id and source in ('internal_inventory','internal_cogs') and source_id=m.movement_id and revision>0) then return;end if;
 select business_category into cat from public.items where tenant_id=m.tenant_id and item_id=m.item_id;
 account:=case when cat='stove' then 'inventory_stove' else 'inventory_lpg' end;
 counter:=case when m.reference_type in ('purchase_receipt','stove_purchase_receipt','purchase_dispatch','purchase_cancellation') then 'inventory_transit' when m.reference_type='stove_purchase_cancellation' then 'operating_expense' when m.reference_type in ('sale','sale_reversal') then 'cogs' else 'inventory_loss' end;
 lines:=jsonb_build_array(app_private.accounting_line(account,a-c,cat,m.item_id)||jsonb_build_object('consolidated_amount',0),
  app_private.accounting_line(counter,c-a,cat,case when counter='inventory_transit' then m.reference_id end)||jsonb_build_object('consolidated_amount',0));
 perform app_private.sync_journal(m.tenant_id,case when a<>0 then 'internal_inventory' else 'internal_cogs' end,m.movement_id,(m.created_at at time zone 'Asia/Dhaka')::date,'Internal transport FIFO carrying cost',lines);
end $function$;

CREATE OR REPLACE FUNCTION app_private.sync_journal(t uuid, src text, id uuid, d date, note text, target jsonb, opening_entry boolean DEFAULT false)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$declare prior app_private.accounting_source_state;delta jsonb;begin
 target:=app_private.dimension_entries(t,src,id,target);
 insert into app_private.accounting_source_state values(t,src,id,'[]',0) on conflict do nothing;
 select * into prior from app_private.accounting_source_state where tenant_id=t and source=src and source_id=id for update;
 with all_lines as(select x,1 sign from jsonb_array_elements(target)x union all select x,-1 from jsonb_array_elements(prior.lines)x),
 grouped as(select x->>'account' account,x->>'business_category' category,(x->>'entity_id')::uuid entity,(x->>'type_id')::uuid type_id,
  sum(sign*(x->>'amount')::numeric) amount,sum(sign*coalesce((x->>'consolidated_amount')::numeric,(x->>'amount')::numeric)) consolidated_amount from all_lines group by 1,2,3,4)
 select coalesce(jsonb_agg(app_private.accounting_line(account,amount,category,entity)||jsonb_build_object('type_id',type_id,'consolidated_amount',consolidated_amount)) filter(where amount<>0 or consolidated_amount<>0),'[]') into delta from grouped;
 if delta<>'[]' then perform app_private.post_journal(t,src,id,(prior.revision+1)::text,d,note,delta,false,opening_entry);
 update app_private.accounting_source_state set lines=target,revision=revision+1 where tenant_id=t and source=src and source_id=id;end if;
end $function$;

CREATE OR REPLACE FUNCTION app_private.wallet_dimensions()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$declare cat text;a jsonb;p public.employee_payments;begin
 if new.type_id is null then new.type_id:=app_private.system_type(new.type);end if;
 if new.type='wallet_transfer' then
  if new.type_id is null or new.allocations is not null or new.business_amounts is not null then raise exception 'Treasury transfers have no business allocation';end if;return new;
 end if;
 if new.allocations is null then
  if new.type in ('pos_sale_income','customer_collection','sale_refund') then select jsonb_build_object(business_category,100) into a from public.sales where tenant_id=new.tenant_id and sale_id=new.reference_id;
  elsif new.type like 'purchase%' then select jsonb_build_object(business_category,100) into a from public.purchases where tenant_id=new.tenant_id and purchase_id=new.reference_id;
  elsif new.type like 'payroll_%' then
   select ep.* into p from public.employee_payment_entries e join public.employee_payments ep using(tenant_id,payment_id) where e.tenant_id=new.tenant_id and e.entry_id=new.employee_entry_id;
   if p.kind='trips' then a:='{"logistics":100}';else a:=p.allocations;end if;
  elsif new.type like 'transit_%' or new.type like 'vehicle_service_%' then a:='{"logistics":100}';
  elsif new.type in ('loan_receipt','loan_repayment') then select allocations into a from public.loans where tenant_id=new.tenant_id and loan_id=new.reference_id;
  elsif new.type like 'asset_%' then select allocations into a from public.business_assets where tenant_id=new.tenant_id and asset_id=new.reference_id;
  elsif new.type='obligation_settlement' then select allocations into a from public.finance_obligations where tenant_id=new.tenant_id and obligation_id=new.reference_id;
  end if;
  new.allocations:=coalesce(a,'{"lpg":100}'::jsonb);
 end if;
 if new.type_id is null or not coalesce(app_private.valid_business_allocation(new.allocations),false) then raise exception 'Wallet type and business allocation are required';end if;
 if new.business_amounts is null then new.business_amounts:=(select jsonb_object_agg(business,amount) from app_private.allocate_money(new.amount,new.allocations));end if; if not coalesce(app_private.valid_business_amounts(new.amount,new.business_amounts),false) then raise exception 'Business amounts must equal the wallet movement';end if;return new;end $function$;

CREATE OR REPLACE FUNCTION public.adjust_inventory(p_payload jsonb, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_owner('inventory:manage');body jsonb:=jsonb_build_object('action','inventory_adjustment','actor',auth.uid(),'body',p_payload);prior public.finance_requests;
 id uuid:=(p_payload->>'item_id')::uuid;f integer:=(p_payload->>'filled_quantity')::integer;e integer:=coalesce((p_payload->>'empty_quantity')::integer,0);kind text:=p_payload->>'kind';counter text;mid uuid;result jsonb;begin perform app_private.require_permission('inventory:adjust');
 if p_payload->>'date' is not null and (not isfinite((p_payload->>'date')::date) or (p_payload->>'date')::date>(now() at time zone 'Asia/Dhaka')::date) then raise exception 'Invalid stock accounting date';end if; if p_request_id is null then raise exception 'Request ID is required';end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from body then raise exception 'Request ID already used with different details';end if;return prior.result;end if;
 if f is null or f=0 and e=0 or abs(f)>1000000 or abs(e)>1000000 or kind is null or kind not in ('capital','gain','lost','stolen','damaged','other_loss')
 or nullif(trim(p_payload->>'reason'),'') is null or length(p_payload->>'reason')>1000 then raise exception 'Enter quantities, adjustment type and a reason';end if;
 if kind in ('capital','gain') and (f<0 or e<0) or kind in ('lost','stolen','damaged','other_loss') and (f>0 or e>0) then raise exception 'Adjustment quantities do not match its type';end if;
 if (p_payload->>'date')::date<(now() at time zone 'Asia/Dhaka')::date then perform 1 from public.items where tenant_id=t order by item_id for update;end if;perform 1 from public.items where tenant_id=t and item_id=id for update;if not found then raise exception 'Product not found';end if;
 counter:=case kind when 'capital' then 'capital' when 'gain' then 'other_income' else 'inventory_loss' end;
 if f>0 and (p_payload->>'filled_unit_cost') is null or e>0 and (p_payload->>'empty_unit_cost') is null then raise exception 'Unit costs are required for added inventory';end if;
 insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,filled_quantity_change,empty_quantity_change,notes,created_by,valuation,created_at)
 values(t,id,case when f+e>0 then 'adjust_gain' else 'adjust_loss' end,'valued_adjustment',p_request_id,f,e,kind||': '||trim(p_payload->>'reason'),auth.uid(),
 jsonb_build_object('counter_account',counter,'filled_unit_cost',p_payload->'filled_unit_cost','filled_shell_unit_cost',p_payload->'filled_shell_unit_cost','empty_unit_cost',p_payload->'empty_unit_cost'),case when p_payload->>'date' is null or (p_payload->>'date')::date=(now() at time zone 'Asia/Dhaka')::date then clock_timestamp() else ((p_payload->>'date')::date+time '12:00') at time zone 'Asia/Dhaka' end) returning movement_id into mid;
 result:=jsonb_build_object('movement_id',mid);insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,result,auth.uid());return result;end $function$;

CREATE OR REPLACE FUNCTION public.create_custom_transit(p_payload jsonb, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_permission('logistics:manage'); vehicle public.vehicles; id uuid; wid uuid;
 fee numeric:=app_private.purchase_money((p_payload->>'fee')::numeric); prior public.finance_requests;
 body jsonb:=jsonb_build_object('action','custom_transit','actor',auth.uid(),'body',p_payload); result jsonb;
begin perform app_private.require_permission('logistics:transits');
 if p_request_id is null or jsonb_typeof(p_payload) is distinct from 'object' then raise exception 'Transit details and request ID are required'; end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload<>body then raise exception 'Request ID was already used with different details'; end if; return prior.result; end if;
 select * into vehicle from public.vehicles where tenant_id=t and vehicle_id=(p_payload->>'vehicle_id')::uuid for update;
 if not found or vehicle.status<>'idle' then raise exception 'Select a vehicle at Home'; end if;
 if nullif(trim(p_payload->>'client_name'),'') is null or length(p_payload->>'client_name')>200 or nullif(trim(p_payload->>'destination'),'') is null or length(p_payload->>'destination')>300 or length(p_payload->>'description')>1000 then raise exception 'Client and destination are required (up to 200 and 300 characters)'; end if;
 perform 1 from public.employees where tenant_id=t and employee_id in(select employee_id from public.vehicle_assignments where tenant_id=t and vehicle_id=vehicle.vehicle_id and ended_at is null) order by employee_id for update;
 if fee>0 then perform 1 from public.wallets where tenant_id=t and type='cash' and is_active order by wallet_id for update;end if;
 insert into public.transits(tenant_id,vehicle_id,status,transport_fee,client_name,destination,description)
  values(t,vehicle.vehicle_id,'active',fee,trim(p_payload->>'client_name'),trim(p_payload->>'destination'),p_payload->>'description') returning transit_id into id;
 if fee>0 then
  select wallet_id into wid from public.wallets where tenant_id=t and type='cash' and is_active;
  if wid is null then raise exception 'Activate Cash Register before starting this transit'; end if;
  perform public.record_operating_payment(jsonb_build_object('transit_id',id,'kind','client_receipt','payment_date',(now() at time zone 'Asia/Dhaka')::date,
   'payments',jsonb_build_array(jsonb_build_object('wallet_id',wid,'amount',fee))),gen_random_uuid());
 end if;
 update public.vehicles set status='going',updated_at=clock_timestamp() where tenant_id=t and vehicle_id=vehicle.vehicle_id;
 result:=jsonb_build_object('transit_id',id);
 insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,result,auth.uid()); return result;
end $function$;

CREATE OR REPLACE FUNCTION public.create_purchase(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid := app_private.require_permission('purchases:manage'); id uuid; b uuid; request uuid; plant uuid; original jsonb;
begin perform app_private.require_permission('purchases:create');
  if p_payload - array['request_id','business_category','supplier_name','plant_id','vehicle_id','transport_cost','labour_cost','notes','items'] <> '{}'::jsonb then raise exception 'Unsupported purchase fields';end if;
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
    insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details) values(t,id,'created',auth.uid(),jsonb_build_object('business_category','stove','supplier_name',p_payload->>'supplier_name'));
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
  insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details)
    values(t,id,'created',auth.uid(),jsonb_build_object('plant_id',plant,'company_id',b));
  return jsonb_build_object('purchase_id',id);
end $function$;

CREATE OR REPLACE FUNCTION public.dispatch_purchase(p_purchase_id uuid, p_revision integer, p_dispatched_on date DEFAULT NULL::date)
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
  perform app_private.settle_internal_transport(t,p_purchase_id,(dispatch_time at time zone 'Asia/Dhaka')::date); insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details)
    values(t,p_purchase_id,'dispatched',auth.uid(),jsonb_build_object('empty_cylinders',
      (select sum(empty_dispatched) from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id)));
  return jsonb_build_object('purchase_id',p_purchase_id);
end $function$;

CREATE OR REPLACE FUNCTION public.get_accounting_breakdown(p_filters jsonb, p_group text, p_side text, p_mode text DEFAULT 'components'::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$declare
 ids uuid[]:=app_private.analysis_scope(p_filters);d date:=(p_filters->>'to')::date;f date:=(p_filters->>'from')::date;
 cat text:=coalesce(p_filters->>'category','all');original boolean:=false;before_day boolean:=false;r jsonb;begin
 if p_side not in ('opening','closing','period') or p_mode not in ('components','history') or p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100
 or p_group not in ('assets','liabilities','equity','accumulated_income','cash','inventory','receivables','fixed_assets','other_assets','dues','employees','other_liabilities','capital','revenue','expenses','withdrawals','other_equity')
 or f is null or d is null or not isfinite(f) or not isfinite(d) or f>d or d>(now() at time zone 'Asia/Dhaka')::date or length(coalesce(p_filters->>'search',''))>500 or cat not in ('all','lpg','stove','logistics') then raise exception 'Invalid breakdown filters';end if;
 if coalesce((p_filters->>'all_time')::boolean,false) then select min((started_at at time zone 'Asia/Dhaka')::date) into f from public.accounting_periods where tenant_id=any(ids);f:=least(f,d);end if;
 if p_side='opening' then before_day:=true;d:=f;original:=coalesce((p_filters->>'all_time')::boolean,false);end if;
 with evidence as(select *,1 sign from app_private.dimensional_balances(ids,d,before_day,original) union all select *,-1 from app_private.dimensional_balances(ids,f,true,coalesce((p_filters->>'all_time')::boolean,false)) where p_side='period'),
 balances as materialized(select b.tenant_id,b.account,b.business_category,b.type_id,
 case when a.kind in ('income','expense','equity') or b.account='cash' then null else b.entity_id end entity_id,a.kind,a.name,
 sum(b.sign*case when cat='all' then b.consolidated_amount else b.amount end) amount
 from evidence b join public.accounting_accounts a on a.code=b.account where cat='all' or b.business_category=cat group by 1,2,3,4,5,6,7),
 classified as(select *,sum(amount) over(partition by tenant_id,account,entity_id) control_total,case when kind='liability' and sum(amount) over(partition by tenant_id,account,entity_id)>0 then 'asset'
 when kind='asset' and account<>'cash' and sum(amount) over(partition by tenant_id,account,entity_id)<0 then 'liability' else kind end reported_kind from balances),
 selected as materialized(select *,case when p_group='withdrawals' then 1 when p_group in ('equity','accumulated_income') or reported_kind in ('liability','income','equity') then -1 else 1 end sign
 from classified where app_private.analysis_matches(p_group,account,reported_kind)
 and (nullif(p_filters->>'account','') is null or account=p_filters->>'account')
 and (nullif(p_filters->>'type_id','') is null or type_id=(p_filters->>'type_id')::uuid)
 and (nullif(p_filters->>'component_business','') is null or business_category=p_filters->>'component_business')
 and (nullif(p_filters->>'entity_id','') is null or p_filters->>'entity_id'='none' and entity_id is null or entity_id=nullif(nullif(p_filters->>'entity_id',''),'none')::uuid)),
 described as materialized(select s.*,ft.name type_name,app_private.analysis_entity(s.tenant_id,s.account,s.entity_id) entity from selected s join public.financial_types ft using(type_id)),
 components as materialized(select * from described where amount<>0 and (kind in ('income','expense','equity') or control_total<>0) and app_private.finance_search(concat_ws(' ',name,type_name,business_category,entity->>'entity_name'),coalesce(p_filters->>'search',''))),
 component_page as(select * from components order by abs(amount) desc,tenant_id,account,type_id,business_category,entity_id nulls first offset p_offset limit p_limit),
 movements as materialized(select j.tenant_id,j.journal_id,j.entry_no,j.occurred_on,j.description,j.source,j.source_id,j.source_id transaction_reference,j.estimated,l.line_no,l.account,s.name,l.type_id,s.type_name,l.business_category,l.entity_id,
 (case when cat='all' then l.consolidated_amount else l.amount end)*s.sign amount,app_private.analysis_entity(l.tenant_id,l.account,l.entity_id)||app_private.financial_source_link(j.tenant_id,j.source,j.source_id) entity
 from described s join public.accounting_lines l on l.tenant_id=s.tenant_id and l.account=s.account and l.type_id=s.type_id and l.business_category=s.business_category
 and (s.kind in ('income','expense','equity') or s.account='cash' or l.entity_id is not distinct from s.entity_id)
 join public.accounting_journals j on j.tenant_id=l.tenant_id and j.journal_id=l.journal_id
 where p_mode='history' and (p_side<>'period' or j.occurred_on>=f) and (case when before_day then j.occurred_on<d or original and j.is_opening and j.occurred_on=d else j.occurred_on<=d end)
 and (nullif(p_filters->>'history_from','') is null or j.occurred_on>=(p_filters->>'history_from')::date)
 and (nullif(p_filters->>'source','') is null or j.source=p_filters->>'source')
 and app_private.finance_search(concat_ws(' ',j.description,s.name,s.type_name,s.business_category,s.entity->>'entity_name',j.source,j.source_id),coalesce(p_filters->>'search',''))),
 history_page as(select * from movements order by occurred_on desc,entry_no desc,line_no offset p_offset limit p_limit)
 select jsonb_build_object('cutoff',case when before_day and not original then d-1 else d end,'original_opening',original,
 'balance',coalesce((select sum(amount*sign) from selected),0),
 'total',case when p_mode='components' then (select count(*) from components) else (select count(*) from movements) end,
 'filtered_movement',case when p_mode='history' then (select coalesce(sum(amount),0) from movements) end,
 'entries',case when p_mode='components' then coalesce((select jsonb_agg(jsonb_build_object('tenant_id',tenant_id,'account',account,'name',name,'kind',reported_kind,'entity_id',entity_id,'type_id',type_id,'type_name',type_name,'business_category',business_category,'amount',amount*sign)||entity order by abs(amount) desc,tenant_id,account,type_id,business_category,entity_id nulls first) from component_page),'[]')
 else coalesce((select jsonb_agg((to_jsonb(p)-'entity')||entity order by occurred_on desc,entry_no desc,line_no) from history_page p),'[]') end) into r;return r;end $function$;

CREATE OR REPLACE FUNCTION public.get_buying_price_history(p_item_id uuid, p_offset integer DEFAULT 0, p_limit integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_any_permission(array['inventory:view','inventory:manage']);r jsonb;begin
 if p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid history page';end if;
 with page as(select h.*,coalesce(u.full_name,u.email,'System') actor from public.product_buying_price_history h left join app_private.tenant_actors u on u.user_id=h.created_by and u.tenant_id=h.tenant_id where h.tenant_id=t and h.item_id=p_item_id order by h.effective_at desc,h.entry_no desc offset p_offset limit p_limit)
 select jsonb_build_object('total',(select count(*) from public.product_buying_price_history where tenant_id=t and item_id=p_item_id),'entries',coalesce((select jsonb_agg(to_jsonb(p) order by effective_at desc,entry_no desc) from page p),'[]')) into r;return r;end $function$;

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
  'Purchase · '||replace(a.action,'_',' '),coalesce(p.supplier_name,g.plant_name,'Purchase'),null::numeric,a.created_at
  from public.purchase_activity a join public.purchases p using(tenant_id,purchase_id) left join public.gas_plants g on g.tenant_id=p.tenant_id and g.plant_id=p.plant_id
  where a.tenant_id=t and app_private.has_any_permission(array['purchases:view','purchases:manage'])
  order by a.created_at desc,a.activity_id desc limit n)
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

CREATE OR REPLACE FUNCTION public.get_inventory_history(p_filters jsonb DEFAULT '{}'::jsonb, p_offset integer DEFAULT 0, p_limit integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_any_permission(array['inventory:view','inventory:manage']);result jsonb;ids uuid[];
 source text:=coalesce(p_filters->>'source','all');from_day date:=nullif(p_filters->>'from','')::date;to_day date:=nullif(p_filters->>'to','')::date;
 sales_access boolean:=app_private.has_any_permission(array['sales:view','receipts:print']);
begin
 if p_filters is null or jsonb_typeof(p_filters)<>'object' or source not in ('all','sale','purchase')
 or p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100 or from_day>to_day
 or (p_filters ? 'item_ids' and jsonb_typeof(p_filters->'item_ids') not in ('array','null')) then raise exception 'Invalid inventory history filter';end if;
 if jsonb_typeof(p_filters->'item_ids')='array' then
  select coalesce(array_agg(distinct value::uuid),'{}'::uuid[]) into ids from jsonb_array_elements_text(p_filters->'item_ids');
 end if;
 with page as materialized (
  select m.* from public.inventory_movements m where m.tenant_id=t
   and (ids is null or m.item_id=any(ids))
   and (from_day is null or m.created_at>=from_day::timestamp at time zone 'Asia/Dhaka')
   and (to_day is null or m.created_at<(to_day+1)::timestamp at time zone 'Asia/Dhaka')
   and (source='all' or source='sale' and (m.reference_type in ('sale','sale_reversal') or m.movement_type='sale')
    or source='purchase' and (m.reference_type in ('purchase_dispatch','purchase_receipt','purchase_cancellation','stove_purchase_receipt','stove_purchase_cancellation') or m.movement_type in ('purchase','refill','purchase_adjustment')))
  order by m.created_at desc,m.movement_id desc limit p_limit+1 offset p_offset
 ), visible as (select * from page order by created_at desc,movement_id desc limit p_limit)
 select jsonb_build_object('hasMore',(select count(*)>p_limit from page),'entries',coalesce((select jsonb_agg(
  to_jsonb(m)||jsonb_build_object(
   'actor',case when a.user_id is not null then jsonb_build_object('email',a.email) end,
   'items',jsonb_build_object('product_name',i.product_name,'size_kg',i.size_kg,'filled_quantity',i.filled_quantity,
    'empty_quantity',i.empty_quantity,'mouth_size',i.mouth_size,'lpg_brands',case when b.brand_id is not null then jsonb_build_object('brand_id',b.brand_id,'brand_name',b.brand_name) end),
   'saleCustomer',case when sales_access then c.name end) order by m.created_at desc,m.movement_id desc)
  from visible m join public.items i on i.tenant_id=m.tenant_id and i.item_id=m.item_id
  left join public.lpg_brands b on b.tenant_id=i.tenant_id and b.brand_id=i.brand_id
  left join app_private.tenant_actors a on a.tenant_id=m.tenant_id and a.user_id=m.created_by
  left join public.sales s on sales_access and m.reference_type in ('sale','sale_reversal') and s.tenant_id=m.tenant_id and s.sale_id=m.reference_id
  left join public.customers c on c.tenant_id=s.tenant_id and c.customer_id=s.customer_id),'[]'::jsonb)) into result;
 return result;
end $function$;

CREATE OR REPLACE FUNCTION public.get_product_inventory(p_item_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  t uuid := app_private.require_any_permission(array['inventory:view','inventory:manage']);
  as_of timestamptz := clock_timestamp();
  local_today date := (as_of at time zone 'Asia/Dhaka')::date;
  saturday date;
  result jsonb;
begin
  if not exists(select 1 from public.items where tenant_id=t and item_id=p_item_id) then
    raise exception 'Product not found';
  end if;
  saturday := local_today - ((extract(dow from local_today)::integer + 1) % 7);
  with current_prices as (
    select distinct on (customer_tier,price_type) customer_tier,price_type,price,mrp,effective_from
    from public.price_books
    where tenant_id=t and item_id=p_item_id and effective_from<=as_of
      and (effective_to is null or effective_to>as_of)
    order by customer_tier,price_type,effective_from desc
  ), weeks as (
    select (saturday - n*7) start_date,(saturday - n*7 + 7) end_date
    from generate_series(0,7) n
  ), history as (
    select w.start_date,w.end_date-1 end_date,
      coalesce(s.sold_refill,0) sold_refill,coalesce(s.sold_package,0) sold_package,
      coalesce((select sum(l.quantity) from public.sale_bottle_receipt_lines l join public.sale_bottle_receipts r on r.tenant_id=t and r.receipt_id=l.receipt_id where l.tenant_id=t and l.received_item_id=p_item_id and r.created_at >= (w.start_date::timestamp at time zone 'Asia/Dhaka') and r.created_at < (w.end_date::timestamp at time zone 'Asia/Dhaka')),0) empty_return,
      coalesce(p.bought_bottles,0) bought_bottles,coalesce(p.bought_gas,0) bought_gas
    from weeks w
    cross join lateral (
      select sum(si.quantity) filter(where si.type='refill') sold_refill,
        sum(si.quantity) filter(where si.type='package') sold_package
      from public.sale_items si join public.sales s using(tenant_id,sale_id)
      where si.tenant_id=t and si.item_id=p_item_id and s.status='completed'
        and s.created_at >= (w.start_date::timestamp at time zone 'Asia/Dhaka')
        and s.created_at < (w.end_date::timestamp at time zone 'Asia/Dhaka')
    ) s
    cross join lateral (
      select sum(pi.bottle_quantity) bought_bottles,
        sum(pi.quantity) bought_gas
      from public.purchase_items pi join public.purchases p using(tenant_id,purchase_id)
      where pi.tenant_id=t and pi.item_id=p_item_id and p.status='received'
        and p.received_at >= (w.start_date::timestamp at time zone 'Asia/Dhaka')
        and p.received_at < (w.end_date::timestamp at time zone 'Asia/Dhaka')
    ) p
  )
  select jsonb_build_object(
    'can_manage_prices',app_private.can_manage_inventory_prices(),
    'prices',coalesce((select jsonb_agg(to_jsonb(c) order by customer_tier,price_type) from current_prices c),'[]'::jsonb),
    'buying_prices',coalesce((select jsonb_agg(coalesce(to_jsonb(h),'{}'::jsonb)||ref.value||jsonb_build_object('price_type',kind,'is_manual',coalesce(h.is_manual,false),'new_price',h.new_price) order by kind)
 from unnest(array['gas','bottle'])k(kind)
 cross join lateral(select app_private.buying_price_reference(t,p_item_id,kind,as_of) value)ref
 left join lateral(select * from public.product_buying_price_history where tenant_id=t and item_id=p_item_id and price_type=kind order by effective_at desc,entry_no desc limit 1)h on true
 where exists(select 1 from public.items where tenant_id=t and item_id=p_item_id and business_category='lpg')),'[]'),
    'valuation',(select to_jsonb(c) from public.inventory_costs c where tenant_id=t and item_id=p_item_id),
    'weeks',(select jsonb_agg(to_jsonb(h) order by start_date desc) from history h)
  ) into result;
  return result;
end $function$;

CREATE OR REPLACE FUNCTION public.get_purchase_directory(p_filters jsonb DEFAULT '{}'::jsonb, p_offset integer DEFAULT 0, p_limit integer DEFAULT 6)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_any_permission(array['purchases:view','purchases:manage']); result jsonb;
  ordering text:=coalesce(p_filters->>'sort','date_desc'); searching boolean:=false;
begin
  if p_filters is null or jsonb_typeof(p_filters)<>'object' or length(coalesce(p_filters->>'search',''))>500
    or coalesce(p_filters->>'status','all') not in ('all','created','in_transit','received','cancelled','pending_refund','closed')
    or coalesce(p_filters->>'payment','all') not in ('all','unpaid','partial','paid')
    or coalesce(p_filters->>'business_category','all') not in ('all','lpg','stove')
    or ordering not in ('date_desc','date_asc','amount_desc','amount_asc','due_asc','due_desc','supplier_asc','supplier_desc') then raise exception 'Invalid purchase filters'; end if;
  if p_offset is null or p_limit is null or p_offset<0 or p_offset>1000000 or p_limit not between 1 and 100 then raise exception 'Invalid purchase page'; end if;
  searching:=exists(select 1 from regexp_split_to_table(coalesce(p_filters->>'search',''),'\s*,\s*') g where btrim(g)<>'');
  with matching as materialized (
    select p.purchase_id,p.created_at,p.total_cost,case when p.status='cancelled' then 0 else greatest(0,p.payable_amount-p.paid_amount) end due,lower(coalesce(b.brand_name,p.supplier_name,'')) supplier from public.purchases p
    left join public.vehicles tr on tr.tenant_id=t and tr.vehicle_id=p.vehicle_id
    left join public.gas_plants gp on gp.tenant_id=t and gp.plant_id=p.plant_id
    left join public.lpg_brands b on b.tenant_id=t and b.brand_id=p.brand_id
    where p.tenant_id=t and (coalesce(p_filters->>'business_category','all')='all' or p.business_category=p_filters->>'business_category')
      and (coalesce(p_filters->>'status','all')='all' or p.status::text=p_filters->>'status' or p_filters->>'status'='pending_refund' and p.status='cancelled' and p.financial_closed_at is null or p_filters->>'status'='closed' and p.status='cancelled' and p.financial_closed_at is not null)
      and (coalesce(p_filters->>'payment','all')='all' or p.payment_status=p_filters->>'payment')
      and (nullif(p_filters->>'from','') is null or p.created_at >= (nullif(p_filters->>'from','')::date::timestamp at time zone 'Asia/Dhaka'))
      and (nullif(p_filters->>'to','') is null or p.created_at < ((nullif(p_filters->>'to','')::date+1)::timestamp at time zone 'Asia/Dhaka'))
      and (not searching or exists(
        select 1 from (select lower(concat_ws(' ',p.purchase_id,p.supplier_name,b.brand_name,gp.plant_name,tr.name,p.notes,p.receipt_notes,p.status,p.payment_status,
          (select string_agg(concat_ws(' ',i.product_name,lb.brand_name,trim_scale(i.size_kg)||'kg',trim_scale(i.size_kg)||' kg',i.mouth_size,
            case when pi.bottle_quantity>0 then 'gas bottle' else 'gas' end),' ')
          from public.purchase_items pi join public.items i on i.tenant_id=pi.tenant_id and i.item_id=pi.item_id
          left join public.lpg_brands lb on lb.tenant_id=i.tenant_id and lb.brand_id=i.brand_id where pi.tenant_id=t and pi.purchase_id=p.purchase_id))) text) document
        where exists(select 1 from regexp_split_to_table(lower(p_filters->>'search'),'\s*,\s*') g where btrim(g)<>'' and not exists(
          select 1 from regexp_split_to_table(btrim(g),'\s+') token where token<>'' and position(token in document.text)=0))))
  ), page as materialized (
    select * from matching order by
      case when ordering='date_desc' then created_at end desc,case when ordering='date_asc' then created_at end asc,
      case when ordering='amount_desc' then total_cost end desc,case when ordering='amount_asc' then total_cost end asc,
      case when ordering='due_asc' then due end asc,case when ordering='due_desc' then due end desc,
      case when ordering='supplier_asc' then supplier end asc,case when ordering='supplier_desc' then supplier end desc,purchase_id
    limit p_limit offset p_offset
  ), details as (
    select r.* from app_private.purchase_rows(t,coalesce((select array_agg(purchase_id) from page),'{}'::uuid[])) r
  ) select jsonb_build_object('total',(select count(*) from matching),'entries',coalesce((select jsonb_agg(d.r order by
    case when ordering='date_desc' then p.created_at end desc,case when ordering='date_asc' then p.created_at end asc,
    case when ordering='amount_desc' then p.total_cost end desc,case when ordering='amount_asc' then p.total_cost end asc,
    case when ordering='due_asc' then p.due end asc,case when ordering='due_desc' then p.due end desc,
    case when ordering='supplier_asc' then p.supplier end asc,case when ordering='supplier_desc' then p.supplier end desc,p.purchase_id)
    from details d(r) join page p on p.purchase_id=(d.r->>'purchase_id')::uuid),'[]'::jsonb)) into result;
  return result;
end $function$;

CREATE OR REPLACE FUNCTION public.get_wallet_ledger(p_filters jsonb DEFAULT '{}'::jsonb, p_offset integer DEFAULT 0, p_limit integer DEFAULT 25)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_any_permission(array['finance:view','finance:manage']); result jsonb;
 sorting text:=coalesce(p_filters->>'sort','date_desc');
 search_condition text:=''; group_condition text; search_group text; token text;
begin
 if p_filters is null or jsonb_typeof(p_filters)<>'object' or length(coalesce(p_filters->>'search',''))>500
  or sorting not in ('date_desc','date_asc','amount_desc','amount_asc')
  or coalesce(p_filters->>'direction','all') not in ('all','in','out')
  or p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid ledger filters or page'; end if;
 if nullif(p_filters->>'min','') is not null then perform app_private.purchase_money((p_filters->>'min')::numeric); end if;
 if nullif(p_filters->>'max','') is not null then perform app_private.purchase_money((p_filters->>'max')::numeric); end if;
 if nullif(p_filters->>'min','')::numeric> nullif(p_filters->>'max','')::numeric or nullif(p_filters->>'from','')::date>nullif(p_filters->>'to','')::date then raise exception 'Invalid filter range'; end if;

 -- Compile token groups once, quoting every literal. Direct LIKE predicates let
 -- pg_trgm use its index; user '%'/'_'/'\' remain literal substring characters.
 for search_group in select value from regexp_split_to_table(lower(coalesce(p_filters->>'search','')),'\s*,\s*') value loop
  group_condition:='';
  for token in select value from regexp_split_to_table(trim(search_group),'\s+') value where value<>'' loop
   group_condition:=concat_ws(' and ',nullif(group_condition,''),format('x.search_document like %L',
    '%'||replace(replace(replace(token,chr(92),chr(92)||chr(92)),'%',chr(92)||'%'),'_',chr(92)||'_')||'%'));
  end loop;
  if group_condition<>'' then search_condition:=concat_ws(' or ',nullif(search_condition,''),'('||group_condition||')'); end if;
 end loop;
 search_condition:=coalesce(nullif(search_condition,''),'true');
 execute format($ledger$ with matching as materialized (
  select x.transaction_id,x.created_at,x.entry_no,case when nullif($2->>'business','') is null then x.amount else coalesce((x.business_amounts->>($2->>'business'))::numeric,0) end amount from public.wallet_transactions x where x.tenant_id=$1
   and (nullif($2->>'wallet','') is null or x.wallet_id=nullif($2->>'wallet','')::uuid)
   and (nullif($2->>'type','') is null or x.type_id=nullif($2->>'type','')::uuid) and (nullif($2->>'business','') is null or coalesce((x.business_amounts->>($2->>'business'))::numeric,0)<>0)
   and (coalesce($2->>'direction','all')='all' or ($2->>'direction'='in' and (case when nullif($2->>'business','') is null then x.amount else (x.business_amounts->>($2->>'business'))::numeric end)>0) or ($2->>'direction'='out' and (case when nullif($2->>'business','') is null then x.amount else (x.business_amounts->>($2->>'business'))::numeric end)<0))
   and (nullif($2->>'from','') is null or x.created_at >= (nullif($2->>'from','')::date::timestamp at time zone 'Asia/Dhaka'))
   and (nullif($2->>'to','') is null or x.created_at < ((nullif($2->>'to','')::date+1)::timestamp at time zone 'Asia/Dhaka'))
   and (nullif($2->>'min','') is null or abs(case when nullif($2->>'business','') is null then x.amount else (x.business_amounts->>($2->>'business'))::numeric end)>=nullif($2->>'min','')::numeric)
   and (nullif($2->>'max','') is null or abs(case when nullif($2->>'business','') is null then x.amount else (x.business_amounts->>($2->>'business'))::numeric end)<=nullif($2->>'max','')::numeric)
   and (%s)
 ), page as materialized (
  select * from matching order by
   case when $3='date_desc' then created_at end desc,case when $3='date_asc' then created_at end,
   case when $3='amount_desc' then abs(amount) end desc,case when $3='amount_asc' then abs(amount) end,entry_no desc limit $4 offset $5
 ) select jsonb_build_object('total',(select count(*) from matching),
  'received',(select coalesce(sum(amount) filter(where amount>0),0) from matching),
  'paid_out',(select -coalesce(sum(amount) filter(where amount<0),0) from matching),
  'entries',coalesce((select jsonb_agg((to_jsonb(p)-'search_document')||app_private.financial_source_link(p.tenant_id,'wallet',p.transaction_id)||jsonb_build_object('amount',keys.amount,'total_amount',p.amount,'balance_after',p.balance_after,'type_name',coalesce((select e.type_name from public.financial_entries e where e.tenant_id=p.tenant_id and e.entry_id=p.reference_id),ft.name),'wallet_name',coalesce(p.wallet_name_snapshot,w.name),'counterparty',cw.name,'actor',up.full_name,
   'payment_reference',coalesce(sp.reference,pp.reference),'customer_name',c.name,'customer_phone',c.phone,'source',case when sp.payment_id is not null or p.type='sale_bottle_expense' then 'sale' when p.type like 'purchase%%' then 'purchase' when p.type like 'transit%%' or p.type like 'transport%%' then 'transit' else null end) order by
   case when $3='date_desc' then p.created_at end desc,case when $3='date_asc' then p.created_at end,
   case when $3='amount_desc' then abs(keys.amount) end desc,case when $3='amount_asc' then abs(keys.amount) end,p.entry_no desc)
   from page keys join public.wallet_transactions p on p.tenant_id=$1 and p.transaction_id=keys.transaction_id
   join public.wallets w on w.tenant_id=$1 and w.wallet_id=p.wallet_id
   left join public.financial_types ft on ft.type_id=p.type_id left join public.wallets cw on cw.tenant_id=$1 and cw.wallet_id=p.counterparty_wallet_id
   left join app_private.tenant_actors up on up.tenant_id=$1 and up.user_id=p.created_by
   left join public.sale_payments sp on sp.tenant_id=$1 and sp.payment_id=p.payment_id
   left join public.purchase_payments pp on pp.tenant_id=$1 and pp.payment_id=p.purchase_payment_id
   left join public.sales s on s.tenant_id=$1 and s.sale_id=case when p.type='sale_bottle_expense' then p.reference_id else sp.sale_id end
   left join public.customers c on c.tenant_id=$1 and c.customer_id=s.customer_id),'[]'))
 $ledger$,search_condition) into result using t,p_filters,sorting,p_limit,p_offset;
 return result;
end $function$;

CREATE OR REPLACE FUNCTION public.receive_purchase(p_purchase_id uuid, p_revision integer, p_received_on date DEFAULT NULL::date)
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
 insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details) values(t,p_purchase_id,'received',auth.uid(),jsonb_build_object('direct_receipt',p.transport_cost=0));
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
  insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details)
    values(t,p_purchase_id,'received',auth.uid(),jsonb_build_object('notes','Expected quantities received; transit costs remain open'));
  return jsonb_build_object('purchase_id',p_purchase_id);
end $function$;

CREATE OR REPLACE FUNCTION public.record_operating_payment(p_payload jsonb, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_permission('logistics:manage');prior public.finance_requests;body jsonb:=jsonb_build_object('action','operating_payment','actor',auth.uid(),'body',p_payload);
 tid uuid:=nullif(p_payload->>'transit_id','')::uuid;sid uuid:=nullif(p_payload->>'service_trip_id','')::uuid;
 kind text:=p_payload->>'kind';original public.operating_payments;tr public.transits;s public.vehicle_service_trips;
 r jsonb;x jsonb;w public.wallets;a numeric;total numeric:=0;id uuid;ids jsonb:='[]';d date:=(p_payload->>'payment_date')::date;due numeric;
begin perform app_private.require_permission('logistics:pay');
 if p_request_id is null or jsonb_typeof(p_payload) is distinct from 'object' then raise exception 'Request ID and payment details are required';end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||p_request_id::text,0));select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload<>body then raise exception 'Request ID was already used with different details';end if;return prior.result;end if;
 if num_nonnulls(tid,sid)<>1 or kind is null or kind not in ('expense','expense_return','client_receipt','client_refund') or d is null or not isfinite(d) or d>(now() at time zone 'Asia/Dhaka')::date then raise exception 'Choose a trip, payment kind and valid past/current date';end if;
 if tid is not null then select * into tr from public.transits where tenant_id=t and transit_id=tid for update;
 if not found or tr.closed_at is not null and kind not in ('client_receipt','client_refund') then raise exception 'Transit costs are closed; only outstanding client settlements remain available';end if;
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
end $function$;

CREATE OR REPLACE FUNCTION public.reverse_sale(p_sale_id uuid, p_reason text, p_confirmation text, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_owner('finance:manage');s public.sales;prior public.finance_requests;body jsonb:=jsonb_build_object('action','sale_reversal','actor',auth.uid(),'sale',p_sale_id,'reason',p_reason,'confirmation',p_confirmation);r record;result jsonb;begin perform app_private.require_permission('sales:cancel');
 if p_request_id is null or p_confirmation is distinct from 'CANCEL' or nullif(trim(p_reason),'') is null or length(p_reason)>1000 then raise exception 'Reason, request ID and CANCEL confirmation are required';end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from body then raise exception 'Request ID already used';end if;return prior.result;end if;
 select * into s from public.sales where tenant_id=t and sale_id=p_sale_id for update;
 if not found or s.status<>'completed' then raise exception 'Completed sale not found';end if;
 if not exists(select 1 from public.inventory_cost_entries e join public.inventory_movements m using(tenant_id,movement_id) where e.tenant_id=t and m.reference_id=p_sale_id and m.reference_type='sale' and e.filled_change<0) or exists(select 1 from public.inventory_movements m where m.tenant_id=t and m.reference_id=p_sale_id and m.reference_type='sale' and not exists(select 1 from public.inventory_cost_entries e where e.tenant_id=t and e.movement_id=m.movement_id)) then raise exception 'Sale has no recorded carrying costs; reconcile its stock evidence before cancellation';end if;
 perform 1 from public.items where tenant_id=t and item_id in (select item_id from public.inventory_movements where tenant_id=t and reference_id=p_sale_id and reference_type='sale') order by item_id for update; for r in select item_id,-sum(filled_quantity_change) filled,-sum(empty_quantity_change) empties from public.inventory_movements where tenant_id=t and reference_id=p_sale_id and reference_type='sale' group by item_id order by item_id loop
  perform 1 from public.items where tenant_id=t and item_id=r.item_id for update;
  insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,filled_quantity_change,empty_quantity_change,notes,created_by)
  values(t,r.item_id,'adjust_gain','sale_reversal',p_sale_id,r.filled,r.empties,'Sale cancellation: '||trim(p_reason),auth.uid());
 end loop;
 perform app_private.sync_sale_bottle_reversal(t,p_sale_id,(now() at time zone 'Asia/Dhaka')::date);
 insert into public.customer_transactions(tenant_id,customer_id,type,amount,reference_id,created_by) values(t,s.customer_id,'invoice_charge',s.total_amount+s.additional_charges,p_sale_id,auth.uid());
 insert into public.sale_reversals(tenant_id,sale_id,reason,created_by) values(t,p_sale_id,trim(p_reason),auth.uid());
 update public.sales set status='voided',updated_at=clock_timestamp() where tenant_id=t and sale_id=p_sale_id;
 result:=jsonb_build_object('sale_id',p_sale_id,'refund_due',s.paid_amount);insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,result,auth.uid());return result;end $function$;

CREATE OR REPLACE FUNCTION public.save_product_prices(p_item_id uuid, p_customer_tier text, p_prices jsonb, p_expected jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  t uuid := app_private.require_permission('inventory:manage');
  kind text; entry jsonb; selling numeric; display_mrp numeric; current_version timestamptz;
  saved_at timestamptz; next_start timestamptz;
begin perform app_private.require_permission('inventory:prices');
  if not app_private.can_manage_inventory_prices() then
    raise exception 'Only the owner can edit product prices' using errcode='42501';
  end if;
  if p_customer_tier is null or p_customer_tier not in ('retail','wholesale') then raise exception 'Invalid customer tier'; end if;
  if jsonb_typeof(p_prices) is distinct from 'object' or jsonb_typeof(p_expected) is distinct from 'object' then
    raise exception 'Both refill and package prices are required';
  end if;
  perform 1 from public.items where tenant_id=t and item_id=p_item_id for update;
  if not found then raise exception 'Product not found'; end if;
  saved_at := clock_timestamp();
  foreach kind in array array['refill','package'] loop
    entry := p_prices->kind;
    if jsonb_typeof(entry) is distinct from 'object' or not p_expected ? kind
      or jsonb_typeof(entry->'price') is distinct from 'number'
      or (entry->'mrp' is not null and entry->'mrp'<>'null'::jsonb and jsonb_typeof(entry->'mrp')<>'number') then
      raise exception 'Both refill and package selling prices are required';
    end if;
    selling := (entry->>'price')::numeric;
    display_mrp := (entry->>'mrp')::numeric;
    if selling<0 or selling>=10000000000 or selling<>round(selling,2)
      or display_mrp<0 or display_mrp>=10000000000 or display_mrp<>round(display_mrp,2) then
      raise exception 'Prices must be nonnegative with at most two decimal places';
    end if;
    select effective_from into current_version from public.price_books
      where tenant_id=t and item_id=p_item_id and customer_tier=p_customer_tier and price_type=kind
        and effective_from<=saved_at and (effective_to is null or effective_to>saved_at)
      order by effective_from desc limit 1;
    if current_version is distinct from (p_expected->>kind)::timestamptz then
      raise exception 'Prices changed. Reload saved prices before saving.' using errcode='P0001';
    end if;
    update public.price_books set effective_to=saved_at
      where tenant_id=t and item_id=p_item_id and customer_tier=p_customer_tier and price_type=kind
        and effective_from<saved_at and (effective_to is null or effective_to>saved_at);
    select min(effective_from) into next_start from public.price_books
      where tenant_id=t and item_id=p_item_id and customer_tier=p_customer_tier and price_type=kind
        and effective_from>saved_at;
    insert into public.price_books(tenant_id,item_id,customer_tier,price_type,price,mrp,effective_from,effective_to)
      values(t,p_item_id,p_customer_tier,kind,selling,display_mrp,saved_at,next_start);
  end loop;
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
  if pid is not null then
    insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details)
      values(t,pid,'logistics_updated',auth.uid(),jsonb_build_object('transit_id',p_transit_id,'operating_cost',total,'before',to_jsonb(tr),'after',(select to_jsonb(h) from public.transits h where h.tenant_id=t and h.transit_id=p_transit_id)));
  end if;
  return jsonb_build_object('transit_id',p_transit_id);
end $function$;

CREATE OR REPLACE FUNCTION public.save_vehicle(p_payload jsonb, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_permission('logistics:manage'); v public.vehicles; a public.vehicle_assignments;
 id uuid:=nullif(p_payload->>'vehicle_id','')::uuid; driver uuid:=nullif(p_payload->>'driver_employee_id','')::uuid;
 helper uuid:=nullif(p_payload->>'helper_employee_id','')::uuid; v_capacity numeric:=(p_payload->>'capacity')::numeric;
 prior public.finance_requests; body jsonb:=jsonb_build_object('action','save_vehicle','actor',auth.uid(),'body',p_payload); result jsonb; role_name text; eid uuid;
begin perform app_private.require_permission('logistics:vehicles');
 if p_request_id is null or jsonb_typeof(p_payload) is distinct from 'object' then raise exception 'Vehicle details and request ID are required'; end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload<>body then raise exception 'Request ID was already used with different details'; end if; return prior.result; end if;
 if nullif(trim(p_payload->>'name'),'') is null or length(p_payload->>'name')>100 or nullif(trim(p_payload->>'serial_no'),'') is null or length(p_payload->>'serial_no')>100
  or v_capacity is null or v_capacity::text in ('NaN','Infinity','-Infinity') or v_capacity<0 or v_capacity>2147483647 or v_capacity<>trunc(v_capacity) then raise exception 'Name, serial number and a nonnegative whole capacity are required'; end if;
 if driver is not null and driver=helper then raise exception 'Choose different driver and helper employees'; end if;
 -- Serialize assignment changes per tenant before vehicle -> employee locks.
 perform pg_advisory_xact_lock(hashtextextended(t::text||':vehicle_assignments',0));
 perform 1 from public.employees where tenant_id=t and employee_id in(driver,helper) order by employee_id for update;
 if id is null then
  insert into public.vehicles(tenant_id,name,serial_no,capacity,status) values(t,trim(p_payload->>'name'),trim(p_payload->>'serial_no'),v_capacity,'idle') returning * into v;
  id:=v.vehicle_id;
  perform public.accounting_operation(jsonb_build_object('action','asset_register','kind','vehicles','vehicle_id',id,'name',v.name,'amount',(p_payload->>'book_value')::numeric,'funding',p_payload->>'funding','wallet_id',p_payload->>'wallet_id','date',coalesce((p_payload->>'acquired_on')::date,(now() at time zone 'Asia/Dhaka')::date),'description','Vehicle acquisition: '||v.name),md5(p_request_id::text||':asset')::uuid);
 else
  select * into v from public.vehicles where tenant_id=t and vehicle_id=id for update;
  if not found or v.availability='retired' then raise exception 'Vehicle not found or retired'; end if;
  if v.revision is distinct from (p_payload->>'revision')::integer then raise exception 'Vehicle changed. Reload before saving.'; end if;
 end if;
 perform 1 from public.employees where tenant_id=t and employee_id in (driver,helper) order by employee_id for update;
 foreach role_name in array array['driver','helper'] loop
  eid:=case role_name when 'driver' then driver else helper end;
  select * into a from public.vehicle_assignments where tenant_id=t and vehicle_id=id and role=role_name and ended_at is null;
  if a.employee_id is not distinct from eid then continue; end if;
  perform app_private.validate_vehicle_employee(t,eid,role_name);
  if exists(select 1 from public.vehicle_assignments where tenant_id=t and employee_id=eid and ended_at is null and vehicle_id<>id) then raise exception 'Employee is assigned to another vehicle. Unlink that assignment first.'; end if;
  update public.vehicle_assignments set ended_at=clock_timestamp(),ended_by=auth.uid() where assignment_id=a.assignment_id;
  if eid is not null then insert into public.vehicle_assignments(tenant_id,vehicle_id,employee_id,role,employee_name,created_by)
   select t,id,eid,role_name,name,auth.uid() from public.employees where tenant_id=t and employee_id=eid; end if;
 end loop;
 update public.vehicles set name=trim(p_payload->>'name'),serial_no=trim(p_payload->>'serial_no'),capacity=v_capacity::integer,revision=revision+1,updated_at=clock_timestamp() where tenant_id=t and vehicle_id=id;
 result:=jsonb_build_object('vehicle_id',id);
 insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,result,auth.uid());
 return result;
end $function$;

CREATE OR REPLACE FUNCTION public.set_product_buying_price(p_payload jsonb, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$declare
 t uuid:=app_private.require_owner('inventory:manage');prior public.finance_requests;body jsonb:=jsonb_build_object('action','buying_price','actor',auth.uid(),'body',p_payload);
 id uuid:=(p_payload->>'item_id')::uuid;kind text:=p_payload->>'price_type';manual boolean:=(p_payload->>'is_manual')::boolean;
 prev public.product_buying_price_history;price numeric;r jsonb;hid uuid;reference jsonb;begin perform app_private.require_permission('inventory:prices');
 if p_request_id is null then raise exception 'Request ID is required';end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from body then raise exception 'Request ID already used with different details';end if;return prior.result;end if;
 if kind is null or kind not in ('gas','bottle') or manual is null or nullif(trim(p_payload->>'reason'),'') is null or length(p_payload->>'reason')>1000 then raise exception 'Choose a price type, mode and reason';end if;
 perform 1 from public.items where tenant_id=t and item_id=id and business_category='lpg' for update;if not found then raise exception 'LPG product not found';end if;
 select * into prev from public.product_buying_price_history where tenant_id=t and item_id=id and price_type=kind order by effective_at desc,entry_no desc limit 1;
 if prev.history_id is distinct from nullif(p_payload->>'expected','')::uuid then raise exception 'Buying price changed. Reload before saving.';end if;
 reference:=app_private.buying_price_reference(t,id,kind,clock_timestamp());
 if not manual and reference->>'automatic_price' is null then raise exception 'Receive a purchase before restoring automatic pricing';end if;
 if manual and p_payload->>'price' is null then raise exception 'Enter an approximate buying price';end if;
 price:=case when manual then app_private.purchase_money((p_payload->>'price')::numeric) else (reference->>'automatic_price')::numeric end;
 insert into public.product_buying_price_history(tenant_id,item_id,price_type,previous_price,new_price,automatic_price,is_manual,invoice_unit_price,overhead_per_unit,purchase_id,source,reason,created_by)
 values(t,id,kind,prev.new_price,price,(reference->>'automatic_price')::numeric,manual,(reference->>'invoice_unit_price')::numeric,(reference->>'overhead_per_unit')::numeric,(reference->>'purchase_id')::uuid,
 case when manual then 'manual' else 'restore_automatic' end,trim(p_payload->>'reason'),auth.uid()) returning history_id into hid;
 r:=jsonb_build_object('history_id',hid);insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,r,auth.uid());return r;end $function$;

CREATE OR REPLACE FUNCTION public.transition_transit(p_transit_id uuid, p_action text, p_revision integer, p_costs jsonb DEFAULT NULL::jsonb)
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
 if pid is not null then insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details) values(t,pid,'transit_closed',auth.uid(),jsonb_build_object('transit_id',p_transit_id,'operating_cost',tr.total_cost));end if;
 return jsonb_build_object('transit_id',p_transit_id);
end $function$;

CREATE OR REPLACE FUNCTION public.update_purchase(p_purchase_id uuid, p_payload jsonb, p_revision integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid := app_private.require_permission('purchases:manage'); p public.purchases; truck uuid; before_items jsonb;
begin perform app_private.require_permission('purchases:edit');
  if p_payload - array['vehicle_id','transport_cost','labour_cost','notes','items'] <> '{}'::jsonb then raise exception 'Unsupported purchase fields';end if;
  select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id for update;
  if not found then raise exception 'Purchase not found'; end if;
  if p_revision is distinct from p.revision then raise exception 'Purchase changed. Reload it before saving.' using errcode='P0001'; end if;
  if p.status='received' and p_payload ?| array['items','transport_cost','labour_cost'] then raise exception 'Received purchase costs and quantities are immutable';end if;
  if p.status='cancelled' or (p.status='received' and p.payment_status='paid') then raise exception 'Purchase is completed and locked'; end if;
  if p_payload ? 'plant_id' and (p_payload->>'plant_id')::uuid is distinct from p.plant_id
    or p_payload ? 'brand_id' and (p_payload->>'brand_id')::uuid is distinct from p.brand_id then
    raise exception 'Plant and company cannot change'; end if;
  if p.status<>'created' and p_payload ? 'transport_cost' and (p_payload->>'transport_cost')::numeric is distinct from p.transport_cost then raise exception 'Transport fee is fixed at dispatch';end if;
  select jsonb_agg(to_jsonb(pi)) into before_items from public.purchase_items pi where tenant_id=t and purchase_id=p_purchase_id;
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
 update public.purchases set payment_status=case when status='created' then payment_status when paid_amount>=payable_amount then 'paid' when paid_amount>0 then 'partial' else 'unpaid' end,
    paid_at=case when status<>'created' and paid_amount>=payable_amount then coalesce(paid_at,now()) else paid_at end,notes=case when p_payload ? 'notes' then p_payload->>'notes' else notes end,
    updated_at=now(),revision=revision+1 where tenant_id=t and purchase_id=p_purchase_id;
  insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details)
    values(t,p_purchase_id,'updated',auth.uid(),jsonb_build_object('before',to_jsonb(p),'before_items',before_items,
      'after',(select to_jsonb(h) from public.purchases h where h.tenant_id=t and h.purchase_id=p_purchase_id),
      'items',(select jsonb_agg(to_jsonb(pi)) from public.purchase_items pi where pi.tenant_id=t and pi.purchase_id=p_purchase_id)));
  return jsonb_build_object('purchase_id',p_purchase_id);
end $function$;

-- New routines follow the existing owner/permission boundary. Private helpers
-- remain unexposed; public operations retain trusted tenancy and action checks.
alter function app_private.purchase_components(uuid,uuid) owner to postgres;
alter function app_private.sync_sale_bottle_reversal(uuid,uuid,date) owner to postgres;
revoke all on function app_private.sync_sale_bottle_reversal(uuid,uuid,date) from public,anon,authenticated;
alter function app_private.fifo_component_layer(uuid,uuid,uuid,text,timestamptz,integer,numeric,numeric,numeric,numeric,integer,uuid,timestamptz) owner to postgres;
alter function app_private.snapshot_inventory_components() owner to postgres;
alter function public.receive_purchase(uuid,integer,date) owner to postgres;
revoke all on function app_private.purchase_components(uuid,uuid),app_private.fifo_component_layer(uuid,uuid,uuid,text,timestamptz,integer,numeric,numeric,numeric,numeric,integer,uuid,timestamptz),app_private.snapshot_inventory_components() from public,anon,authenticated;
revoke all on function public.receive_purchase(uuid,integer,date) from public,anon;
grant execute on function public.receive_purchase(uuid,integer,date) to authenticated,service_role;
alter function app_private.refresh_buying_price(uuid,uuid,text,timestamptz,uuid) owner to postgres;
revoke all on function app_private.refresh_buying_price(uuid,uuid,text,timestamptz,uuid) from public,anon,authenticated;
