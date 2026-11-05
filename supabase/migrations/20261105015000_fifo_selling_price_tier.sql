-- Resolve current selling references exactly like POS: requested tier, then retail.
create or replace function public.get_lpg_fifo_stock(p_item_id uuid,p_tier text default 'retail',p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('finance:stock');result jsonb;begin
 if p_tier is null or p_tier not in ('retail','wholesale') or p_offset is null or p_offset<0 or p_offset>1000000 then raise exception 'Invalid FIFO filters';end if;
 if not exists(select 1 from public.items where tenant_id=t and item_id=p_item_id and business_category='lpg') then raise insufficient_privilege using message='Product unavailable';end if;
 with prices as materialized(select distinct on (price_type) price_type,price,effective_from,customer_tier from public.price_books
 where tenant_id=t and item_id=p_item_id and customer_tier in (p_tier,'retail') and effective_from<=now() and (effective_to is null or effective_to>now()) order by price_type,case when customer_tier=p_tier then 0 else 1 end,effective_from desc),
 layers as materialized(select l.*,m.reference_type,m.reference_id,
  (l.remaining_value-l.remaining_shell_value+l.remaining_internal_value-l.remaining_internal_shell_value) gas_value,
  l.remaining_shell_value+l.remaining_internal_shell_value bottle_value,
  (l.remaining_value+l.remaining_internal_value) carrying_value,
  coalesce(c.estimated,true) estimated
  from app_private.fifo_layers l join public.inventory_movements m using(tenant_id,movement_id)
  left join public.inventory_costs c on c.tenant_id=l.tenant_id and c.item_id=l.item_id
  where l.tenant_id=t and l.item_id=p_item_id and l.remaining>0),
 page as(select * from layers order by component,acquired_at,acquired_order,slice_no,layer_id limit 25 offset p_offset)
 select jsonb_build_object('generated_at',now(),'tier',p_tier,'total',(select count(*) from layers),
 'prices',coalesce((select jsonb_agg(to_jsonb(p) order by price_type) from prices p),'[]'),
 'summary',(select jsonb_build_object('filled',coalesce(sum(remaining) filter(where component='filled'),0),'empty',coalesce(sum(remaining) filter(where component='empty'),0),
 'gas_value',coalesce(sum(gas_value),0),'bottle_value',coalesce(sum(bottle_value),0),'carrying_value',coalesce(sum(carrying_value),0)) from layers),
 'layers',coalesce((select jsonb_agg(jsonb_build_object('layer_id',l.layer_id,'state',l.component,'acquired_at',l.acquired_at,'bottle_acquired_at',l.shell_acquired_at,
 'source_kind',l.reference_type,'source_id',l.reference_id,'movement_id',l.movement_id,'bottle_source_movement_id',l.shell_source_movement_id,'remaining',l.remaining,'estimated',l.estimated,
 'gas_value',l.gas_value,'bottle_value',l.bottle_value,'carrying_value',l.carrying_value,
 'gas_unit_cost',case when l.component='filled' and not l.estimated then l.gas_value/l.remaining end,
 'bottle_unit_cost',case when not l.estimated then l.bottle_value/l.remaining end,
 'refill_margin',case when l.component='filled' and not l.estimated then (select price from prices where price_type='refill')-l.gas_value/l.remaining end,
 'package_margin',case when l.component='filled' and not l.estimated then (select price from prices where price_type='package')-l.carrying_value/l.remaining end,
 'bottle_contribution_margin',case when not l.estimated then (select price from prices where price_type='package')-(select price from prices where price_type='refill')-l.bottle_value/l.remaining end)
 order by l.component,l.acquired_at,l.acquired_order,l.slice_no,l.layer_id) from page l),'[]')) into result;
 return result;end$$;
notify pgrst,'reload schema';
