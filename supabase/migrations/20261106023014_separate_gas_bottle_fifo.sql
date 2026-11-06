-- Separate immutable LPG acquisitions from their available and held positions.
-- Original position and issue IDs are retained for exact reversals and history.
create temporary table prior_fifo_positions on commit drop as select * from app_private.fifo_layers;
create temporary table prior_fifo_effects on commit drop as select * from app_private.fifo_consumptions;

alter table app_private.fifo_layers rename to fifo_positions;
create table app_private.fifo_component_layers (
  tenant_id uuid not null,
  layer_id uuid not null default gen_random_uuid(),
  item_id uuid not null,
  movement_id uuid not null,
  component text not null check(component in ('gas','bottle')),
  origin_state text not null check(origin_state in ('filled','empty') and (component='bottle' or origin_state='filled')),
  acquired_at timestamptz not null,
  quantity integer not null check(quantity>0),
  value numeric(20,2) not null check(value>=0),
  internal_value numeric(20,2) not null check(internal_value>=0),
  primary key (tenant_id,layer_id),
  unique (tenant_id,movement_id,component,origin_state),
  foreign key (tenant_id,item_id) references public.items(tenant_id,item_id),
  foreign key (tenant_id,movement_id) references public.inventory_movements(tenant_id,movement_id)
);
create index fifo_component_item on app_private.fifo_component_layers(tenant_id,item_id);

alter table app_private.fifo_positions
 add column gas_layer_id uuid,
 add column bottle_layer_id uuid,
 add foreign key (tenant_id,gas_layer_id) references app_private.fifo_component_layers(tenant_id,layer_id),
 add foreign key (tenant_id,bottle_layer_id) references app_private.fifo_component_layers(tenant_id,layer_id);
create index fifo_positions_gas_layer on app_private.fifo_positions(tenant_id,gas_layer_id) where gas_layer_id is not null;
create index fifo_positions_bottle_layer on app_private.fifo_positions(tenant_id,bottle_layer_id) where bottle_layer_id is not null;

insert into app_private.fifo_component_layers(tenant_id,item_id,movement_id,component,origin_state,acquired_at,quantity,value,internal_value)
select l.tenant_id,l.item_id,l.movement_id,'gas','filled',min(l.acquired_at),sum(l.quantity),
  sum(l.value-l.shell_value),sum(l.internal_value-l.internal_shell_value)
from prior_fifo_positions l join public.items i using(tenant_id,item_id)
where i.business_category='lpg' and l.component='filled'
group by l.tenant_id,l.item_id,l.movement_id
union all
select l.tenant_id,l.item_id,l.movement_id,'bottle',l.component,min(l.shell_acquired_at),sum(l.quantity),
  sum(l.shell_value),sum(l.internal_shell_value)
from prior_fifo_positions l join public.items i using(tenant_id,item_id)
where i.business_category='lpg' and l.shell_source_movement_id=l.movement_id
group by l.tenant_id,l.item_id,l.movement_id,l.component;

update app_private.fifo_positions p set
  gas_layer_id=(select a.layer_id from app_private.fifo_component_layers a
    where a.tenant_id=p.tenant_id and a.movement_id=p.movement_id and a.component='gas' and p.component='filled'),
  bottle_layer_id=(select a.layer_id from app_private.fifo_component_layers a
    where a.tenant_id=p.tenant_id and a.movement_id=p.shell_source_movement_id and a.component='bottle'
      and a.origin_state=case when p.shell_source_movement_id<>p.movement_id then 'empty' else p.component end)
from public.items i where i.tenant_id=p.tenant_id and i.item_id=p.item_id and i.business_category='lpg';

do $$begin
 if exists(select 1 from app_private.fifo_positions p join public.items i using(tenant_id,item_id)
   where i.business_category='lpg' and (p.bottle_layer_id is null or (p.component='filled' and p.gas_layer_id is null))) then
  raise exception 'Original Gas and Bottle acquisition links do not reconcile';
 end if;
end$$;

alter table app_private.fifo_positions
 drop constraint fifo_shell_value_valid,
 drop constraint fifo_internal_shell_valid,
 drop constraint fifo_internal_value_valid,
 drop constraint fifo_exhausted_value_zero,
 drop constraint fifo_shell_source_fk,
 drop column shell_source_movement_id,
 drop column shell_acquired_at;
update app_private.fifo_positions set
 value=value-shell_value,remaining_value=remaining_value-remaining_shell_value,
 internal_value=internal_value-internal_shell_value,remaining_internal_value=remaining_internal_value-remaining_internal_shell_value;
alter table app_private.fifo_positions rename column value to unit_value;
alter table app_private.fifo_positions rename column remaining_value to remaining_unit_value;
alter table app_private.fifo_positions rename column shell_value to bottle_value;
alter table app_private.fifo_positions rename column remaining_shell_value to remaining_bottle_value;
alter table app_private.fifo_positions rename column internal_value to internal_unit_value;
alter table app_private.fifo_positions rename column remaining_internal_value to remaining_internal_unit_value;
alter table app_private.fifo_positions rename column internal_shell_value to internal_bottle_value;
alter table app_private.fifo_positions rename column remaining_internal_shell_value to remaining_internal_bottle_value;
alter table app_private.fifo_positions add constraint fifo_position_costs check(
  remaining_unit_value between 0 and unit_value and remaining_bottle_value between 0 and bottle_value
  and remaining_internal_unit_value between 0 and internal_unit_value and remaining_internal_bottle_value between 0 and internal_bottle_value
  and (remaining>0 or remaining_unit_value+remaining_bottle_value+remaining_internal_unit_value+remaining_internal_bottle_value=0)
  and (gas_layer_id is not null)=(component='filled' and bottle_layer_id is not null)
  and (component='filled' or (gas_layer_id is null and bottle_layer_id is not null and unit_value+internal_unit_value=0))
);

create table app_private.fifo_purchase_holdings (
  tenant_id uuid not null,
  dispatch_movement_id uuid not null,
  position_id uuid not null,
  quantity integer not null check(quantity>0),
  value numeric(20,2) not null check(value>=0),
  internal_value numeric(20,2) not null check(internal_value>=0),
  settled_movement_id uuid,
  primary key (tenant_id,dispatch_movement_id,position_id),
  foreign key (tenant_id,dispatch_movement_id) references public.inventory_movements(tenant_id,movement_id),
  foreign key (tenant_id,settled_movement_id) references public.inventory_movements(tenant_id,movement_id),
  foreign key (tenant_id,position_id) references app_private.fifo_positions(tenant_id,layer_id)
);
create index fifo_holdings_position on app_private.fifo_purchase_holdings(tenant_id,position_id);
create index fifo_holdings_settlement on app_private.fifo_purchase_holdings(tenant_id,settled_movement_id)
  where settled_movement_id is not null;

insert into app_private.fifo_purchase_holdings(tenant_id,dispatch_movement_id,position_id,quantity,value,internal_value,settled_movement_id)
select x.tenant_id,x.movement_id,x.layer_id,x.quantity,x.value,x.internal_value,settled.movement_id
from prior_fifo_effects x join public.inventory_movements d using(tenant_id,movement_id)
left join public.inventory_movements settled on settled.tenant_id=d.tenant_id and settled.item_id=d.item_id
 and settled.reference_id=d.reference_id and settled.reference_type in ('purchase_receipt','purchase_cancellation')
where d.reference_type='purchase_dispatch';
delete from app_private.fifo_consumptions x using public.inventory_movements m
where m.tenant_id=x.tenant_id and m.movement_id=x.movement_id and m.reference_type in ('purchase_dispatch','purchase_cancellation');

alter table app_private.fifo_component_layers owner to postgres;
alter table app_private.fifo_purchase_holdings owner to postgres;
alter table app_private.fifo_component_layers enable row level security;
alter table app_private.fifo_purchase_holdings enable row level security;
revoke all on app_private.fifo_component_layers,app_private.fifo_purchase_holdings from public,anon,authenticated,service_role;
create trigger a_business_deletion_guard before insert or update or delete on app_private.fifo_component_layers
 for each row execute function app_private.guard_business_deletion();
create trigger a_business_deletion_guard before insert or update or delete on app_private.fifo_purchase_holdings
 for each row execute function app_private.guard_business_deletion();

-- Read projections provide combined values to existing costing reports and
-- reconcile the effects of custody without recording a sale or another acquisition.
create view app_private.fifo_layers as
select p.tenant_id,p.item_id,p.layer_id,p.movement_id,p.component,p.acquired_at,p.acquired_order,p.quantity,p.remaining,
  (p.unit_value+p.bottle_value)::numeric(20,2) value,
  (p.remaining_unit_value+p.remaining_bottle_value)::numeric(20,2) remaining_value,
  p.bottle_value shell_value,p.remaining_bottle_value remaining_shell_value,
  (p.internal_unit_value+p.internal_bottle_value)::numeric(20,2) internal_value,
  (p.remaining_internal_unit_value+p.remaining_internal_bottle_value)::numeric(20,2) remaining_internal_value,
  p.slice_no,coalesce(b.movement_id,p.movement_id) shell_source_movement_id,
  coalesce(b.acquired_at,p.acquired_at) shell_acquired_at,
  p.internal_bottle_value internal_shell_value,p.remaining_internal_bottle_value remaining_internal_shell_value
from app_private.fifo_positions p
left join app_private.fifo_component_layers b on b.tenant_id=p.tenant_id and b.layer_id=p.bottle_layer_id;
create view app_private.fifo_position_effects as
select tenant_id,movement_id,layer_id,quantity,value,shell_value,internal_value,internal_shell_value from app_private.fifo_consumptions
union all
select tenant_id,dispatch_movement_id,position_id,quantity,value,value,internal_value,internal_value
from app_private.fifo_purchase_holdings
union all
select h.tenant_id,h.settled_movement_id,h.position_id,-h.quantity,-h.value,-h.value,-h.internal_value,-h.internal_value
from app_private.fifo_purchase_holdings h join public.inventory_movements m
 on m.tenant_id=h.tenant_id and m.movement_id=h.settled_movement_id and m.reference_type='purchase_cancellation';
alter view app_private.fifo_layers owner to postgres;
alter view app_private.fifo_position_effects owner to postgres;
revoke all on app_private.fifo_layers,app_private.fifo_position_effects from public,anon,authenticated,service_role;

do $$begin
 if exists((select * from prior_fifo_positions except select * from app_private.fifo_layers)
   union all (select * from app_private.fifo_layers except select * from prior_fifo_positions))
 or exists((select * from prior_fifo_effects except select * from app_private.fifo_position_effects)
   union all (select * from app_private.fifo_position_effects except select * from prior_fifo_effects)) then
  raise exception 'Separated component FIFO does not reproduce original position and movement evidence';
 end if;
end$$;


-- Independent acquisition rollup. Fulfilment moves availability between empty,
-- held and filled positions while the original Bottle acquisition remains stable.
create function app_private.fifo_components_consistent(t uuid, id uuid)
returns boolean language sql stable set search_path='' as $$
 with positions as materialized (
   select * from app_private.fifo_positions where tenant_id=t and item_id=id
 ), pieces as (
   select p.gas_layer_id layer_id,p.remaining quantity,p.remaining_unit_value value,p.remaining_internal_unit_value internal_value
   from positions p where p.gas_layer_id is not null
   union all
   select p.bottle_layer_id,p.remaining,p.remaining_bottle_value,p.remaining_internal_bottle_value
   from positions p where p.bottle_layer_id is not null
   union all
   select p.bottle_layer_id,h.quantity,h.value,h.internal_value
   from positions p join app_private.fifo_purchase_holdings h on h.tenant_id=t and h.position_id=p.layer_id
   where h.settled_movement_id is null
   union all
   select p.gas_layer_id,x.quantity,x.value-x.shell_value,x.internal_value-x.internal_shell_value
   from positions p join app_private.fifo_consumptions x using(tenant_id,layer_id)
   where p.gas_layer_id is not null
   union all
   select p.bottle_layer_id,x.quantity,x.shell_value,x.internal_shell_value
   from positions p join app_private.fifo_consumptions x using(tenant_id,layer_id)
   where p.bottle_layer_id is not null
 ), balances as (
   select layer_id,sum(quantity) quantity,sum(value) value,sum(internal_value) internal_value
   from pieces group by layer_id
 )
 select not exists(
   select 1 from app_private.fifo_component_layers a left join balances b using(layer_id)
   where a.tenant_id=t and a.item_id=id
     and row(a.quantity,a.value,a.internal_value) is distinct from row(b.quantity,b.value,b.internal_value)
 );
$$;
alter function app_private.fifo_components_consistent(uuid,uuid) owner to postgres;
revoke all on function app_private.fifo_components_consistent(uuid,uuid) from public,anon,authenticated,service_role;

do $$begin
 if exists(select 1 from public.items where business_category='lpg' and not app_private.fifo_components_consistent(tenant_id,item_id)) then
  raise exception 'Component acquisitions do not reconcile to available stock, purchase custody and original issues';
 end if;
end$$;

CREATE OR REPLACE FUNCTION app_private.fifo_component_layer(t uuid, id uuid, mid uuid, part text, at_time timestamp with time zone, qty integer, cost numeric, shell numeric, internal_cost numeric, internal_shell numeric, slice integer DEFAULT 0, shell_source uuid DEFAULT NULL::uuid, shell_time timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare gas uuid; bottle uuid; category text;
begin
 if qty<=0 then return; end if;
 if cost<0 or shell<0 or shell>cost or internal_cost<0 or internal_shell<0 or internal_shell>internal_cost then
  raise exception 'Invalid component acquisition evidence';
 end if;
 select business_category into strict category from public.items where tenant_id=t and item_id=id;
 if category='lpg' then
  if part='filled' then
   select layer_id into gas from app_private.fifo_component_layers
   where tenant_id=t and movement_id=mid and component='gas' and origin_state='filled';
   if gas is null then
    insert into app_private.fifo_component_layers
      (tenant_id,item_id,movement_id,component,origin_state,acquired_at,quantity,value,internal_value)
    values(t,id,mid,'gas','filled',at_time,qty,cost-shell,internal_cost-internal_shell)
    returning layer_id into gas;
   end if;
  end if;
  if shell_source is null then
   insert into app_private.fifo_component_layers
     (tenant_id,item_id,movement_id,component,origin_state,acquired_at,quantity,value,internal_value)
   values(t,id,mid,'bottle',part,at_time,qty,shell,internal_shell)
   returning layer_id into bottle;
  else
   select layer_id into strict bottle from app_private.fifo_component_layers
   where tenant_id=t and item_id=id and movement_id=shell_source and component='bottle'
     and origin_state='empty' and acquired_at=shell_time;
  end if;
 end if;
 insert into app_private.fifo_positions
   (tenant_id,item_id,movement_id,component,acquired_at,acquired_order,quantity,remaining,
    unit_value,remaining_unit_value,bottle_value,remaining_bottle_value,
    internal_unit_value,remaining_internal_unit_value,internal_bottle_value,remaining_internal_bottle_value,
    slice_no,gas_layer_id,bottle_layer_id)
 values(t,id,mid,part,at_time,(select movement_no from public.inventory_movements where tenant_id=t and movement_id=mid),qty,qty,
    cost-shell,cost-shell,shell,shell,internal_cost-internal_shell,internal_cost-internal_shell,internal_shell,internal_shell,slice,gas,bottle);
end
$function$;

CREATE OR REPLACE FUNCTION app_private.fifo_take(t uuid, id uuid, mid uuid, part text, qty integer)
 RETURNS numeric
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
 r record; needed integer:=qty; taken integer; v numeric; shell numeric; iv numeric; isv numeric; total numeric:=0;
 dispatched boolean:=exists(select 1 from public.inventory_movements
   where tenant_id=t and movement_id=mid and reference_type='purchase_dispatch');
begin
 if dispatched and part<>'empty' then raise exception 'Only empty bottles may be dispatched'; end if;
 for r in select * from app_private.fifo_positions
  where tenant_id=t and item_id=id and component=part and remaining>0
  order by acquired_at,acquired_order,slice_no,layer_id for update loop
  exit when needed=0;
  taken:=least(needed,r.remaining);
  -- Round the combined slice and its Bottle cost independently, exactly as before.
  v:=round((r.remaining_unit_value+r.remaining_bottle_value)*taken/r.remaining,2);
  shell:=round(r.remaining_bottle_value*taken/r.remaining,2);
  iv:=round((r.remaining_internal_unit_value+r.remaining_internal_bottle_value)*taken/r.remaining,2);
  isv:=round(r.remaining_internal_bottle_value*taken/r.remaining,2);
  update app_private.fifo_positions set
   remaining=remaining-taken,
   remaining_unit_value=remaining_unit_value-v+shell,
   remaining_bottle_value=remaining_bottle_value-shell,
   remaining_internal_unit_value=remaining_internal_unit_value-iv+isv,
   remaining_internal_bottle_value=remaining_internal_bottle_value-isv
  where tenant_id=t and layer_id=r.layer_id;
  if dispatched then
   insert into app_private.fifo_purchase_holdings(tenant_id,dispatch_movement_id,position_id,quantity,value,internal_value)
   values(t,mid,r.layer_id,taken,v,iv);
  else
   insert into app_private.fifo_consumptions(tenant_id,movement_id,layer_id,quantity,value,shell_value,internal_value,internal_shell_value)
   values(t,mid,r.layer_id,taken,v,shell,iv,isv);
  end if;
  total:=total+v;
  needed:=needed-taken;
 end loop;
 if needed<>0 then raise exception 'Insufficient FIFO % stock for product',part;end if;
 return total;
end
$function$;

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
 if lines is null then lines:=jsonb_build_array(app_private.accounting_line(account,fc+ec,cat,m.item_id),app_private.accounting_line(counter,-fc-ec,cat,m.reference_id));end if;
 perform app_private.sync_journal(m.tenant_id,'inventory',m.movement_id,d,coalesce(m.notes,'FIFO component carrying cost'),lines,counter='opening_equity');
 perform app_private.sync_internal_fifo(m);
end$function$;

CREATE OR REPLACE FUNCTION app_private.rebuild_fifo_set(t uuid, ids uuid[])
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$declare m public.inventory_movements;r record;begin
 -- Callers already hold item locks in UUID order. Never acquire a purchase or
 -- snapshot lock here: journal invalidation is always the final lock boundary.
 perform 1 from public.items where tenant_id=t and item_id=any(ids) order by item_id for update;
 delete from app_private.fifo_purchase_holdings where tenant_id=t and position_id in(
   select layer_id from app_private.fifo_positions where tenant_id=t and item_id=any(ids));
 delete from app_private.fifo_consumptions where tenant_id=t and layer_id in(select layer_id from app_private.fifo_positions where tenant_id=t and item_id=any(ids));
 delete from app_private.fifo_positions where tenant_id=t and item_id=any(ids);
 delete from app_private.fifo_component_layers where tenant_id=t and item_id=any(ids);
 update public.inventory_costs set filled_quantity=0,empty_quantity=0,filled_value=0,empty_value=0 where tenant_id=t and item_id=any(ids);
 for m in select im.* from public.inventory_movements im where im.tenant_id=t and im.item_id=any(ids) order by im.created_at,case when im.reference_type='sale' then (select min(x.movement_no) from public.inventory_movements x where x.tenant_id=t and x.reference_type='sale' and x.reference_id=im.reference_id) else im.movement_no end,case when im.reference_type='sale' and im.filled_quantity_change<0 then 0 else 1 end,im.movement_no loop perform app_private.fifo_cost_movement(m);end loop;
 for r in select s.sale_id,(s.created_at at time zone 'Asia/Dhaka')::date d from public.sale_reversals s where s.tenant_id=t and exists(select 1 from public.inventory_movements im where im.tenant_id=t and im.reference_id=s.sale_id and im.reference_type='sale' and im.item_id=any(ids)) loop perform app_private.sync_sale_bottle_reversal(t,r.sale_id,r.d);end loop;
end $function$;

CREATE OR REPLACE FUNCTION app_private.sync_internal_fifo(m public.inventory_movements)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$declare
 a numeric:=0;c numeric:=0;cat text;account text;counter text;lines jsonb;begin
 select coalesce(sum(internal_value),0) into a from app_private.fifo_layers where tenant_id=m.tenant_id and movement_id=m.movement_id;
 select coalesce(sum(internal_value),0) into c from app_private.fifo_position_effects where tenant_id=m.tenant_id and movement_id=m.movement_id;
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
 expected:=expected||jsonb_build_object('inventory_control',coalesce((select sum(c.filled_value+c.empty_value) from public.inventory_costs c join public.items i using(tenant_id,item_id) where c.tenant_id=t and i.business_category=(select business_category from public.items where tenant_id=t and item_id=id)),0));
 observed:=observed||jsonb_build_object('full_inventory_control',coalesce((select sum(l.amount) from public.accounting_lines l where l.tenant_id=t and l.account=case when (select business_category from public.items where tenant_id=t and item_id=id)='stove' then 'inventory_stove' else 'inventory_lpg' end),0));
 expected:=expected||jsonb_build_object('full_inventory_control',coalesce((select sum(c.filled_value+c.empty_value+coalesce((select sum(l.remaining_internal_value) from app_private.fifo_layers l where l.tenant_id=c.tenant_id and l.item_id=c.item_id),0)) from public.inventory_costs c join public.items i using(tenant_id,item_id) where c.tenant_id=t and i.business_category=(select business_category from public.items where tenant_id=t and item_id=id)),0));
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
  select jsonb_build_object('recognized_invoice',case when status in ('in_transit','received') then payable_amount else 0 end) into expected from public.purchases where tenant_id=t and purchase_id=id;
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
