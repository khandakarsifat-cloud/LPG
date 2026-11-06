-- One physical-stock report. Only adjacent equal-cost customer empty receipts
-- are combined for display. Purchases and linked owned shells remain distinct.
create function public.get_fifo_stock(p_item_id uuid,p_tier text default 'retail',p_state text default 'all',p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('finance:stock');cat text;begin
 if p_tier is null or p_tier not in ('retail','wholesale') or p_state is null or p_state not in ('all','filled','empty') or p_offset is null or p_offset<0 or p_offset>1000000 then raise exception 'Invalid FIFO filters';end if;
 select business_category into cat from public.items where tenant_id=t and item_id=p_item_id;
 if cat is null or cat not in ('lpg','stove') then raise insufficient_privilege using message='Product unavailable';end if;
 return (with prices as materialized(
 select distinct on(price_type) price_type,price,effective_from,customer_tier from public.price_books
 where tenant_id=t and item_id=p_item_id and customer_tier in(p_tier,'retail') and effective_from<=now() and (effective_to is null or effective_to>now())
 order by price_type,case when customer_tier=p_tier then 0 else 1 end,effective_from desc
 ), basis as materialized(
 select l.*,m.reference_type,m.reference_id,
 l.remaining_value-l.remaining_shell_value+l.remaining_internal_value-l.remaining_internal_shell_value gas_value,
 l.remaining_shell_value+l.remaining_internal_shell_value bottle_value,
 l.remaining_value+l.remaining_internal_value carrying_value,
 coalesce(c.estimated,true) estimated,
 l.component='empty' and m.reference_type='sale' mergeable,
 case when cat='stove' then null when l.component='empty' then 'received_empty'
 when l.shell_source_movement_id=l.movement_id and m.reference_type='purchase_receipt' then 'purchased'
 when m.reference_type='purchase_receipt' then 'owned_reused' else 'recorded_stock' end bottle_origin
 from app_private.fifo_layers l join public.inventory_movements m using(tenant_id,movement_id)
 left join public.inventory_costs c on c.tenant_id=l.tenant_id and c.item_id=l.item_id
 where l.tenant_id=t and l.item_id=p_item_id and l.remaining>0 and (p_state='all' or l.component=p_state)
 ), previous as(
 select *,lag(mergeable) over w prior_mergeable,lag(bottle_value) over w prior_value,lag(remaining) over w prior_quantity,lag(estimated) over w prior_estimated
 from basis window w as(order by component,acquired_at,acquired_order,slice_no,layer_id)
 ), runs as(
 select *,sum(case when mergeable and prior_mergeable and bottle_value*prior_quantity=prior_value*remaining and estimated is not distinct from prior_estimated then 0 else 1 end)
 over(order by component,acquired_at,acquired_order,slice_no,layer_id) group_id from previous
 ), groups as materialized(
 select group_id,min(component) state,min(acquired_at) acquired_at,max(acquired_at) last_acquired_at,min(shell_acquired_at) bottle_acquired_at,
 min(reference_type) source_kind,case when count(*)=1 then min(reference_id::text)::uuid end source_id,
 min(bottle_origin) bottle_origin,count(*) source_count,sum(remaining) remaining,bool_or(estimated) estimated,
 sum(gas_value) gas_value,sum(bottle_value) bottle_value,sum(carrying_value) carrying_value
 from runs group by group_id
 ), page as(select * from groups order by group_id limit 25 offset p_offset)
 select jsonb_build_object('business',cat,'generated_at',now(),'tier',p_tier,'total',(select count(*) from groups),
 'prices',coalesce((select jsonb_agg(to_jsonb(p) order by price_type) from prices p),'[]'),
 'summary',(select jsonb_build_object('filled',coalesce(sum(remaining) filter(where component='filled'),0),'empty',coalesce(sum(remaining) filter(where component='empty'),0),
 'gas_value',coalesce(sum(gas_value),0),'bottle_value',coalesce(sum(bottle_value),0),'carrying_value',coalesce(sum(carrying_value),0)) from basis),
 'layers',coalesce((select jsonb_agg(to_jsonb(l)||jsonb_build_object(
 'gas_unit_cost',case when l.state='filled' and not l.estimated then l.gas_value/l.remaining end,
 'bottle_unit_cost',case when cat='lpg' and not l.estimated then l.bottle_value/l.remaining end,
 'refill_margin',case when l.state='filled' and cat='lpg' and not l.estimated then (select price from prices where price_type='refill')-l.gas_value/l.remaining end,
 'package_margin',case when l.state='filled' and not l.estimated then (select price from prices where price_type='package')-l.carrying_value/l.remaining end,
 'bottle_contribution_margin',case when cat='lpg' and not l.estimated then (select price from prices where price_type='package')-(select price from prices where price_type='refill')-l.bottle_value/l.remaining end
 ) order by group_id) from page l),'[]')));
end$$;
revoke all on function public.get_fifo_stock(uuid,text,text,integer) from public,anon;
grant execute on function public.get_fifo_stock(uuid,text,text,integer) to authenticated;
drop function public.get_fifo_cost_groups(uuid,text,text,integer);
