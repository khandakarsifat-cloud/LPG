-- Canonical component contract. This cutover requires the authorized empty development baseline.
do $$begin
 if exists(select 1 from public.tenants) then
  raise exception 'Component cutover requires the verified empty development baseline';
 end if;
end$$;

drop view app_private.fifo_layers;
drop view app_private.fifo_position_effects;
drop table app_private.fifo_purchase_holdings;
drop table app_private.fifo_consumptions;
drop table app_private.fifo_positions;
drop table app_private.fifo_component_layers;
drop function app_private.fifo_component_layer(uuid,uuid,uuid,text,timestamptz,integer,numeric,numeric,numeric,numeric,integer,uuid,timestamptz);
drop function app_private.sync_internal_fifo(public.inventory_movements);
drop function app_private.fifo_components_consistent(uuid,uuid);
drop function public.get_lpg_fifo_stock(uuid,text,integer);
drop function public.get_fifo_stock(uuid,text,text,integer);

alter table public.items drop column empty_quantity;
alter table public.items rename column filled_quantity to gas_quantity;
alter table public.items add column unit_quantity integer not null default 0;
alter table public.items drop constraint item_business_shape;
alter table public.items add constraint item_business_shape check(
 (business_category='lpg' and brand_id is not null and size_kg>0 and product_name is null
  and product_type_id is null and unit_quantity=0 and gas_quantity between 0 and bottle_quantity)
 or (business_category='stove' and brand_id is null and size_kg is null and mouth_size is null
  and length(trim(product_name)) between 1 and 150 and product_type_id is not null
  and gas_quantity=0 and bottle_quantity=0 and unit_quantity>=0));

alter table public.inventory_movements drop column empty_quantity_change;
alter table public.inventory_movements rename column filled_quantity_change to gas_change;
alter table public.inventory_movements rename column bottle_quantity_change to bottle_change;
alter table public.inventory_movements alter column bottle_change set default 0;
alter table public.inventory_movements alter column bottle_change set not null;
alter table public.inventory_movements add column unit_change integer not null default 0;
alter table public.inventory_movements add column bottle_transit_change integer not null default 0;
comment on column public.inventory_movements.gas_change is 'Gas quantity added to or issued from on-hand LPG stock.';
comment on column public.inventory_movements.bottle_change is 'Bottle quantity added to or issued from on-hand LPG stock.';
comment on column public.inventory_movements.bottle_transit_change is 'Owned Bottle quantity moved to or from purchase transit. Never a FIFO issue or acquisition.';
comment on column public.items.gas_quantity is 'On-hand LPG Gas quantity.';
comment on column public.items.bottle_quantity is 'On-hand owned LPG Bottle quantity, independently of Gas. Transit is recorded by inventory custody.';
comment on column public.items.unit_quantity is 'On-hand Stove Unit quantity; zero for LPG products.';

alter table public.purchase_items rename column empty_dispatched to bottles_dispatched;
alter table public.purchase_items drop constraint purchase_custody_quantity_valid;
alter table public.purchase_items add constraint purchase_custody_quantity_valid check(bottles_dispatched<=quantity-bottle_quantity);

alter table public.inventory_costs drop constraint inventory_costs_check;
alter table public.inventory_costs rename column filled_quantity to gas_quantity;
alter table public.inventory_costs rename column empty_quantity to bottle_quantity;
alter table public.inventory_costs rename column filled_value to gas_value;
alter table public.inventory_costs rename column empty_value to bottle_value;
alter table public.inventory_costs add column unit_quantity integer not null default 0;
alter table public.inventory_costs add column unit_value numeric(20,2) not null default 0;
alter table public.inventory_costs add constraint component_inventory_costs_valid check(
 gas_quantity>=0 and bottle_quantity>=0 and unit_quantity>=0 and gas_value>=0 and bottle_value>=0 and unit_value>=0);
-- Cost pools include owned Bottle stock in transit. Location remains inventory evidence.
alter table public.inventory_cost_entries rename column filled_change to gas_change;
alter table public.inventory_cost_entries rename column empty_change to bottle_change;
alter table public.inventory_cost_entries rename column filled_value to gas_value;
alter table public.inventory_cost_entries rename column empty_value to bottle_value;
alter table public.inventory_cost_entries rename column filled_after to gas_after;
alter table public.inventory_cost_entries rename column empty_after to bottle_after;
alter table public.inventory_cost_entries add column unit_change integer not null default 0;
alter table public.inventory_cost_entries add column unit_value numeric(20,2) not null default 0;
alter table public.inventory_cost_entries add column unit_after numeric(20,2) not null default 0;
-- Corrections retain their movement link. One original posting per movement.
alter table public.inventory_cost_entries drop constraint inventory_cost_entries_tenant_id_movement_id_key;
alter table public.inventory_cost_entries add column is_correction boolean not null default false;
create unique index component_cost_original_once on public.inventory_cost_entries(tenant_id,movement_id) where not is_correction;
alter table app_private.fifo_movement_costs rename column filled_value to gas_value;
alter table app_private.fifo_movement_costs rename column empty_value to bottle_value;
alter table app_private.fifo_movement_costs add column unit_value numeric(20,2) not null default 0;

create table app_private.fifo_layers (
 tenant_id uuid not null,
 layer_id uuid not null default gen_random_uuid(),
 item_id uuid not null,
 movement_id uuid not null,
 component text not null check(component in('gas','bottle','unit')),
 acquired_at timestamptz not null,
 acquired_order bigint not null,
 quantity integer not null check(quantity>0),
 remaining integer not null check(remaining>=0 and remaining<=quantity),
 value numeric(20,2) not null check(value>=0),
 remaining_value numeric(20,2) not null check(remaining_value>=0 and remaining_value<=value),
 internal_value numeric(20,2) not null default 0 check(internal_value>=0),
 remaining_internal_value numeric(20,2) not null default 0 check(remaining_internal_value>=0 and remaining_internal_value<=internal_value),
 primary key(tenant_id,layer_id),
 unique(tenant_id,movement_id,component),
 foreign key(tenant_id,item_id) references public.items(tenant_id,item_id),
 foreign key(tenant_id,movement_id) references public.inventory_movements(tenant_id,movement_id),
 check(remaining>0 or remaining_value+remaining_internal_value=0)
);
create index fifo_component_available on app_private.fifo_layers(tenant_id,item_id,component,acquired_at,acquired_order,layer_id) where remaining>0;
create table app_private.fifo_consumptions (
 tenant_id uuid not null,
 movement_id uuid not null,
 layer_id uuid not null,
 quantity integer not null,
 value numeric(20,2) not null,
 internal_value numeric(20,2) not null default 0,
 primary key(tenant_id,movement_id,layer_id),
 foreign key(tenant_id,movement_id) references public.inventory_movements(tenant_id,movement_id),
 foreign key(tenant_id,layer_id) references app_private.fifo_layers(tenant_id,layer_id)
);
create index fifo_layer_consumptions on app_private.fifo_consumptions(tenant_id,layer_id);
-- A purchase owns these location reservations. Layer balances are untouched by location changes.
create table app_private.purchase_bottle_custody (
 tenant_id uuid not null,
 dispatch_movement_id uuid not null,
 layer_id uuid not null,
 quantity integer not null check(quantity>0),
 settled_movement_id uuid,
 primary key(tenant_id,dispatch_movement_id,layer_id),
 foreign key(tenant_id,dispatch_movement_id) references public.inventory_movements(tenant_id,movement_id),
 foreign key(tenant_id,settled_movement_id) references public.inventory_movements(tenant_id,movement_id),
 foreign key(tenant_id,layer_id) references app_private.fifo_layers(tenant_id,layer_id)
);
create index bottle_custody_active on app_private.purchase_bottle_custody(tenant_id,layer_id) where settled_movement_id is null;
do $$declare name text;begin
 foreach name in array array['fifo_layers','fifo_consumptions','purchase_bottle_custody'] loop
  execute format('alter table app_private.%I owner to postgres',name);
  execute format('alter table app_private.%I enable row level security',name);
  execute format('revoke all on app_private.%I from public,anon,authenticated,service_role',name);
  execute format('create trigger a_business_deletion_guard before insert or update or delete on app_private.%I for each row execute function app_private.guard_business_deletion()',name);
 end loop;
end$$;

drop index public.dashboard_bottle_expectations;
alter type public.sale_item_type rename to retired_sale_item_type;
create type public.sale_item_type as enum('refill','package');
alter table public.sale_items alter column type type public.sale_item_type using type::text::public.sale_item_type;
drop type public.retired_sale_item_type;
create index dashboard_bottle_expectations on public.sale_items(tenant_id,sale_id) include(quantity) where type='refill';
alter table public.purchase_items rename constraint purchase_items_empty_dispatched_check to purchase_items_dispatched_bottles_valid;

-- The system type remains an identity for historical migration replay only.
alter table public.financial_types disable trigger user;
update public.financial_types set name='Bottle transit' where tenant_id is null and code='purchase_dispatch';
alter table public.financial_types enable trigger user;


create function app_private.add_component_layer(m public.inventory_movements, part text, qty integer, cost numeric, transport numeric default 0)
returns void language plpgsql set search_path='' as $$
begin
 if qty<=0 or cost<0 or transport<0 then raise exception 'Invalid component acquisition';end if;
 insert into app_private.fifo_layers(tenant_id,item_id,movement_id,component,acquired_at,acquired_order,
   quantity,remaining,value,remaining_value,internal_value,remaining_internal_value)
 values(m.tenant_id,m.item_id,m.movement_id,part,m.created_at,m.movement_no,qty,qty,cost,cost,transport,transport);
end$$;

create or replace function app_private.fifo_take(t uuid,id uuid,mid uuid,part text,qty integer)
returns numeric language plpgsql set search_path='' as $$
declare batch record; needed integer:=qty; take integer; cost numeric; transport numeric; total numeric:=0;
begin
 if part not in('gas','bottle','unit') or qty<=0 then raise exception 'Invalid component issue';end if;
 for batch in select l.*,l.remaining-coalesce((select sum(h.quantity) from app_private.purchase_bottle_custody h
   where h.tenant_id=l.tenant_id and h.layer_id=l.layer_id and h.settled_movement_id is null),0) available
   from app_private.fifo_layers l where tenant_id=t and item_id=id and component=part and remaining>0
   order by acquired_at,acquired_order,layer_id for update loop
  exit when needed=0;
  take:=least(needed,batch.available);
  if take<=0 then continue;end if;
  cost:=case when take=batch.remaining then batch.remaining_value else round(batch.remaining_value*take/batch.remaining,2) end;
  transport:=case when take=batch.remaining then batch.remaining_internal_value else round(batch.remaining_internal_value*take/batch.remaining,2) end;
  update app_private.fifo_layers set remaining=remaining-take,remaining_value=remaining_value-cost,
    remaining_internal_value=remaining_internal_value-transport where tenant_id=t and layer_id=batch.layer_id;
  insert into app_private.fifo_consumptions values(t,mid,batch.layer_id,take,cost,transport);
  total:=total+cost;needed:=needed-take;
 end loop;
 if needed<>0 then raise exception 'Insufficient % FIFO for product',part;end if;
 return total;
end$$;

create function app_private.update_bottle_custody(m public.inventory_movements)
returns void language plpgsql set search_path='' as $$
declare batch record; needed integer:=m.bottle_transit_change; taken integer; recorded integer;
begin
 if needed>0 then
  for batch in select l.*,l.remaining-coalesce((select sum(h.quantity) from app_private.purchase_bottle_custody h
    where h.tenant_id=l.tenant_id and h.layer_id=l.layer_id and h.settled_movement_id is null),0) available
    from app_private.fifo_layers l where l.tenant_id=m.tenant_id and l.item_id=m.item_id
      and l.component='bottle' and l.remaining>0 order by acquired_at,acquired_order,layer_id for update loop
   exit when needed=0;
   taken:=least(needed,batch.available);
   if taken<=0 then continue;end if;
   insert into app_private.purchase_bottle_custody(tenant_id,dispatch_movement_id,layer_id,quantity)
   values(m.tenant_id,m.movement_id,batch.layer_id,taken);
   needed:=needed-taken;
  end loop;
  if needed<>0 then raise exception 'Insufficient available Bottle stock for dispatch';end if;
 elsif needed<0 then
  select coalesce(sum(h.quantity),0) into recorded from app_private.purchase_bottle_custody h
  join public.inventory_movements d on d.tenant_id=h.tenant_id and d.movement_id=h.dispatch_movement_id
  where h.tenant_id=m.tenant_id and d.item_id=m.item_id and d.reference_id=m.reference_id and h.settled_movement_id is null;
  if recorded<>-needed then raise exception 'Purchase Bottle transit does not reconcile';end if;
  update app_private.purchase_bottle_custody h set settled_movement_id=m.movement_id
  from public.inventory_movements d where h.tenant_id=m.tenant_id and d.tenant_id=h.tenant_id
    and d.movement_id=h.dispatch_movement_id and d.item_id=m.item_id and d.reference_id=m.reference_id
    and h.settled_movement_id is null;
 end if;
end$$;

create or replace function app_private.snapshot_inventory_components()
returns trigger language plpgsql set search_path='' as $$
declare category text;price numeric;
begin
 select business_category into strict category from public.items where tenant_id=new.tenant_id and item_id=new.item_id;
 if category='lpg' and new.unit_change<>0 or category='stove' and abs(new.gas_change)+abs(new.bottle_change)+abs(new.bottle_transit_change)<>0 then
  raise exception 'Stock components do not match the product business';
 end if;
 if new.bottle_transit_change<>0 and (category<>'lpg' or new.reference_type not in('purchase_dispatch','purchase_receipt','purchase_cancellation')) then
  raise exception 'Bottle transit requires a purchase operation';
 end if;
 if new.reference_type='sale' and new.bottle_change>0 then
  select new_price into price from public.product_buying_price_history
  where tenant_id=new.tenant_id and item_id=new.item_id and price_type='bottle' and effective_at<=new.created_at
  order by effective_at desc,entry_no desc limit 1;
  if price is null then raise exception 'Set the received product Bottle buying price before accepting bottles';end if;
  new.valuation:=coalesce(new.valuation,'{}')||jsonb_build_object('bottle_unit_cost',price);
 end if;
 return new;
end$$;

create or replace function app_private.update_item_inventory()
returns trigger language plpgsql set search_path='' as $$
begin
 update public.items set gas_quantity=gas_quantity+new.gas_change,bottle_quantity=bottle_quantity+new.bottle_change,
   unit_quantity=unit_quantity+new.unit_change,updated_at=clock_timestamp()
 where tenant_id=new.tenant_id and item_id=new.item_id;
 return new;
end$$;

create or replace function app_private.fifo_cost_movement(m public.inventory_movements)
returns void language plpgsql set search_path='' as $$
declare
 pool public.inventory_costs; prior app_private.fifo_movement_costs;category text;account text;counter text:='cogs';
 gas numeric:=0;bottle numeric:=0;units numeric:=0;transport numeric:=0;part record;batch record;
 acquired_qty integer;external_cost numeric;internal_cost numeric;returned integer;expected integer;previous integer;
 basis numeric:=0;external_basis numeric:=0;full_basis numeric:=0;claim_internal numeric:=0;
 target jsonb;occurred date:=(m.created_at at time zone 'Asia/Dhaka')::date;
begin
 select * into pool from public.inventory_costs where tenant_id=m.tenant_id and item_id=m.item_id for update;
 select business_category into strict category from public.items where tenant_id=m.tenant_id and item_id=m.item_id;
 account:=case when category='lpg' then 'inventory_lpg' else 'inventory_stove' end;
 perform app_private.update_bottle_custody(m);
 if m.reference_type in('purchase_dispatch','purchase_cancellation') then return;end if;
 select * into prior from app_private.fifo_movement_costs where tenant_id=m.tenant_id and movement_id=m.movement_id;

 if m.reference_type in('sale_reversal','stove_purchase_cancellation') then
  -- Reverse exactly the received layers, before restoring outgoing component issues.
  for batch in select l.* from app_private.fifo_layers l join public.inventory_movements original using(tenant_id,movement_id)
    where l.tenant_id=m.tenant_id and l.item_id=m.item_id and original.reference_id=m.reference_id
    and ((m.reference_type='sale_reversal' and original.reference_type='sale' and original.bottle_change>0)
      or (m.reference_type='stove_purchase_cancellation' and original.reference_type='stove_purchase_receipt'))
    order by l.acquired_at,l.acquired_order,l.layer_id for update of l loop
   if batch.remaining<>batch.quantity or batch.remaining_value<>batch.value or batch.remaining_internal_value<>batch.internal_value
     or exists(select 1 from app_private.purchase_bottle_custody h where h.tenant_id=m.tenant_id and h.layer_id=batch.layer_id and h.settled_movement_id is null) then
    raise exception 'The original received component has been consumed or reserved; cancellation cannot substitute other stock';
   end if;
   insert into app_private.fifo_consumptions values(m.tenant_id,m.movement_id,batch.layer_id,batch.quantity,batch.value,batch.internal_value);
   update app_private.fifo_layers set remaining=0,remaining_value=0,remaining_internal_value=0
   where tenant_id=m.tenant_id and layer_id=batch.layer_id;
  end loop;
  if m.reference_type='sale_reversal' then
   for batch in select x.layer_id,sum(x.quantity)::integer quantity,sum(x.value) value,sum(x.internal_value) internal_value
     from app_private.fifo_consumptions x join public.inventory_movements original using(tenant_id,movement_id)
     join app_private.fifo_layers l using(tenant_id,layer_id)
     where x.tenant_id=m.tenant_id and l.item_id=m.item_id and original.reference_id=m.reference_id
       and original.reference_type='sale' and (original.gas_change<0 or original.unit_change<0)
     group by x.layer_id,l.acquired_at order by l.acquired_at,x.layer_id loop
    update app_private.fifo_layers set remaining=remaining+batch.quantity,remaining_value=remaining_value+batch.value,
      remaining_internal_value=remaining_internal_value+batch.internal_value where tenant_id=m.tenant_id and layer_id=batch.layer_id;
    insert into app_private.fifo_consumptions values(m.tenant_id,m.movement_id,batch.layer_id,-batch.quantity,-batch.value,-batch.internal_value);
   end loop;
  else counter:='inventory_transit';end if;
 else
  for part in select * from (values('gas',m.gas_change),('bottle',m.bottle_change+m.bottle_transit_change),('unit',m.unit_change)) p(component,delta) loop
   if part.delta<0 then perform app_private.fifo_take(m.tenant_id,m.item_id,m.movement_id,part.component,-part.delta);end if;
  end loop;
  if m.reference_type in('purchase_receipt','stove_purchase_receipt') then
   counter:='inventory_transit';
   for part in select * from app_private.purchase_components(m.tenant_id,m.reference_id) where item_id=m.item_id loop
    acquired_qty:=case when category='stove' then m.unit_change when part.component='gas' then m.gas_change
      else m.bottle_change+m.bottle_transit_change end;
    if acquired_qty>0 then
     perform app_private.add_component_layer(m,case when category='stove' then 'unit' else part.component end,
       acquired_qty,part.invoice_value+part.labour_value,part.transport_value);
    end if;
   end loop;
  elsif m.valuation->>'counter_account' is not null then
   counter:=m.valuation->>'counter_account';
   if counter not in('capital','other_income','opening_equity','inventory_loss') then raise exception 'Invalid stock classification';end if;
   for part in select * from (values('gas',m.gas_change),('bottle',m.bottle_change),('unit',m.unit_change)) p(component,delta) loop
    if part.delta>0 then
     if m.valuation->>(part.component||'_unit_cost') is null then raise exception 'Component acquisition cost is required';end if;
     perform app_private.add_component_layer(m,part.component,part.delta,
       round(part.delta*app_private.purchase_money((m.valuation->>(part.component||'_unit_cost'))::numeric),2));
    end if;
   end loop;
  elsif m.reference_type='sale' then
   if m.bottle_change>0 then
    perform app_private.add_component_layer(m,'bottle',m.bottle_change,
      round(m.bottle_change*app_private.purchase_money((m.valuation->>'bottle_unit_cost')::numeric),2));
   end if;
  else raise exception 'Stock movement requires component acquisition evidence';end if;
 end if;

 select coalesce(sum(value) filter(where component='gas'),0),coalesce(sum(value) filter(where component='bottle'),0),
   coalesce(sum(value) filter(where component='unit'),0),coalesce(sum(internal_value),0)
 into gas,bottle,units,transport from (
   select l.component,l.value,l.internal_value from app_private.fifo_layers l where l.tenant_id=m.tenant_id and l.movement_id=m.movement_id
   union all
   select l.component,-x.value,-x.internal_value from app_private.fifo_consumptions x join app_private.fifo_layers l using(tenant_id,layer_id)
   where x.tenant_id=m.tenant_id and x.movement_id=m.movement_id
 ) effects;
 update public.inventory_costs set gas_quantity=gas_quantity+m.gas_change,
   bottle_quantity=bottle_quantity+m.bottle_change+m.bottle_transit_change,unit_quantity=unit_quantity+m.unit_change,
   gas_value=gas_value+gas,bottle_value=bottle_value+bottle,unit_value=unit_value+units
 where tenant_id=m.tenant_id and item_id=m.item_id;
 if prior.movement_id is null then
  insert into public.inventory_cost_entries(tenant_id,item_id,movement_id,occurred_on,gas_change,bottle_change,unit_change,
   gas_value,bottle_value,unit_value,gas_after,bottle_after,unit_after,reason,estimated,created_by)
  values(m.tenant_id,m.item_id,m.movement_id,occurred,m.gas_change,m.bottle_change+m.bottle_transit_change,m.unit_change,
   gas,bottle,units,pool.gas_value+gas,pool.bottle_value+bottle,pool.unit_value+units,coalesce(m.notes,'Component stock movement'),pool.estimated,m.created_by);
 elsif row(prior.gas_value,prior.bottle_value,prior.unit_value) is distinct from row(gas,bottle,units) then
  insert into public.inventory_cost_entries(tenant_id,item_id,movement_id,occurred_on,gas_change,bottle_change,unit_change,
   gas_value,bottle_value,unit_value,gas_after,bottle_after,unit_after,reason,estimated,created_by,is_correction)
  values(m.tenant_id,m.item_id,m.movement_id,occurred,0,0,0,gas-prior.gas_value,bottle-prior.bottle_value,units-prior.unit_value,
   pool.gas_value+gas,pool.bottle_value+bottle,pool.unit_value+units,'Component FIFO correction',pool.estimated,auth.uid(),true);
 end if;
 insert into app_private.fifo_movement_costs(tenant_id,movement_id,item_id,occurred_at,gas_value,bottle_value,unit_value)
 values(m.tenant_id,m.movement_id,m.item_id,m.created_at,gas,bottle,units)
 on conflict(tenant_id,movement_id) do update set gas_value=excluded.gas_value,bottle_value=excluded.bottle_value,unit_value=excluded.unit_value;

 target:=jsonb_build_array(app_private.accounting_line(account,gas+bottle+units,category,m.item_id),
   app_private.accounting_line(counter,-gas-bottle-units,category,m.reference_id));
 if m.reference_type='sale' and m.bottle_change>0 then
  select coalesce(sum(quantity),0) into expected from public.sale_items where tenant_id=m.tenant_id and sale_id=m.reference_id and type='refill';
  select coalesce(sum(bottle_change),0) into previous from public.inventory_movements where tenant_id=m.tenant_id and reference_id=m.reference_id
    and reference_type='sale' and bottle_change>0 and (created_at,movement_no)<(m.created_at,m.movement_no);
  select coalesce(sum(x.value+x.internal_value),0),coalesce(sum(x.value),0) into full_basis,external_basis
  from app_private.fifo_consumptions x join app_private.fifo_layers l using(tenant_id,layer_id)
  join public.inventory_movements issue on issue.tenant_id=x.tenant_id and issue.movement_id=x.movement_id
  where x.tenant_id=m.tenant_id and issue.reference_id=m.reference_id and issue.reference_type='sale'
    and issue.valuation->>'sale_type'='refill' and l.component='bottle';
  basis:=case when expected>0 then round(full_basis*least(expected,previous+m.bottle_change)/expected,2)-round(full_basis*least(expected,previous)/expected,2) else 0 end;
  external_basis:=case when expected>0 then round(external_basis*least(expected,previous+m.bottle_change)/expected,2)-round(external_basis*least(expected,previous)/expected,2) else 0 end;
  target:=jsonb_build_array(app_private.accounting_line(account,bottle,category,m.item_id),
    app_private.accounting_line('bottle_receivable',-basis,category,m.reference_id)||jsonb_build_object('consolidated_amount',-external_basis),
    app_private.accounting_line('bottle_exchange',basis-bottle,category,m.reference_id)||jsonb_build_object('consolidated_amount',external_basis-bottle));
 end if;
 perform app_private.sync_journal(m.tenant_id,'inventory',m.movement_id,occurred,coalesce(m.notes,'Component stock movement'),target,counter='opening_equity');
 if transport<>0 or exists(select 1 from app_private.accounting_source_state where tenant_id=m.tenant_id and source='internal_inventory' and source_id=m.movement_id) then
  perform app_private.sync_journal(m.tenant_id,'internal_inventory',m.movement_id,occurred,'Component transport carrying cost',
   jsonb_build_array(app_private.accounting_line(account,transport,category,m.item_id)||jsonb_build_object('consolidated_amount',0),
     app_private.accounting_line(counter,-transport,category,case when counter='inventory_transit' then m.reference_id end)||jsonb_build_object('consolidated_amount',0)));
 end if;
 if m.reference_type='sale' and m.valuation->>'sale_type'='refill' and m.gas_change<0 then
  select coalesce(sum(x.value),0),coalesce(sum(x.internal_value),0) into basis,claim_internal
  from app_private.fifo_consumptions x join app_private.fifo_layers l using(tenant_id,layer_id)
  where x.tenant_id=m.tenant_id and x.movement_id=m.movement_id and l.component='bottle';
  perform app_private.sync_journal(m.tenant_id,'bottle_obligation',m.movement_id,occurred,'Bottle replacement claim',
    jsonb_build_array(app_private.accounting_line('bottle_receivable',basis+claim_internal,category,m.reference_id)||jsonb_build_object('consolidated_amount',basis),
      app_private.accounting_line('cogs',-basis-claim_internal,category)||jsonb_build_object('consolidated_amount',-basis)));
 end if;
end$$;

create or replace function app_private.rebuild_fifo_set(t uuid,ids uuid[])
returns void language plpgsql set search_path='' as $$
declare movement public.inventory_movements;reversal record;
begin
 perform 1 from public.items where tenant_id=t and item_id=any(ids) order by item_id for update;
 delete from app_private.purchase_bottle_custody where tenant_id=t and layer_id in(select layer_id from app_private.fifo_layers where tenant_id=t and item_id=any(ids));
 delete from app_private.fifo_consumptions where tenant_id=t and layer_id in(select layer_id from app_private.fifo_layers where tenant_id=t and item_id=any(ids));
 delete from app_private.fifo_layers where tenant_id=t and item_id=any(ids);
 update public.inventory_costs set gas_quantity=0,bottle_quantity=0,unit_quantity=0,gas_value=0,bottle_value=0,unit_value=0 where tenant_id=t and item_id=any(ids);
 for movement in select im.* from public.inventory_movements im where im.tenant_id=t and im.item_id=any(ids)
   order by im.created_at,case when im.reference_type='sale' then (select min(x.movement_no) from public.inventory_movements x
     where x.tenant_id=t and x.reference_type='sale' and x.reference_id=im.reference_id) else im.movement_no end,
     case when im.gas_change<0 or im.unit_change<0 then 0 else 1 end,im.movement_no loop
  perform app_private.fifo_cost_movement(movement);
 end loop;
 for reversal in select s.sale_id,(s.created_at at time zone 'Asia/Dhaka')::date d from public.sale_reversals s
  where s.tenant_id=t and exists(select 1 from public.inventory_movements im where im.tenant_id=t and im.reference_id=s.sale_id
    and im.reference_type='sale' and im.item_id=any(ids)) loop
  perform app_private.sync_sale_bottle_reversal(t,reversal.sale_id,reversal.d);
 end loop;
end$$;

create or replace function app_private.cost_inventory_movement()
returns trigger language plpgsql set search_path='' as $$
begin
 if exists(select 1 from public.inventory_movements im where im.tenant_id=new.tenant_id and im.item_id=new.item_id
   and (im.created_at,im.movement_no)>(new.created_at,new.movement_no)) then
  perform app_private.rebuild_fifo_set(new.tenant_id,(select array_agg(item_id order by item_id) from public.items where tenant_id=new.tenant_id));
 else perform app_private.fifo_cost_movement(new);end if;
 return new;
end$$;


create function app_private.component_inventory_evidence(t uuid,id uuid)
returns jsonb language sql stable set search_path='' as $$
 with balances as (
  select coalesce(sum(remaining) filter(where component='gas'),0) gas,
    coalesce(sum(remaining) filter(where component='bottle'),0) bottle,
    coalesce(sum(remaining) filter(where component='unit'),0) units,
    coalesce(sum(remaining_value),0) external_value,coalesce(sum(remaining_internal_value),0) transport
  from app_private.fifo_layers where tenant_id=t and item_id=id
 ), custody as (
  select coalesce(sum(h.quantity),0) quantity from app_private.purchase_bottle_custody h
  join app_private.fifo_layers l using(tenant_id,layer_id)
  where h.tenant_id=t and l.item_id=id and h.settled_movement_id is null
 ), stock as (
  select i.*,c.gas_value,c.bottle_value,c.unit_value,c.gas_quantity pool_gas,c.bottle_quantity pool_bottle,c.unit_quantity pool_unit
  from public.items i join public.inventory_costs c using(tenant_id,item_id) where i.tenant_id=t and i.item_id=id
 )
 select jsonb_build_object('gas',b.gas,'bottle',b.bottle,'unit',b.units,'transit',h.quantity,
  'consistent',
   b.gas=s.gas_quantity and b.bottle=s.bottle_quantity+h.quantity and b.units=s.unit_quantity
   and row(b.gas,b.bottle,b.units)=row(s.pool_gas,s.pool_bottle,s.pool_unit)
   and b.external_value=s.gas_value+s.bottle_value+s.unit_value
   and not exists(select 1 from app_private.fifo_layers l left join lateral(
     select coalesce(sum(quantity),0) quantity,coalesce(sum(value),0) value,coalesce(sum(internal_value),0) transport
     from app_private.fifo_consumptions x where x.tenant_id=l.tenant_id and x.layer_id=l.layer_id) x on true
     where l.tenant_id=t and l.item_id=id and
       row(l.quantity,l.value,l.internal_value) is distinct from row(l.remaining+x.quantity,l.remaining_value+x.value,l.remaining_internal_value+x.transport))
   and not exists(select 1 from app_private.purchase_bottle_custody h join app_private.fifo_layers l using(tenant_id,layer_id)
     where h.tenant_id=t and l.item_id=id and h.settled_movement_id is null group by l.layer_id,l.remaining,l.component
     having sum(h.quantity)>l.remaining or l.component<>'bottle')
   and (select coalesce(sum(j.amount),0) from public.accounting_lines j where j.tenant_id=t
     and j.account=case when s.business_category='lpg' then 'inventory_lpg' else 'inventory_stove' end)
     =(select coalesce(sum(l.remaining_value+l.remaining_internal_value),0) from app_private.fifo_layers l
       join public.items i using(tenant_id,item_id) where l.tenant_id=t and i.business_category=s.business_category)
   and (select coalesce(sum(j.consolidated_amount),0) from public.accounting_lines j where j.tenant_id=t
     and j.account=case when s.business_category='lpg' then 'inventory_lpg' else 'inventory_stove' end)
     =(select coalesce(sum(l.remaining_value),0) from app_private.fifo_layers l
       join public.items i using(tenant_id,item_id) where l.tenant_id=t and i.business_category=s.business_category),
   'external_value',b.external_value,'transport',b.transport)
 from balances b cross join custody h cross join stock s;
$$;

create or replace function public.get_inventory_valuation()
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['inventory:view','inventory:manage']);
begin
 return (select jsonb_build_object(
  'known_value',coalesce(sum(l.remaining_value+l.remaining_internal_value),0),
  'gas_value',coalesce(sum(l.remaining_value+l.remaining_internal_value) filter(where l.component='gas'),0),
  'bottle_value',coalesce(sum(l.remaining_value+l.remaining_internal_value) filter(where l.component='bottle'),0),
  'unit_value',coalesce(sum(l.remaining_value+l.remaining_internal_value) filter(where l.component='unit'),0),
  'lpg_value',coalesce(sum(l.remaining_value+l.remaining_internal_value) filter(where i.business_category='lpg'),0),
  'stove_value',coalesce(sum(l.remaining_value+l.remaining_internal_value) filter(where i.business_category='stove'),0),
  'internal_transport_value',coalesce(sum(l.remaining_internal_value),0),
  'reconstructed_products',(select count(*) from public.inventory_costs where tenant_id=t and estimated))
 from app_private.fifo_layers l join public.items i using(tenant_id,item_id) where l.tenant_id=t);
end$$;

create or replace function public.get_inventory_cost_history(p_item_id uuid,p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['inventory:view','inventory:manage','finance:view','finance:manage']);
begin
 if p_offset is null or p_offset not between 0 and 1000000 then raise exception 'Invalid page';end if;
 return jsonb_build_object(
  'pool',(select to_jsonb(c)||jsonb_build_object('internal_value',coalesce((select sum(remaining_internal_value)
    from app_private.fifo_layers where tenant_id=t and item_id=p_item_id),0)) from public.inventory_costs c where tenant_id=t and item_id=p_item_id),
  'total',(select count(*) from public.inventory_cost_entries where tenant_id=t and item_id=p_item_id),
  'entries',coalesce((select jsonb_agg(to_jsonb(e) order by created_at desc,entry_id desc) from (
    select * from public.inventory_cost_entries where tenant_id=t and item_id=p_item_id
    order by created_at desc,entry_id desc offset p_offset limit 10) e),'[]'));
end$$;

create function public.get_fifo_stock(p_item_id uuid,p_tier text default 'retail',p_component text default 'all',p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('finance:stock');product public.items;
begin
 if p_tier is null or p_tier not in('retail','wholesale') or p_component is null or p_component not in('all','gas','bottle','unit')
   or p_offset is null or p_offset not between 0 and 1000000 then raise exception 'Invalid FIFO filters';end if;
 select * into product from public.items where tenant_id=t and item_id=p_item_id;
 if not found then raise insufficient_privilege using message='Product unavailable';end if;
 return (with prices as materialized(
  select distinct on(price_type) price_type,price,effective_from,customer_tier from public.price_books
  where tenant_id=t and item_id=p_item_id and customer_tier in(p_tier,'retail') and effective_from<=now()
    and (effective_to is null or effective_to>now())
  order by price_type,case when customer_tier=p_tier then 0 else 1 end,effective_from desc
 ), available as materialized(
  select l.*,coalesce(h.quantity,0) transit_quantity,l.remaining-coalesce(h.quantity,0) available_quantity,
    coalesce(c.estimated,true) estimated,m.reference_type source_kind,m.reference_id source_id
  from app_private.fifo_layers l join public.inventory_movements m using(tenant_id,movement_id)
  left join public.inventory_costs c on c.tenant_id=l.tenant_id and c.item_id=l.item_id
  left join lateral(select sum(quantity) quantity from app_private.purchase_bottle_custody h
    where h.tenant_id=l.tenant_id and h.layer_id=l.layer_id and h.settled_movement_id is null) h on true
  where l.tenant_id=t and l.item_id=p_item_id and l.remaining>0
    and (p_component='all' or l.component=p_component)
 ), page as (
  select *,case when not estimated then (remaining_value+remaining_internal_value)/remaining end unit_cost
  from available where available_quantity>0 order by acquired_at,acquired_order,layer_id offset p_offset limit 25
 )
 select jsonb_build_object('business',product.business_category,'generated_at',now(),'tier',p_tier,
  'total',(select count(*) from available where available_quantity>0),
  'prices',coalesce((select jsonb_agg(to_jsonb(p) order by price_type) from prices p),'[]'),
  'summary',jsonb_build_object('gas',product.gas_quantity,'bottle',product.bottle_quantity,'unit',product.unit_quantity,
    'transit_bottles',(select coalesce(sum(h.quantity),0) from app_private.purchase_bottle_custody h join app_private.fifo_layers l using(tenant_id,layer_id)
      where h.tenant_id=t and l.item_id=p_item_id and h.settled_movement_id is null)),
  'layers',coalesce((select jsonb_agg(jsonb_build_object(
    'layer_id',p.layer_id,'component',p.component,'source_kind',p.source_kind,'source_id',p.source_id,'acquired_at',p.acquired_at,
    'remaining',p.available_quantity,'in_transit',p.transit_quantity,
    'carrying_value',round((p.remaining_value+p.remaining_internal_value)*p.available_quantity/p.remaining,2),
    'unit_cost',p.unit_cost,'estimated',p.estimated,
    'projected_margin',case when p.estimated then null
      when p.component='gas' then (select price from prices where price_type='refill')-p.unit_cost
      when p.component='bottle' then (select price from prices where price_type='package')-(select price from prices where price_type='refill')-p.unit_cost
      else (select price from prices where price_type='package')-p.unit_cost end
  ) order by acquired_at,acquired_order,layer_id) from page p),'[]')));
end$$;


create or replace function app_private.action_adjust_inventory(p_payload jsonb,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 t uuid:=app_private.require_permission('inventory:adjust');product public.items;
 body jsonb:=jsonb_build_object('action','inventory_adjustment','actor',auth.uid(),'body',p_payload);
 prior public.finance_requests;part text;qty integer;gas integer;bottle integer;units integer;
 kind text:=p_payload->>'kind';counter text;movement uuid;result jsonb;
 occurred date:=coalesce((p_payload->>'date')::date,(now() at time zone 'Asia/Dhaka')::date);
 valuation jsonb;
begin
 if p_request_id is null then raise exception 'Request ID is required';end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then
  if prior.payload is distinct from body then raise exception 'Request ID already used with different details';end if;
  return prior.result;
 end if;
 if jsonb_typeof(p_payload)<>'object' or p_payload-array['item_id','kind','gas_quantity','bottle_quantity','unit_quantity',
   'gas_unit_cost','bottle_unit_cost','unit_unit_cost','reason','date']<>'{}' then raise exception 'Unsupported component adjustment fields';end if;
 if not isfinite(occurred) or occurred>(now() at time zone 'Asia/Dhaka')::date
  or kind is null or kind not in('capital','gain','lost','stolen','damaged','other_loss')
  or nullif(trim(p_payload->>'reason'),'') is null or length(p_payload->>'reason')>1000 then
  raise exception 'Enter component quantities, adjustment type and reason';
 end if;
 foreach part in array array['gas_quantity','bottle_quantity','unit_quantity'] loop
  if p_payload ? part and (jsonb_typeof(p_payload->part)<>'number'
    or (p_payload->>part)::numeric<>trunc((p_payload->>part)::numeric)) then
   raise exception 'Component quantities must be whole numbers';
  end if;
 end loop;
 gas:=coalesce((p_payload->>'gas_quantity')::integer,0);
 bottle:=coalesce((p_payload->>'bottle_quantity')::integer,0);
 units:=coalesce((p_payload->>'unit_quantity')::integer,0);
 if gas=0 and bottle=0 and units=0 or greatest(abs(gas),abs(bottle),abs(units))>1000000 then
  raise exception 'Enter valid whole component quantities';
 end if;
 if kind in('capital','gain') and least(gas,bottle,units)<0
  or kind not in('capital','gain') and greatest(gas,bottle,units)>0 then raise exception 'Adjustment quantities do not match its type';end if;
 if occurred<(now() at time zone 'Asia/Dhaka')::date then
  perform 1 from public.items where tenant_id=t order by item_id for update;
 end if;
 select * into product from public.items where tenant_id=t and item_id=(p_payload->>'item_id')::uuid for update;
 if not found then raise exception 'Product not found';end if;
 if product.business_category='lpg' and units<>0 or product.business_category='stove' and (gas<>0 or bottle<>0) then
  raise exception 'Components do not match the selected product';
 end if;
 counter:=case kind when 'capital' then 'capital' when 'gain' then 'other_income' else 'inventory_loss' end;
 valuation:=jsonb_build_object('counter_account',counter,'gas_unit_cost',p_payload->'gas_unit_cost',
   'bottle_unit_cost',p_payload->'bottle_unit_cost','unit_unit_cost',p_payload->'unit_unit_cost');
 insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,
   gas_change,bottle_change,unit_change,notes,created_by,valuation,created_at)
 values(t,product.item_id,case when kind in('capital','gain') then 'adjust_gain' else 'adjust_loss' end,
   'valued_adjustment',p_request_id,gas,bottle,units,kind||': '||trim(p_payload->>'reason'),auth.uid(),valuation,
   case when occurred=(now() at time zone 'Asia/Dhaka')::date then clock_timestamp() else (occurred+time '12:00') at time zone 'Asia/Dhaka' end)
 returning movement_id into movement;
 result:=jsonb_build_object('movement_id',movement);
 insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,result,auth.uid());
 return result;
end$$;


CREATE OR REPLACE FUNCTION app_private.action_create_pos_sale(p_customer_phone character varying, p_customer_name character varying, p_customer_shop_name character varying, p_customer_address text, p_customer_tier character varying, p_discount_amount numeric, p_exchange_fee numeric, p_notes text, p_items jsonb, p_customer_id uuid DEFAULT NULL::uuid, p_request_id uuid DEFAULT NULL::uuid, p_payments jsonb DEFAULT NULL::jsonb, p_bottles jsonb DEFAULT NULL::jsonb, p_sold_on date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  t uuid:=app_private.require_permission('pos:sell'); actor uuid:=auth.uid();
  tier text:=coalesce(p_customer_tier,'retail'); payload jsonb; saved public.sales;
  customer public.customers; sale uuid; x jsonb; stock record; qty integer; price numeric;
  expected numeric; subtotal numeric:=0; discount numeric; fee numeric; total numeric;
  component_delta integer;
  category text;wallet uuid;sold_time timestamptz:=case when p_sold_on is null then clock_timestamp() else (p_sold_on+time '15:00') at time zone 'Asia/Dhaka' end; result jsonb; payments jsonb; paid numeric; bottles jsonb;
begin
  if p_sold_on is not null then if not isfinite(p_sold_on) or p_sold_on>(now() at time zone 'Asia/Dhaka')::date then raise exception 'Invalid sale business date';end if;if p_sold_on<>(now() at time zone 'Asia/Dhaka')::date then perform app_private.require_permission('sales:backdate');end if;end if; if p_request_id is null then raise exception 'Checkout request ID is required. Refresh the application.'; end if;
  payload:=jsonb_build_object('actor',actor,'customer_id',p_customer_id,'phone',trim(p_customer_phone),
    'name',p_customer_name,'shop',p_customer_shop_name,'address',p_customer_address,'tier',tier,
    'discount',coalesce(p_discount_amount,0),'fee',coalesce(p_exchange_fee,0),'notes',p_notes,'items',p_items,'payments',p_payments,'bottles',p_bottles);
  if p_sold_on is not null then payload:=payload||jsonb_build_object('sold_on',p_sold_on);end if; perform pg_advisory_xact_lock(hashtextextended(t::text||':pos:'||p_request_id::text,0));
  select * into saved from public.sales where tenant_id=t and checkout_request_id=p_request_id;
  if found then
    if saved.checkout_payload is distinct from payload then
      raise exception 'Checkout request ID was already used with different sale details';
    end if;
    return saved.checkout_result;
  end if;
  if tier not in ('retail','wholesale') then raise exception 'Invalid sale tier'; end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then
    raise exception 'Cart must be a nonempty array';
  end if;
  select min(i.business_category) into category from jsonb_array_elements(p_items) l join public.items i on i.tenant_id=t and i.item_id=(l->>'item_id')::uuid;
  if category is null or exists(select 1 from jsonb_array_elements(p_items) l join public.items i on i.tenant_id=t and i.item_id=(l->>'item_id')::uuid where i.business_category<>category) then raise exception 'Use one business catalog per sale';end if;
  if category='stove' and (coalesce(p_exchange_fee,0)<>0 or exists(select 1 from jsonb_array_elements(p_items) l where l->>'type'<>'package') or p_bottles is not null) then raise exception 'Stove sales do not support LPG bottle settlement';end if;
  discount:=app_private.purchase_money(coalesce(p_discount_amount,0));if discount>0 then perform app_private.require_permission('sales:discount');end if;
  fee:=app_private.purchase_money(coalesce(p_exchange_fee,0));
  if nullif(trim(p_customer_phone),'') is null then raise exception 'Customer phone number is required to complete a sale'; end if;

  if p_bottles is not null and (jsonb_typeof(p_bottles)<>'object' or jsonb_typeof(p_bottles->'lines') is distinct from 'array') then raise exception 'Invalid received bottles'; end if;
  bottles:=coalesce(p_bottles,'{"lines":[]}'::jsonb);
  if p_sold_on<(now() at time zone 'Asia/Dhaka')::date then perform 1 from public.items where tenant_id=t order by item_id for update;end if;
 -- Every participating item is locked before any stock write, in the same order
  -- as purchases and inventory price saves. Price saves also lock the item first.
  for stock in select i.item_id from public.items i where i.tenant_id=t and i.item_id in
    (select (value->>'item_id')::uuid from jsonb_array_elements(p_items) union select (value->>'received_item_id')::uuid from jsonb_array_elements(bottles->'lines')) order by i.item_id for update
  loop null; end loop;
  for x in select value from jsonb_array_elements(p_items) loop
    if jsonb_typeof(x)<>'object' or x->>'type' is null or x->>'type' not in ('refill','package') then
      raise exception 'Invalid sale line';
    end if;
    qty:=app_private.purchase_integer(x->'quantity');
    if qty=0 then raise exception 'Sale quantities must be positive whole numbers'; end if;
    if jsonb_typeof(x->'unit_price') is distinct from 'number' then raise exception 'Sale prices must be finite numbers'; end if;
    price:=app_private.purchase_money((x->>'unit_price')::numeric);
    if not exists(select 1 from public.items where tenant_id=t and item_id=(x->>'item_id')::uuid) then
      raise exception 'Item not found';
    end if;
      select pb.price into expected from public.price_books pb
        where pb.tenant_id=t and pb.item_id=(x->>'item_id')::uuid and pb.price_type=x->>'type'
          and pb.customer_tier in (tier,'retail') and pb.effective_from<=statement_timestamp()
          and (pb.effective_to is null or pb.effective_to>statement_timestamp())
        order by (pb.customer_tier=tier) desc,pb.effective_from desc limit 1;
      if not found then raise exception 'No active selling price. Set the product price before checkout.'; end if;
      expected:=app_private.purchase_money(expected);
      if price<>expected then raise exception 'Selling price changed or does not match the price book. Refresh prices and review the cart.'; end if;
    subtotal:=subtotal+qty*price;
  end loop;
  subtotal:=app_private.purchase_money(subtotal);
  if discount>subtotal then raise exception 'Discount cannot exceed the product subtotal'; end if;
  total:=app_private.purchase_money(subtotal-discount+fee);
  -- Validate net stock across the complete cart, independently of line order.
  for stock in select i.item_id,i.business_category,i.gas_quantity,i.bottle_quantity,i.unit_quantity,
    sum((l.value->>'quantity')::integer) required
    from jsonb_array_elements(p_items) l join public.items i on i.tenant_id=t and i.item_id=(l.value->>'item_id')::uuid
    group by i.tenant_id,i.item_id order by i.item_id loop
    if stock.business_category='lpg' and (stock.gas_quantity<stock.required or stock.bottle_quantity<stock.required)
      or stock.business_category='stove' and stock.unit_quantity<stock.required then raise exception 'Insufficient stock';end if;
  end loop;
  if p_customer_id is not null then
    select * into customer from public.customers where tenant_id=t and customer_id=p_customer_id for share;
    if not found then raise exception 'Selected customer was not found'; end if;
    if tier is distinct from customer.tier::text then
      raise exception 'Sale pricing must match the selected customer type. Select the customer again.';
    end if;
  else
    if exists(select 1 from public.customers where tenant_id=t and phone=trim(p_customer_phone)) then
      raise exception 'This phone number belongs to a saved customer. Select the saved customer before completing the sale.';
    end if;
    insert into public.customers(tenant_id,name,phone,shop_name,address,tier)
      values(t,coalesce(nullif(trim(p_customer_name),''),'Unknown'),trim(p_customer_phone),
        nullif(trim(p_customer_shop_name),''),nullif(trim(p_customer_address),''),tier) returning * into customer;
  end if;
  if p_sold_on is null or p_sold_on=(now() at time zone 'Asia/Dhaka')::date then sold_time:=clock_timestamp();end if;
 insert into public.sales(tenant_id,customer_id,sale_tier,status,subtotal,discount_amount,exchange_fee,total_amount,
    notes,created_by,checkout_request_id,checkout_payload,business_category,created_at)
    values(t,customer.customer_id,tier,'completed',subtotal,discount,fee,total,p_notes,actor,p_request_id,payload,category,sold_time) returning sale_id into sale;
  insert into public.sale_items(tenant_id,sale_id,item_id,type,quantity,unit_price,line_total)
    select t,sale,(l->>'item_id')::uuid,(l->>'type')::public.sale_item_type,
      app_private.purchase_integer(l->'quantity'),(l->>'unit_price')::numeric,
      app_private.purchase_integer(l->'quantity')*(l->>'unit_price')::numeric
    from jsonb_array_elements(p_items) l;

  for x in select value from jsonb_array_elements(p_items) loop
    qty:=app_private.purchase_integer(x->'quantity'); price:=(x->>'unit_price')::numeric;
    component_delta:=-qty;
    insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,
      gas_change,bottle_change,unit_change,notes,created_by,valuation,created_at)
    values(t,(x->>'item_id')::uuid,'sale','sale',sale,
      case when category='lpg' then component_delta else 0 end,
      case when category='lpg' then component_delta else 0 end,
      case when category='stove' then component_delta else 0 end,
      'POS sale',actor,jsonb_build_object('sale_type',x->>'type'),sold_time);
  end loop;
  if category='lpg' then perform app_private.receive_sale_bottles(t,sale,bottles,'checkout',p_request_id);end if;
 insert into public.customer_transactions(tenant_id,customer_id,type,amount,reference_id,created_by)
    values(t,customer.customer_id,'invoice_charge',-total,sale,actor);
  select wallet_id into wallet from public.wallets where tenant_id=t and type='cash';
  payments:=coalesce(p_payments,case when total=0 then '[]'::jsonb else jsonb_build_array(jsonb_build_object('wallet_id',wallet,'amount',total)) end);
  paid:=app_private.receive_sale_payments(t,sale,payments,'checkout',p_request_id);
  update public.sales set paid_at_checkout=paid where tenant_id=t and sale_id=sale;
  result:=jsonb_build_object('sale_id',sale,'sale_tier',tier,'customer_id',customer.customer_id,'subtotal',subtotal,
    'total_amount',total,'paid_amount',paid,'due',total-paid,'customer_phone',customer.phone,'customer_name',coalesce(nullif(trim(customer.name),''),'Unknown'));
  update public.sales set checkout_result=result where tenant_id=t and sale_id=sale;
  return result;
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
 if p.recognize_on_receipt and (
  not exists(select 1 from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id)
  or p.subtotal<=0 and p.transport_cost+p.labour_cost>0) then
  raise exception 'Add products with positive buying values before dispatch or receipt';
 end if;
  perform 1 from public.employees where tenant_id=t and employee_id in(select employee_id from public.vehicle_assignments where tenant_id=t and vehicle_id=p.vehicle_id and ended_at is null) order by employee_id for update;
  if p.business_category='lpg' then perform 1 from public.gas_plants gp join public.lpg_brands b on b.tenant_id=gp.tenant_id and b.brand_id=gp.brand_id
    where gp.tenant_id=t and gp.plant_id=p.plant_id and gp.brand_id=p.brand_id and gp.is_active and b.is_active for share of gp,b;
  if not found then raise exception 'Plant company is unavailable'; end if;
  perform app_private.check_purchase_bottles(t,(select jsonb_agg(to_jsonb(pi)) from public.purchase_items pi where tenant_id=t and purchase_id=p_purchase_id));end if;
  if p_dispatched_on<(now() at time zone 'Asia/Dhaka')::date then perform 1 from public.items where tenant_id=t order by item_id for update;end if;
 perform 1 from public.items where tenant_id=t and item_id in(select item_id from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id) order by item_id for update;
 if p_dispatched_on is null or p_dispatched_on=(now() at time zone 'Asia/Dhaka')::date then dispatch_time:=clock_timestamp();end if;
  -- Acquire stock locks in SKU order. Movement inserts apply the stock once.
  update public.purchase_items set bottles_dispatched=case when p.business_category='lpg' then quantity-bottle_quantity else 0 end where tenant_id=t and purchase_id=p_purchase_id;
  for x in select i.item_id,(i.bottle_quantity-i.gas_quantity) available,i.brand_id,sum(pi.bottles_dispatched) outgoing
    from public.purchase_items pi join public.items i on i.tenant_id=pi.tenant_id and i.item_id=pi.item_id
    where pi.tenant_id=t and pi.purchase_id=p_purchase_id group by i.tenant_id,i.item_id order by i.item_id loop
    perform 1 from public.items where tenant_id=t and item_id=x.item_id for update;
    if p.business_category='lpg' and x.brand_id is distinct from p.brand_id then raise exception 'All products must belong to the plant company'; end if;
    if (select bottle_quantity-gas_quantity from public.items where tenant_id=t and item_id=x.item_id) < x.outgoing then
      raise exception 'Insufficient available Bottle stock'; end if;
    if x.outgoing>0 then
      insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,bottle_change,bottle_transit_change,notes,created_by,created_at)
      values(t,x.item_id,'purchase','purchase_dispatch',p_purchase_id,-x.outgoing,x.outgoing,'Bottles dispatched to plant',auth.uid(),dispatch_time);
    end if;
  end loop;
  insert into public.transits(tenant_id,vehicle_id,purchase_id,status,transport_fee,created_at,client_name,destination)
    values(t,p.vehicle_id,p_purchase_id,'active',p.transport_cost,dispatch_time,case when p.business_category='stove' then p.supplier_name end,case when p.business_category='stove' then 'Stove supplier collection' end);
  update public.vehicles set status='going',updated_at=now() where tenant_id=t and vehicle_id=p.vehicle_id;
  update public.purchases set status='in_transit',dispatched_at=dispatch_time,payment_status=case when paid_amount>=payable_amount then 'paid' when paid_amount>0 then 'partial' else 'unpaid' end,paid_at=case when paid_amount>=payable_amount then now() end,updated_at=now(),revision=revision+1
    where tenant_id=t and purchase_id=p_purchase_id;
  perform app_private.settle_internal_transport(t,p_purchase_id,(dispatch_time at time zone 'Asia/Dhaka')::date); insert into public.purchase_activity(tenant_id,purchase_id,created_by,message)
    values(t,p_purchase_id,auth.uid(),case when p.business_category='lpg' then
      format('Vehicle dispatched. %s bottles sent.', (select coalesce(sum(bottles_dispatched),0) from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id))
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
   if (select unit_quantity from public.items where tenant_id=t and item_id=r.item_id)<r.qty then raise exception 'Purchased stock has been consumed; return stock before cancellation';end if;
   insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,unit_change,notes,created_by)
   values(t,r.item_id,'purchase_adjustment','stove_purchase_cancellation',p_purchase_id,-r.qty,'Stove purchase cancelled',auth.uid());
  end loop;

 end if;
 -- LPG retains its pre-receipt cancellation boundary.
 for r in select m.item_id,sum(m.bottle_change) bottles from public.inventory_movements m where m.tenant_id=t and
 m.reference_id=p_purchase_id and m.reference_type='purchase_dispatch' group by m.item_id order by m.item_id loop
  perform 1 from public.items where tenant_id=t and item_id=r.item_id for update;
  if r.bottles<>0 then insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,bottle_change,bottle_transit_change,notes,created_by)
   values(t,r.item_id,'purchase_adjustment','purchase_cancellation',p_purchase_id,-r.bottles,r.bottles,'Cancelled purchase: Bottle transit released',auth.uid()); end if;
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
      insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,unit_change,notes,created_by,created_at)
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
  for r in select item_id,sum(quantity) qty,sum(bottles_dispatched) dispatched from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id
    group by item_id order by item_id loop
    perform 1 from public.items where tenant_id=t and item_id=r.item_id for update;
    insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,gas_change,bottle_change,bottle_transit_change,notes,created_by,created_at)
      values(t,r.item_id,'purchase','purchase_receipt',
      p_purchase_id,r.qty,r.qty,-r.dispatched,'Components received',auth.uid(),received_time);
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

CREATE OR REPLACE FUNCTION app_private.action_reverse_sale(p_sale_id uuid, p_reason text, p_confirmation text, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_permission('sales:cancel');s public.sales;prior public.finance_requests;body jsonb:=jsonb_build_object('action','sale_reversal','actor',auth.uid(),'sale',p_sale_id,'reason',p_reason,'confirmation',p_confirmation);r record;result jsonb;begin perform app_private.require_permission('sales:cancel');
 if p_request_id is null or p_confirmation is distinct from 'CANCEL' or nullif(trim(p_reason),'') is null or length(p_reason)>1000 then raise exception 'Reason, request ID and CANCEL confirmation are required';end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from body then raise exception 'Request ID already used';end if;return prior.result;end if;
 select * into s from public.sales where tenant_id=t and sale_id=p_sale_id for update;
 if not found or s.status<>'completed' then raise exception 'Completed sale not found';end if;
 if not exists(select 1 from public.inventory_cost_entries e join public.inventory_movements m using(tenant_id,movement_id) where e.tenant_id=t and m.reference_id=p_sale_id and m.reference_type='sale' and (e.gas_change<0 or e.unit_change<0)) or exists(select 1 from public.inventory_movements m where m.tenant_id=t and m.reference_id=p_sale_id and m.reference_type='sale' and not exists(select 1 from public.inventory_cost_entries e where e.tenant_id=t and e.movement_id=m.movement_id)) then raise exception 'Sale has no recorded carrying costs; reconcile its stock evidence before cancellation';end if;
 perform 1 from public.items where tenant_id=t and item_id in (select item_id from public.inventory_movements where tenant_id=t and reference_id=p_sale_id and reference_type='sale') order by item_id for update; for r in select item_id,-sum(gas_change) gas,-sum(bottle_change) bottles,-sum(unit_change) units from public.inventory_movements where tenant_id=t and reference_id=p_sale_id and reference_type='sale' group by item_id order by item_id loop
  perform 1 from public.items where tenant_id=t and item_id=r.item_id for update;
  insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,gas_change,bottle_change,unit_change,notes,created_by)
  values(t,r.item_id,'adjust_gain','sale_reversal',p_sale_id,r.gas,r.bottles,r.units,'Sale cancellation: '||trim(p_reason),auth.uid());
 end loop;
 perform app_private.sync_sale_bottle_reversal(t,p_sale_id,(now() at time zone 'Asia/Dhaka')::date);
 insert into public.customer_transactions(tenant_id,customer_id,type,amount,reference_id,created_by) values(t,s.customer_id,'invoice_charge',s.total_amount+s.additional_charges,p_sale_id,auth.uid());
 insert into public.sale_reversals(tenant_id,sale_id,reason,created_by) values(t,p_sale_id,trim(p_reason),auth.uid());
 update public.sales set status='voided',updated_at=clock_timestamp() where tenant_id=t and sale_id=p_sale_id;
 result:=jsonb_build_object('sale_id',p_sale_id,'refund_due',s.paid_amount);insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,result,auth.uid());return result;end $function$;

CREATE OR REPLACE FUNCTION app_private.check_purchase_bottles(t uuid, lines jsonb)
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
    sum((app_private.purchase_integer(l.value->'quantity')-app_private.purchase_integer(coalesce(l.value->'bottle_quantity','0'::jsonb)))) required,(i.bottle_quantity-i.gas_quantity) available
    from jsonb_array_elements(lines) l join public.items i on i.tenant_id=t and i.item_id=(l.value->>'item_id')::uuid
    left join public.lpg_brands b on b.tenant_id=i.tenant_id and b.brand_id=i.brand_id
    group by i.item_id,b.brand_name,i.size_kg,i.mouth_size,(i.bottle_quantity-i.gas_quantity)
    having sum((app_private.purchase_integer(l.value->'quantity')-app_private.purchase_integer(coalesce(l.value->'bottle_quantity','0'::jsonb))))>(i.bottle_quantity-i.gas_quantity)) s;
  if jsonb_array_length(shortages)>0 then
    raise exception 'Not enough bottles' using detail=shortages::text;
  end if;
end $function$;

drop function app_private.check_purchase_empties(uuid,jsonb);
CREATE OR REPLACE FUNCTION app_private.dashboard_snapshot(t uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare d date:=(now() at time zone 'Asia/Dhaka')::date;r jsonb;
 finance boolean:=app_private.has_any_permission(array['finance:view','finance:manage']);
 customers boolean:=app_private.has_any_permission(array['customers:view','customers:manage']);
 inventory boolean:=app_private.has_any_permission(array['inventory:view','inventory:manage']);
begin
 with days as (select generate_series(d-6,d,interval '1 day')::date business_day),
 recognition as materialized(
  select j.occurred_on business_day,
   coalesce(-sum(l.amount) filter(where case when finance then a.kind='income' else l.account='sales_revenue' end),0) revenue,
   case when finance then coalesce(sum(l.amount) filter(where a.kind='expense'),0) end expense
  from public.accounting_journals j join public.accounting_lines l using(tenant_id,journal_id) join public.accounting_accounts a on a.code=l.account
  where j.tenant_id=t and j.occurred_on between d-6 and d and not j.is_opening group by j.occurred_on),
 collections as (select (p.created_at at time zone 'Asia/Dhaka')::date business_day,sum(p.amount) collected
  from public.sale_payments p where p.tenant_id=t and p.created_at >= (d-6)::timestamp at time zone 'Asia/Dhaka'
  and p.created_at < (d+1)::timestamp at time zone 'Asia/Dhaka' group by 1),
 sale_counts as (select (s.created_at at time zone 'Asia/Dhaka')::date business_day,count(*) sales
  from public.sales s where s.tenant_id=t and s.status='completed' and s.created_at >= (d-6)::timestamp at time zone 'Asia/Dhaka'
  and s.created_at < (d+1)::timestamp at time zone 'Asia/Dhaka' group by 1),
 today_sales as materialized(select s.* from public.sales s where s.tenant_id=t and s.status='completed'
  and s.created_at>=d::timestamp at time zone 'Asia/Dhaka' and s.created_at<(d+1)::timestamp at time zone 'Asia/Dhaka'),
 sold as materialized(select i.item_id,i.size_kg,i.business_category,i.product_name,i.image_url,sum(si.quantity) quantity
  from today_sales s join public.sale_items si using(tenant_id,sale_id) join public.items i using(tenant_id,item_id)
  where si.type in ('refill','package') group by i.item_id,i.size_kg,i.business_category,i.product_name,i.image_url),
 expected as (select si.sale_id,sum(si.quantity) quantity from public.sale_items si where customers and si.tenant_id=t and si.type='refill' group by si.sale_id),
 received as (select b.sale_id,sum(b.quantity) quantity from public.sale_bottle_receipt_lines b where customers and b.tenant_id=t group by b.sale_id),
 bottle_due as materialized(select s.customer_id,greatest(0,e.quantity-coalesce(b.quantity,0)) quantity
  from expected e join public.sales s on s.tenant_id=t and s.sale_id=e.sale_id left join received b on b.sale_id=e.sale_id where s.status='completed'),
 weights as (select size_kg from public.business_weights where tenant_id=t and is_active
  union select size_kg from sold where business_category='lpg')
 select jsonb_build_object('date',d,'generated_at',now(),'finance_visible',finance,
 'days',(select jsonb_agg(jsonb_build_object('date',days.business_day,'revenue',coalesce(x.revenue,0),'expense',case when finance then coalesce(x.expense,0) end,
  'collected',coalesce(c.collected,0),'sales',coalesce(s.sales,0)) order by days.business_day) from days left join recognition x using(business_day) left join collections c using(business_day) left join sale_counts s using(business_day)),
 'bottles',coalesce((select jsonb_agg(jsonb_build_object('size_kg',w.size_kg,'quantity',coalesce((select sum(quantity) from sold where business_category='lpg' and size_kg=w.size_kg),0)) order by w.size_kg) from weights w),'[]'),
 'stove_types',app_private.dashboard_stove_types(t),
 'attention',jsonb_build_object(
  'customer_due',case when customers then (select coalesce(sum(total_due),0) from app_private.customer_metrics where tenant_id=t and total_due>0) end,
  'customers',case when customers then (select count(*) from app_private.customer_metrics where tenant_id=t and total_due>0) end,
  'bottles',case when customers then (select coalesce(sum(quantity),0) from bottle_due) end,
  'bottle_customers',case when customers then (select count(distinct customer_id) from bottle_due where quantity>0) end,
  'low_stock',case when inventory then (select count(*) from public.items where tenant_id=t and gas_quantity+unit_quantity<low_stock_threshold) end),
 'sales',coalesce((select jsonb_agg(x order by x.created_at desc,x.sale_id desc) from (
  select s.sale_id,s.created_at,s.total_amount+s.additional_charges amount,coalesce(c.shop_name,c.name,'Customer') customer,
   (select string_agg(coalesce(i.product_name,'LPG '||i.size_kg||' kg')||' × '||si.quantity||case when si.type='package' then ' (Package)' else '' end,', ' order by si.item_id,si.type)
    from public.sale_items si join public.items i using(tenant_id,item_id) where si.tenant_id=t and si.sale_id=s.sale_id and si.type in('refill','package')) items
  from today_sales s left join public.customers c using(tenant_id,customer_id) order by s.created_at desc,s.sale_id desc limit 5)x),'[]'),
 'activity',public.get_dashboard_activity(0,6)) into r;
 return r;
end $function$;

CREATE OR REPLACE FUNCTION app_private.queue_reconciliation(t uuid, k text, id uuid, due timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS void
 LANGUAGE sql
 SET search_path TO ''
AS $function$
 insert into app_private.reconciliation_queue(tenant_id,kind,entity_id,available_at) values(t,k,id,
 coalesce(due,((case when (clock_timestamp() at time zone 'Asia/Dhaka')::time<'03:00'::time then (clock_timestamp() at time zone 'Asia/Dhaka')::date else (clock_timestamp() at time zone 'Asia/Dhaka')::date+1 end+time '03:00') at time zone 'Asia/Dhaka')))
 on conflict(tenant_id,kind,entity_id) do update set generation=reconciliation_queue.generation+1,changed_at=clock_timestamp(),available_at=least(reconciliation_queue.available_at,excluded.available_at),attempts=0;$function$;

CREATE OR REPLACE FUNCTION app_private.receive_sale_bottles(t uuid, sid uuid, body jsonb, phase text, op uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare s public.sales; x jsonb; rid uuid; qty integer; expected bigint; received bigint; incoming bigint:=0;
 original bigint; previous bigint; note text:=btrim(coalesce(body->>'note',''));
begin
 select * into s from public.sales where tenant_id=t and sale_id=sid for update;
 if not found or s.status<>'completed' then raise exception 'Sale does not support bottle collection'; end if;
 if body is null or jsonb_typeof(body)<>'object' or jsonb_typeof(body->'lines') is distinct from 'array' or jsonb_array_length(body->'lines')>200 then raise exception 'Use up to 200 received products'; end if;
 if length(note)>1000 then raise exception 'Bottle note is too long'; end if;
 if body - array['lines','note','fee'] <> '{}'::jsonb or exists(select 1 from jsonb_array_elements(body->'lines') l where jsonb_typeof(l)<>'object' or l - array['received_item_id','quantity','acknowledged'] <> '{}'::jsonb) then raise exception 'Unsupported bottle fields'; end if;
 if phase='checkout' and coalesce((body->>'fee')::numeric,0)<>0 then raise exception 'Use the checkout exchange cost field'; end if;
 if exists(select 1 from jsonb_array_elements(body->'lines') l group by l->>'received_item_id' having count(*)>1) then raise exception 'Use one quantity per received product'; end if;
 select coalesce(sum(quantity),0) into expected from public.sale_items where type='refill' and tenant_id=t and sale_id=sid;
 select coalesce(sum(quantity),0) into received from public.sale_bottle_receipt_lines where tenant_id=t and sale_id=sid;
 for x in select value from jsonb_array_elements(body->'lines') loop
  qty:=app_private.purchase_integer(x->'quantity');
  if qty<=0 then raise exception 'Received quantities must be positive whole numbers'; end if;
  incoming:=incoming+qty;
 end loop;
 if phase='collection' and incoming=0 then raise exception 'Add at least one received bottle'; end if;
 if phase='collection' and received>=expected then raise exception 'Bottle obligation is already settled'; end if;
 if expected=0 and incoming>0 then raise exception 'Sale has no bottle obligation'; end if;
 -- Keep actual quantities uncapped. Product acknowledgements below cover excess.
 -- Same lock order as checkout/purchases: sale, actual products.
 perform 1 from public.items where tenant_id=t and item_id in(select (l->>'received_item_id')::uuid from jsonb_array_elements(body->'lines') l) order by item_id for update;
 for x in select value from jsonb_array_elements(body->'lines') loop
  if not exists(select 1 from public.items where tenant_id=t and item_id=(x->>'received_item_id')::uuid) then raise exception 'Received product not found in this business'; end if;
  select coalesce(sum(quantity),0) into original from public.sale_items where type='refill' and tenant_id=t and sale_id=sid and item_id=(x->>'received_item_id')::uuid;
  select coalesce(sum(quantity),0) into previous from public.sale_bottle_receipt_lines where tenant_id=t and sale_id=sid and received_item_id=(x->>'received_item_id')::uuid;
  if (original=0 or previous+(x->>'quantity')::integer>original) and coalesce((x->>'acknowledged')::boolean,false) is not true then raise exception 'Acknowledge unexpected products or receipts exceeding the original product quantity'; end if;
 end loop;
 insert into public.sale_bottle_receipts(tenant_id,sale_id,phase,operation_id,note,created_by,fee,created_at)
 values(t,sid,phase,op,note,auth.uid(),coalesce((body->>'fee')::numeric,0),case when phase='checkout' then s.created_at else clock_timestamp() end) returning receipt_id into rid;
 for x in select value from jsonb_array_elements(body->'lines') loop
  qty:=app_private.purchase_integer(x->'quantity');
  insert into public.sale_bottle_receipt_lines(tenant_id,receipt_id,sale_id,received_item_id,quantity,acknowledged)
  values(t,rid,sid,(x->>'received_item_id')::uuid,qty,coalesce((x->>'acknowledged')::boolean,false));
  insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,bottle_change,notes,created_by,created_at)
  values(t,(x->>'received_item_id')::uuid,'sale','sale',sid,qty,'Bottle '||phase||' #'||rid::text||case when note='' then '' else ': '||note end,auth.uid(),case when phase='checkout' then s.created_at else clock_timestamp() end);
 end loop;
 return rid;
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
  perform 1 from public.items where tenant_id=t and item_id=id for update nowait;
  if not found then return false;end if;
  observed:=app_private.component_inventory_evidence(t,id);
  expected:=observed||jsonb_build_object('consistent',true);
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

CREATE OR REPLACE FUNCTION app_private.run_accounting_maintenance(batch_size integer DEFAULT 40)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare r record;t uuid;n integer:=0;problems integer:=0;errs integer:=0;run bigint;deadline timestamptz:=clock_timestamp()+interval '15 seconds';begin
 if batch_size not between 1 and 100 then raise exception 'Invalid reconciliation batch';end if;
 if not pg_try_advisory_xact_lock(hashtextextended('lpg:accounting:maintenance',0)) then return jsonb_build_object('skipped','already running');end if;
 if not exists(select 1 from app_private.reconciliation_queue where available_at<=clock_timestamp()) and not exists(select 1 from app_private.reconciliation_sweeps where completed_at is null) then return jsonb_build_object('idle',true);end if;
 insert into app_private.reconciliation_runs default values returning run_id into run;
 perform app_private.reconciliation_sweep_batch(100);
 for r in select * from app_private.reconciliation_queue where available_at<=clock_timestamp() order by changed_at limit batch_size loop
  exit when clock_timestamp()>deadline;
  begin
   if r.kind='payroll' then perform app_private.sync_payroll(r.tenant_id);end if;
   if app_private.reconcile_record(r.tenant_id,r.kind,r.entity_id) then problems:=problems+1;end if;
   delete from app_private.reconciliation_queue where tenant_id=r.tenant_id and kind=r.kind and entity_id=r.entity_id and generation=r.generation;
  exception when lock_not_available then
   update app_private.reconciliation_queue set available_at=clock_timestamp()+interval '1 minute' where tenant_id=r.tenant_id and kind=r.kind and entity_id=r.entity_id;
  when others then
   errs:=errs+1;
   insert into app_private.reconciliation_findings(tenant_id,kind,entity_id,observed,expected,status,diagnostic) values(r.tenant_id,r.kind,r.entity_id,'{}','{}','error','Reconciliation failed: '||sqlstate||' · '||left(sqlerrm,500));
   update app_private.reconciliation_queue set attempts=attempts+1,available_at=clock_timestamp()+case when attempts>=4 then interval '1 day' else interval '10 minutes' end where tenant_id=r.tenant_id and kind=r.kind and entity_id=r.entity_id;
  end;n:=n+1;
 end loop;
 update app_private.reconciliation_runs set finished_at=clock_timestamp(),checked=n,discrepancies=problems,errors=errs where run_id=run;
 return jsonb_build_object('checked',n,'discrepancies',problems,'errors',errs);end $function$;

CREATE OR REPLACE FUNCTION app_private.save_purchase_lines(p_tenant uuid, p_purchase uuid, p_lines jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
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
   insert into public.purchase_items(tenant_id,purchase_id,item_id,quantity,bottle_quantity,unit_price,bottle_unit_price,bottles_dispatched)
   values(p_tenant,p_purchase,line_id,q,b,price,bp,0);
  else
   if not exists(select 1 from public.purchase_items pi where pi.tenant_id=p_tenant and pi.purchase_id=p_purchase and pi.purchase_item_id=(x->>'purchase_item_id')::uuid and pi.item_id=line_id and pi.quantity=q and pi.bottle_quantity=b) then raise exception 'Dispatched products and quantities are locked';end if;
   update public.purchase_items set unit_price=price,bottle_unit_price=bp where tenant_id=p_tenant and purchase_id=p_purchase and item_id=line_id;
  end if;
 end loop;
end$function$;

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
   when m.reference_type='sale' then case when m.gas_change>0 or m.bottle_change>0 then 'bottle_return' else 'inventory_sale' end
   when m.valuation->>'counter_account'='opening_equity' then 'inventory_opening'
   when m.valuation->>'counter_account'='capital' then 'inventory_capital'
   when m.gas_change<0 or m.bottle_change<0 or m.unit_change<0 then 'inventory_loss' else 'inventory_gain' end;
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

CREATE OR REPLACE FUNCTION app_private.sync_journal(t uuid, src text, id uuid, d date, note text, target jsonb, opening_entry boolean DEFAULT false)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$declare prior app_private.accounting_source_state;delta jsonb;begin
 target:=app_private.dimension_entries(t,src,id,target);
 -- Replay needs prior account dimensions and amounts, not repeated empty/null
 -- metadata or a duplicate external amount when it equals the business amount.
 select coalesce(jsonb_agg(
  (case when coalesce(x->'details','{}')='{}' then jsonb_strip_nulls(x)-'details' else jsonb_strip_nulls(x) end)
  -case when (x->>'consolidated_amount')::numeric=(x->>'amount')::numeric then 'consolidated_amount' else '__unused__' end),'[]') into target
 from jsonb_array_elements(target)x;
 insert into app_private.accounting_source_state values(t,src,id,'[]',0) on conflict do nothing;
 select * into prior from app_private.accounting_source_state where tenant_id=t and source=src and source_id=id for update;
 with all_lines as(select x,1 sign from jsonb_array_elements(target)x union all select x,-1 from jsonb_array_elements(prior.lines)x),
 grouped as(select x->>'account' account,x->>'business_category' category,(x->>'entity_id')::uuid entity,(x->>'type_id')::uuid type_id,
  sum(sign*(x->>'amount')::numeric) amount,sum(sign*coalesce((x->>'consolidated_amount')::numeric,(x->>'amount')::numeric)) consolidated_amount from all_lines group by 1,2,3,4)
 select coalesce(jsonb_agg(app_private.accounting_line(account,amount,category,entity)||jsonb_build_object('type_id',type_id,'consolidated_amount',consolidated_amount)) filter(where amount<>0 or consolidated_amount<>0),'[]') into delta from grouped;
 if delta<>'[]' then perform app_private.post_journal(t,src,id,(prior.revision+1)::text,d,note,delta,false,opening_entry);
 update app_private.accounting_source_state set lines=target,revision=revision+1 where tenant_id=t and source=src and source_id=id;end if;
end $function$;

CREATE OR REPLACE FUNCTION public.get_customer_bottle_balance(p_customer_id uuid)
 RETURNS bigint
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_any_permission(array['customers:view','customers:manage','finance:view','finance:manage']); result bigint;
begin
 if not exists(select 1 from public.customers where tenant_id=t and customer_id=p_customer_id) then raise exception 'Customer not found'; end if;
 select coalesce(sum(greatest(0,
 (select coalesce(sum(quantity),0) from public.sale_items where type='refill' and tenant_id=t and sale_id=s.sale_id)-
 (select coalesce(sum(quantity),0) from public.sale_bottle_receipt_lines where tenant_id=t and sale_id=s.sale_id))),0) into result
 from public.sales s where s.tenant_id=t and s.customer_id=p_customer_id and s.status='completed';
 return result;
end $function$;

CREATE OR REPLACE FUNCTION public.get_customer_directory(p_filters jsonb DEFAULT '{}'::jsonb, p_offset integer DEFAULT 0, p_limit integer DEFAULT 12, p_customer_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
 SET plan_cache_mode TO 'force_custom_plan'
AS $function$
declare
  t uuid:=app_private.require_any_permission(array['customers:view','customers:manage']);
  ids uuid[]; result jsonb; ordering text:=coalesce(p_filters->>'sort','name_asc');
  from_day date:=nullif(p_filters->>'from','')::date; to_day date:=nullif(p_filters->>'to','')::date;
  activity_filter boolean; page_first boolean;
begin
  perform app_private.validate_customer_filters(p_filters); if coalesce(p_filters->>'dues','all') not in ('all','payment','bottle','both','none') then raise exception 'Invalid customer dues filter';end if;
  if p_offset is null or p_limit is null or p_offset<0 or p_offset>1000000 or p_limit not between 1 and 100 then raise exception 'Invalid customer page'; end if;
  if jsonb_typeof(p_filters->'item_ids')='array' then select coalesce(array_agg(distinct value::uuid),'{}'::uuid[]) into ids from jsonb_array_elements_text(p_filters->'item_ids'); end if;
  activity_filter:=from_day is not null or to_day is not null or ids is not null
    or exists(select 1 from jsonb_each_text(p_filters) f
      where f.key in ('transactions_min','transactions_max','refill_min','refill_max','package_min','package_max') and nullif(f.value,'') is not null);
  -- Only unscoped name ordering can safely select customers before reading sales.
  -- Both paths share one relational sales scope and response shape.
  page_first:=not activity_filter and ordering in ('name_asc','name_desc');
  with bottle_due as materialized (
   select distinct s.customer_id from public.sales s
   join (select sale_id,sum(quantity) quantity from public.sale_items where tenant_id=t and type='refill' group by sale_id)e on e.sale_id=s.sale_id
   left join (select sale_id,sum(quantity) quantity from public.sale_bottle_receipt_lines where tenant_id=t group by sale_id)r on r.sale_id=s.sale_id
   where s.tenant_id=t and s.status='completed' and coalesce(p_filters->>'dues','all')<>'all' and e.quantity>coalesce(r.quantity,0)
 ), dues_scope as materialized (
   select c.customer_id from public.customers c
   left join app_private.customer_metrics m on m.tenant_id=c.tenant_id and m.customer_id=c.customer_id
   left join bottle_due b on b.customer_id=c.customer_id
   where c.tenant_id=t and coalesce(p_filters->>'dues','all')<>'all'
   and case p_filters->>'dues'
    when 'payment' then coalesce(m.ledger_balance,0)<0
    when 'bottle' then b.customer_id is not null
    when 'both' then coalesce(m.ledger_balance,0)<0 and b.customer_id is not null
    when 'none' then coalesce(m.ledger_balance,0)>=0 and b.customer_id is null
    else false end
 ), candidates as materialized (
    select c.tenant_id,c.customer_id,c.name,c.phone,c.shop_name,c.address,
      case when c.tier='wholesale' then 'wholesale' else 'retail' end tier,c.created_at,
      coalesce(nullif(case when c.tier='wholesale' then c.shop_name end,''),c.name) display_name
    from public.customers c where c.tenant_id=t and (coalesce(p_filters->>'dues','all')='all' or c.customer_id in(select customer_id from dues_scope)) and (p_customer_id is null or c.customer_id=p_customer_id)
      and (coalesce(p_filters->>'tier','all')='all' or p_filters->>'tier'=case when c.tier='wholesale' then 'wholesale' else 'retail' end)
      and (not exists(select 1 from regexp_split_to_table(coalesce(p_filters->>'search',''),'\s*,\s*') g where btrim(g)<>'')
        or exists(select 1 from regexp_split_to_table(lower(p_filters->>'search'),'\s*,\s*') g where btrim(g)<>'' and not exists(
          select 1 from regexp_split_to_table(btrim(g),'\s+') token where token<>''
          and position(token in lower(concat_ws(' ',c.name,c.shop_name,c.phone,c.address,c.tier,
            case when c.phone like '08801%' then substring(c.phone from 4) else '088'||c.phone end)))=0)))
  ), scoped_customers as materialized (
    select * from candidates order by
      case when page_first and ordering='name_asc' then lower(display_name) end asc,
      case when page_first and ordering='name_desc' then lower(display_name) end desc,customer_id
    limit case when page_first then p_limit end offset case when page_first then p_offset else 0 end
  ), headers as materialized (
    select s.customer_id,s.sale_id,s.created_at,s.total_amount+s.additional_charges total_amount,
      greatest(0,s.total_amount+s.additional_charges-s.paid_amount) due
    from public.sales s join scoped_customers c on c.customer_id=s.customer_id
    where s.tenant_id=t and s.status='completed' and (from_day is not null or to_day is not null or ids is not null)
      and (from_day is null or s.created_at >= (from_day::timestamp at time zone 'Asia/Dhaka'))
      and (to_day is null or s.created_at < ((to_day+1)::timestamp at time zone 'Asia/Dhaka'))
  ), quantities as (
    select si.sale_id,
      sum(si.quantity) filter(where si.type='refill') refill,
      sum(si.quantity) filter(where si.type='package') package
    from public.sale_items si join headers h on h.sale_id=si.sale_id
    where si.tenant_id=t and si.type in ('refill','package') and (ids is null or si.item_id=any(ids))
    group by si.sale_id
  ), qualifying as (
    select h.*,coalesce(q.refill,0) refill,coalesce(q.package,0) package
    from headers h left join quantities q on q.sale_id=h.sale_id
    where ids is null or q.sale_id is not null
  ), activity as materialized (
    select a.customer_id,count(*) transactions,sum(a.refill) refill,sum(a.package) package,
      sum(a.total_amount) total_sold_amount,sum(a.due) total_due,max(a.created_at) last_transaction_at
    from qualifying a group by a.customer_id
    union all select m.customer_id,m.transactions,m.refill,m.package,m.total_sold_amount,greatest(0,-m.ledger_balance),m.last_transaction_at from app_private.customer_metrics m join scoped_customers c on c.customer_id=m.customer_id where m.tenant_id=t and from_day is null and to_day is null and ids is null
  ), filtered as materialized (
    select c.*,coalesce(a.transactions,0) transactions,coalesce(a.refill,0) refill,coalesce(a.package,0) package,
      coalesce(a.refill,0)+coalesce(a.package,0) total_sold,
      coalesce(a.total_sold_amount,0) total_sold_amount,coalesce(a.total_due,0) total_due,a.last_transaction_at
    from scoped_customers c left join activity a on a.customer_id=c.customer_id
    where (not activity_filter or a.transactions>0)
      and coalesce(a.transactions,0)>=coalesce(nullif(p_filters->>'transactions_min','')::bigint,0)
      and (nullif(p_filters->>'transactions_max','') is null or a.transactions<=(p_filters->>'transactions_max')::bigint)
      and coalesce(a.refill,0)>=coalesce(nullif(p_filters->>'refill_min','')::bigint,0)
      and (nullif(p_filters->>'refill_max','') is null or a.refill<=(p_filters->>'refill_max')::bigint)
      and coalesce(a.package,0)>=coalesce(nullif(p_filters->>'package_min','')::bigint,0)
      and (nullif(p_filters->>'package_max','') is null or a.package<=(p_filters->>'package_max')::bigint)
  ), ranked as (
    select f.*,row_number() over(order by
      case when ordering='name_asc' then lower(display_name) end asc,
      case when ordering='name_desc' then lower(display_name) end desc,
      case when ordering='sold_asc' then total_sold_amount end asc,
      case when ordering='sold_desc' then total_sold_amount end desc,
      case when ordering='due_asc' then total_due end asc,
      case when ordering='due_desc' then total_due end desc,
      case when ordering='last_sale_asc' then last_transaction_at end asc nulls last,
      case when ordering='last_sale_desc' then last_transaction_at end desc nulls last,customer_id) ordinal
    from filtered f
  ), page as (
    select * from ranked order by ordinal limit p_limit offset case when page_first then 0 else p_offset end
  ) select jsonb_build_object('total',case when page_first then (select count(*) from candidates) else (select count(*) from filtered) end,
    'entries',coalesce((select jsonb_agg(to_jsonb(p)-'ordinal' order by ordinal) from page p),'[]'::jsonb)) into result;
  return result;
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
   'items',jsonb_build_object('product_name',i.product_name,'size_kg',i.size_kg,'gas_quantity',i.gas_quantity,'unit_quantity',i.unit_quantity,
    'bottle_quantity',i.bottle_quantity,'mouth_size',i.mouth_size,'lpg_brands',case when b.brand_id is not null then jsonb_build_object('brand_id',b.brand_id,'brand_name',b.brand_name) end),
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
      coalesce((select sum(l.quantity) from public.sale_bottle_receipt_lines l join public.sale_bottle_receipts r on r.tenant_id=t and r.receipt_id=l.receipt_id join public.sales actual_sale on actual_sale.tenant_id=r.tenant_id and actual_sale.sale_id=r.sale_id and actual_sale.status='completed' where l.tenant_id=t and l.received_item_id=p_item_id and r.created_at >= (w.start_date::timestamp at time zone 'Asia/Dhaka') and r.created_at < (w.end_date::timestamp at time zone 'Asia/Dhaka')),0) bottles_received,
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

CREATE OR REPLACE FUNCTION public.get_product_performance(p_business text, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_permission('finance:stock');begin
 if p_business not in('lpg','stove') or p_business is null or p_offset is null or p_offset<0 or p_offset>1000000
 or (p_from is not null and not isfinite(p_from)) or (p_to is not null and not isfinite(p_to)) or p_from>p_to then raise exception 'Invalid reporting range';end if;
 return (with sale_lines as materialized(
  select si.tenant_id,si.sale_item_id,si.sale_id,si.item_id,si.type::text type,si.quantity,si.line_total,s.created_at sold_at,s.discount_amount,s.subtotal,
   sum(si.line_total) over(partition by si.sale_id order by si.item_id,si.type,si.sale_item_id) cumulative,
   r.created_at reversed_at
  from public.sale_items si join public.sales s using(tenant_id,sale_id)
  left join public.sale_reversals r using(tenant_id,sale_id)
  where si.tenant_id=t and s.business_category=p_business and s.status in('completed','voided') and si.type in('refill','package')
  and (((p_from is null or s.created_at>=p_from::timestamp at time zone 'Asia/Dhaka') and (p_to is null or s.created_at<(p_to+1)::timestamp at time zone 'Asia/Dhaka'))
   or (r.created_at is not null and (p_from is null or r.created_at>=p_from::timestamp at time zone 'Asia/Dhaka') and (p_to is null or r.created_at<(p_to+1)::timestamp at time zone 'Asia/Dhaka')))
 ), priced as materialized(
  select sl.*,sl.line_total-case when sl.subtotal>0 then
   round(sl.discount_amount*sl.cumulative/sl.subtotal,2)-round(sl.discount_amount*(sl.cumulative-sl.line_total)/sl.subtotal,2) else 0 end revenue,
   c.cost,c.qty,coalesce(c.estimated,false) estimated
  from sale_lines sl left join lateral(
   select sum(fc.quantity) filter(where l.component in('gas','unit')) qty,
    sum(fc.value+fc.internal_value) filter(where sl.type='package' or l.component='gas') cost,
    bool_or(coalesce(ce.estimated,true)) estimated
   from public.inventory_movements m join app_private.fifo_consumptions fc using(tenant_id,movement_id)
   join app_private.fifo_layers l using(tenant_id,layer_id)
   left join public.inventory_cost_entries ce on ce.tenant_id=l.tenant_id and ce.movement_id=l.movement_id and not ce.is_correction
   where m.tenant_id=t and m.reference_type='sale' and m.reference_id=sl.sale_id and m.item_id=sl.item_id
    and (m.gas_change<0 or m.unit_change<0) and m.valuation->>'sale_type'=sl.type
  ) c on true
 ), events as materialized(
  select p.item_id,p.type,e.at,e.sign*p.quantity sold,e.sign*p.revenue revenue,e.sign*p.cost cogs,
   case when p.qty is distinct from p.quantity then p.quantity else 0 end missing_units,
   case when p.estimated then p.quantity else 0 end estimated_units
  from priced p cross join lateral(values(p.sold_at,1),(p.reversed_at,-1)) e(at,sign)
  where e.at is not null and (p_from is null or e.at>=p_from::timestamp at time zone 'Asia/Dhaka')
   and (p_to is null or e.at<(p_to+1)::timestamp at time zone 'Asia/Dhaka')
 ), sold as materialized(
  select item_id,type,sum(sold) sold,sum(revenue) revenue,sum(cogs) cogs,sum(missing_units) missing_units,sum(estimated_units) estimated_units
  from events group by item_id,type
 ), bought as materialized(
  select pi.item_id,ty.type,sum(e.sign*case when p_business='stove' then pi.quantity when ty.type='refill' then pi.quantity-pi.bottle_quantity else pi.bottle_quantity end) bought
  from public.purchase_items pi join public.purchases p using(tenant_id,purchase_id)
  cross join lateral(values(p.received_at,1),(case when p.status='cancelled' and p.received_at is not null then p.cancelled_at end,-1)) e(at,sign)
  cross join lateral(select 'package'::text type union all select 'refill' where p_business='lpg') ty
  where pi.tenant_id=t and p.business_category=p_business and p.received_at is not null and e.at is not null
   and (p_from is null or e.at>=p_from::timestamp at time zone 'Asia/Dhaka') and (p_to is null or e.at<(p_to+1)::timestamp at time zone 'Asia/Dhaka')
  group by pi.item_id,ty.type
 ), entries as materialized(
  select i.item_id,ty.type,coalesce(b.brand_name,st.name) category,
   case when p_business='lpg' then i.size_kg::text||' kg · '||i.mouth_size::text else i.product_name end product_name,
   coalesce(s.sold,0) sold,coalesce(p.bought,0) bought,coalesce(s.revenue,0) revenue,
   case when coalesce(s.missing_units,0)=0 then coalesce(s.cogs,0) end cogs,
   case when coalesce(s.missing_units,0)=0 then coalesce(s.revenue,0)-coalesce(s.cogs,0) end margin,
   case when coalesce(s.missing_units,0)=0 and s.sold>0 then round((s.revenue-coalesce(s.cogs,0))/s.sold,2) end average_margin,
   coalesce(s.missing_units,0) missing_units,coalesce(s.estimated_units,0) estimated_units
  from public.items i left join public.lpg_brands b using(tenant_id,brand_id)
  left join public.stove_product_types st on st.tenant_id=i.tenant_id and st.type_id=i.product_type_id
  cross join lateral(select 'package'::text type union all select 'refill' where p_business='lpg') ty
  left join sold s on s.item_id=i.item_id and s.type=ty.type left join bought p on p.item_id=i.item_id and p.type=ty.type
  where i.tenant_id=t and i.business_category=p_business
 ), page as(select * from entries order by category,product_name,item_id,type desc limit 25 offset p_offset),
 totals as(select coalesce(sum(sold),0) sold,coalesce(sum(bought),0) bought,coalesce(sum(revenue),0) revenue,
  case when coalesce(sum(missing_units),0)=0 then coalesce(sum(cogs),0) end cogs,
  case when coalesce(sum(missing_units),0)=0 then coalesce(sum(margin),0) end margin,
  case when coalesce(sum(missing_units),0)=0 and sum(sold)>0 then round(sum(margin)/sum(sold),2) end average_margin,
  coalesce(sum(missing_units),0) missing_units,coalesce(sum(estimated_units),0) estimated_units from entries)
 select jsonb_build_object('total',(select count(*) from entries),'generated_at',now(),'business',p_business,
  'rows',coalesce((select jsonb_agg(to_jsonb(p) order by category,product_name,item_id,type desc) from page p),'[]'),
  'totals',(select to_jsonb(totals) from totals)));
end $function$;

CREATE OR REPLACE FUNCTION public.get_sale_bottles(p_sale_id uuid, p_offset integer DEFAULT 0, p_limit integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_any_permission(array['sales:view','receipts:print','sales:collect_bottles']); s public.sales; result jsonb;
begin
 if p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid bottle history page'; end if;
 select * into s from public.sales where tenant_id=t and sale_id=p_sale_id;
 if not found then raise exception 'Sale not found'; end if;
 with obligations as materialized (
  select o.item_id,concat_ws(' ',b.brand_name,i.size_kg||'kg',i.mouth_size) name,i.size_kg,i.mouth_size,o.expected_quantity expected,
    coalesce(sum(l.quantity),0) received,o.expected_quantity-coalesce(sum(l.quantity),0) difference
  from (select tenant_id,sale_id,item_id,sum(quantity) expected_quantity from public.sale_items where type='refill' and tenant_id=t and sale_id=p_sale_id group by tenant_id,sale_id,item_id) o join public.items i on i.tenant_id=t and i.item_id=o.item_id
  left join public.lpg_brands b on b.tenant_id=t and b.brand_id=i.brand_id
  left join public.sale_bottle_receipt_lines l on l.tenant_id=t and l.sale_id=o.sale_id and l.received_item_id=o.item_id
  where o.tenant_id=t and o.sale_id=p_sale_id group by o.item_id,o.expected_quantity,i.size_kg,i.mouth_size,b.brand_name
 ), actual as materialized (
  select r.phase,l.received_item_id item_id,concat_ws(' ',b.brand_name,i.size_kg||'kg',i.mouth_size) name,sum(l.quantity) quantity
  from public.sale_bottle_receipts r join public.sale_bottle_receipt_lines l on l.tenant_id=t and l.receipt_id=r.receipt_id
  join public.items i on i.tenant_id=t and i.item_id=l.received_item_id left join public.lpg_brands b on b.tenant_id=t and b.brand_id=i.brand_id
  where r.tenant_id=t and r.sale_id=p_sale_id group by r.phase,l.received_item_id,b.brand_name,i.size_kg,i.mouth_size
 ), events as materialized (
  select r.receipt_id id,r.created_at,'bottles' kind,r.phase,r.note,r.fee amount,r.expense,r.expense_wallet_name,coalesce(u.full_name,u.email,'Operator') actor,
   coalesce((select jsonb_agg(jsonb_build_object('received_item_id',l.received_item_id,'quantity',l.quantity,'acknowledged',l.acknowledged,
     'received_name',concat_ws(' ',rb.brand_name,ri.size_kg||'kg',ri.mouth_size)) order by l.line_id)
    from public.sale_bottle_receipt_lines l
    join public.items ri on ri.tenant_id=t and ri.item_id=l.received_item_id
    left join public.lpg_brands rb on rb.tenant_id=t and rb.brand_id=ri.brand_id
    where l.tenant_id=t and l.receipt_id=r.receipt_id),'[]') lines
  from public.sale_bottle_receipts r left join app_private.tenant_actors u on u.tenant_id=t and u.user_id=r.created_by where r.tenant_id=t and r.sale_id=p_sale_id
  union all
  select s.sale_id,s.created_at,'sale','checkout',coalesce(s.notes,''),s.total_amount,0::numeric,null::text,coalesce(u.full_name,u.email,'Operator'),'[]'::jsonb
  from public.user_profiles u where u.tenant_id=t and u.user_id=s.created_by
  union all
  select p.payment_id,p.created_at,'payment',p.phase,concat_ws(' · ',p.wallet_name,nullif(p.reference,'')),p.amount,0::numeric,null::text,coalesce(u.full_name,u.email,'Operator'),'[]'::jsonb
  from public.sale_payments p left join app_private.tenant_actors u on u.tenant_id=t and u.user_id=p.created_by where p.tenant_id=t and p.sale_id=p_sale_id
 ), page as (select * from events order by created_at desc,id desc limit p_limit offset p_offset)
 select jsonb_build_object('expected',coalesce((select sum(expected) from obligations),0),
  'received',coalesce((select sum(quantity) from actual),0),'outstanding',greatest(0,coalesce((select sum(expected) from obligations),0)-coalesce((select sum(quantity) from actual),0)),
  'obligations',coalesce((select jsonb_agg(to_jsonb(o) order by name,item_id) from obligations o),'[]'),
  'actual',coalesce((select jsonb_agg(to_jsonb(a) order by phase,name,item_id) from actual a),'[]'),
  'event_count',(select count(*) from events),'events',coalesce((select jsonb_agg(to_jsonb(p) order by created_at desc,id desc) from page p),'[]')) into result;
 return result;
end $function$;

CREATE OR REPLACE FUNCTION public.get_sales_directory(p_filters jsonb DEFAULT '{}'::jsonb, p_offset integer DEFAULT 0, p_limit integer DEFAULT 25)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
 SET plan_cache_mode TO 'force_custom_plan'
AS $function$
declare t uuid:=app_private.require_permission('sales:view'); result jsonb; ordering text:=coalesce(p_filters->>'sort','date_desc');
 sale_filter text:=coalesce(p_filters->>'status','all'); bottles text:=coalesce(p_filters->>'bottles','all');
 from_day date:=nullif(p_filters->>'from','')::date; to_day date:=nullif(p_filters->>'to','')::date;
begin
 if p_filters is null or jsonb_typeof(p_filters)<>'object' or length(coalesce(p_filters->>'search',''))>500 or p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid sales page'; end if;
 if ordering not in ('date_desc','date_asc','amount_desc','amount_asc','due_desc','due_asc','bottles_desc','bottles_asc','customer_asc','customer_desc') or sale_filter not in ('all','unpaid','partial','paid','outstanding','cancelled') or bottles not in ('all','outstanding','partial','none_received','received') or coalesce(p_filters->>'tier','all') not in ('all','retail','wholesale') or coalesce(p_filters->>'business_category','all') not in ('all','lpg','stove') or from_day>to_day then raise exception 'Invalid sales filter'; end if;
 with headers as materialized (
  select s.sale_id,s.status,s.business_category,s.created_at,s.customer_id,s.sale_tier,s.total_amount original_total,s.additional_charges,s.total_amount+s.additional_charges total_amount,s.paid_amount,case when s.status='voided' then 0 else s.total_amount+s.additional_charges-s.paid_amount end due,(case when s.status='voided' then s.paid_amount-coalesce((select sum(amount) from public.sale_refunds where tenant_id=t and sale_id=s.sale_id),0) else 0 end) refund_due,
   c.name,c.phone,c.shop_name,
   coalesce(q.expected,0) expected,case when s.status='voided' then 0 else greatest(0,coalesce(q.expected,0)-coalesce(q.received,0)) end outstanding_bottles,coalesce(q.received,0) received_bottles
  from public.sales s join public.customers c on c.tenant_id=t and c.customer_id=s.customer_id
  left join lateral (select
   (select coalesce(sum(quantity),0) from public.sale_items where type='refill' and tenant_id=t and sale_id=s.sale_id) expected,
   (select coalesce(sum(quantity),0) from public.sale_bottle_receipt_lines where tenant_id=t and sale_id=s.sale_id) received) q on true
  where s.tenant_id=t and (coalesce(p_filters->>'business_category','all')='all' or s.business_category=p_filters->>'business_category')
   and (from_day is null or s.created_at>=from_day::timestamp at time zone 'Asia/Dhaka') and (to_day is null or s.created_at<(to_day+1)::timestamp at time zone 'Asia/Dhaka')
   and (coalesce(p_filters->>'tier','all')='all' or s.sale_tier=p_filters->>'tier')
   and app_private.finance_search(concat_ws(' ',s.sale_id,c.name,c.phone,c.shop_name,s.sale_tier,s.notes,
    (select string_agg(concat_ws(' ',i.product_name,b.brand_name,case when i.business_category='lpg' then i.size_kg||'kg' end,i.mouth_size,si.type),' ') from public.sale_items si join public.items i on i.tenant_id=t and i.item_id=si.item_id left join public.lpg_brands b on b.tenant_id=t and b.brand_id=i.brand_id where si.tenant_id=t and si.sale_id=s.sale_id)),coalesce(p_filters->>'search',''))
 ), matching as materialized (
  select * from headers where (sale_filter='all' or sale_filter='cancelled' and status='voided' or status='completed' and (sale_filter='unpaid' and paid_amount=0 and due>0 or sale_filter='partial' and paid_amount>0 and due>0 or sale_filter='paid' and due=0 or sale_filter='outstanding' and due>0))
   and (bottles='all' or status='completed' and (bottles='outstanding' and outstanding_bottles>0 or bottles='partial' and received_bottles>0 and outstanding_bottles>0 or bottles='none_received' and received_bottles=0 and outstanding_bottles>0 or bottles='received' and outstanding_bottles=0))
 ), page as (
  select * from matching order by case when ordering='date_desc' then created_at end desc,case when ordering='date_asc' then created_at end asc,
   case when ordering='amount_desc' then total_amount end desc,case when ordering='amount_asc' then total_amount end asc,
   case when ordering='due_desc' then due end desc,case when ordering='due_asc' then due end asc,case when ordering='bottles_desc' then outstanding_bottles end desc,case when ordering='bottles_asc' then outstanding_bottles end asc,case when ordering='customer_asc' then lower(case when sale_tier='wholesale' then coalesce(nullif(shop_name,''),name) else name end) end asc,case when ordering='customer_desc' then lower(case when sale_tier='wholesale' then coalesce(nullif(shop_name,''),name) else name end) end desc,sale_id desc limit p_limit offset p_offset
 ), details as (
  select p.*,coalesce((select jsonb_agg(jsonb_build_object('item_id',si.item_id,'type',si.type,'quantity',si.quantity,'name',concat_ws(' ',i.product_name,b.brand_name,case when i.business_category='lpg' then i.size_kg||'kg' end,i.mouth_size)) order by si.type,si.item_id)
   from public.sale_items si join public.items i on i.tenant_id=t and i.item_id=si.item_id left join public.lpg_brands b on b.tenant_id=t and b.brand_id=i.brand_id where si.tenant_id=t and si.sale_id=p.sale_id),'[]') items
  from page p
 ) select jsonb_build_object('total',(select count(*) from matching),'entries',coalesce((select jsonb_agg(to_jsonb(d) order by
  case when ordering='date_desc' then created_at end desc,case when ordering='date_asc' then created_at end asc,
  case when ordering='amount_desc' then total_amount end desc,case when ordering='amount_asc' then total_amount end asc,
  case when ordering='due_desc' then due end desc,case when ordering='due_asc' then due end asc,case when ordering='bottles_desc' then outstanding_bottles end desc,case when ordering='bottles_asc' then outstanding_bottles end asc,case when ordering='customer_asc' then lower(case when sale_tier='wholesale' then coalesce(nullif(shop_name,''),name) else name end) end asc,case when ordering='customer_desc' then lower(case when sale_tier='wholesale' then coalesce(nullif(shop_name,''),name) else name end) end desc,sale_id desc) from details d),'[]')) into result;
 return result;
end $function$;

CREATE OR REPLACE FUNCTION public.get_sales_overview()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_permission('sales:view'); result jsonb;
begin
 select jsonb_build_object('total',(select count(*) from public.sales where tenant_id=t),'amount',coalesce(sum(total_amount+additional_charges),0),'due',coalesce(sum(total_amount+additional_charges-paid_amount),0),
 'bottles',coalesce((select sum(greatest(0,
   (select coalesce(sum(quantity),0) from public.sale_items where type='refill' and tenant_id=t and sale_id=s.sale_id)-
   (select coalesce(sum(quantity),0) from public.sale_bottle_receipt_lines where tenant_id=t and sale_id=s.sale_id)))
   from public.sales s where tenant_id=t and status='completed'),0)) into result from public.sales where tenant_id=t and status='completed';
 return result;
end $function$;

CREATE OR REPLACE FUNCTION public.get_stock_alerts(p_only_low boolean DEFAULT true, p_search text DEFAULT ''::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_any_permission(array['inventory:view','inventory:manage']);r jsonb;
begin
 if p_offset is null or p_limit is null or p_search is null or p_only_low is null or p_offset<0 or p_limit not between 1 and 50 or length(p_search)>200 then raise exception 'Invalid stock page';end if;
 with products as materialized(
  select i.item_id,i.business_category,i.gas_quantity,i.unit_quantity,i.bottle_quantity,i.low_stock_threshold,
   coalesce(i.product_name,b.brand_name||' '||i.size_kg||' kg '||coalesce(i.mouth_size::text,'')) name
  from public.items i left join public.lpg_brands b using(tenant_id,brand_id)
  where i.tenant_id=t and (not p_only_low or i.gas_quantity+i.unit_quantity<i.low_stock_threshold)
  and (p_search='' or concat_ws(' ',i.product_name,b.brand_name,i.size_kg,i.mouth_size) ilike '%'||p_search||'%'))
 select jsonb_build_object('total',(select count(*) from products),'entries',coalesce((select jsonb_agg(p) from
  (select * from products order by name,item_id offset p_offset limit p_limit)p),'[]')) into r;return r;
end $function$;

alter function app_private.add_component_layer(public.inventory_movements,text,integer,numeric,numeric) owner to postgres;
revoke all on function app_private.add_component_layer(public.inventory_movements,text,integer,numeric,numeric) from public,anon,authenticated,service_role;
alter function app_private.update_bottle_custody(public.inventory_movements) owner to postgres;
revoke all on function app_private.update_bottle_custody(public.inventory_movements) from public,anon,authenticated,service_role;
alter function app_private.component_inventory_evidence(uuid,uuid) owner to postgres;
revoke all on function app_private.component_inventory_evidence(uuid,uuid) from public,anon,authenticated,service_role;
alter function app_private.check_purchase_bottles(uuid,jsonb) owner to postgres;
revoke all on function app_private.check_purchase_bottles(uuid,jsonb) from public,anon,authenticated,service_role;
alter function app_private.fifo_cost_movement(m inventory_movements) owner to postgres;
alter function app_private.fifo_take(t uuid, id uuid, mid uuid, part text, qty integer) owner to postgres;
alter function app_private.rebuild_fifo_set(t uuid, ids uuid[]) owner to postgres;
alter function app_private.cost_inventory_movement() owner to postgres;
alter function app_private.snapshot_inventory_components() owner to postgres;
alter function app_private.update_item_inventory() owner to postgres;
alter function app_private.action_adjust_inventory(p_payload jsonb, p_request_id uuid) owner to postgres;
alter function public.get_fifo_stock(uuid,text,text,integer) owner to postgres;
revoke all on function public.get_fifo_stock(uuid,text,text,integer) from public,anon;
grant execute on function public.get_fifo_stock(uuid,text,text,integer) to authenticated,service_role;
