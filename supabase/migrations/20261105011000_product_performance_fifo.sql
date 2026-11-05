-- Read-only management reports. Historical FIFO values and current price references stay separate.
create function public.get_lpg_performance(p_from date default null,p_to date default null,p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('finance:stock');result jsonb;begin
 if p_offset is null or p_offset<0 or p_offset>1000000 or (p_from is not null and not isfinite(p_from)) or (p_to is not null and not isfinite(p_to)) or p_from>p_to then raise exception 'Invalid reporting range';end if;
 with sold as materialized(
  select si.item_id,si.type,sum(si.quantity) qty from public.sale_items si join public.sales s using(tenant_id,sale_id)
  where si.tenant_id=t and s.status='completed' and si.type in ('refill','package')
  and (p_from is null or s.created_at >= p_from::timestamp at time zone 'Asia/Dhaka')
  and (p_to is null or s.created_at < (p_to+1)::timestamp at time zone 'Asia/Dhaka') group by si.item_id,si.type
 ), bought as materialized(
  select pi.item_id,sum(pi.quantity-pi.bottle_quantity) refill,sum(pi.bottle_quantity) package
  from public.purchase_items pi join public.purchases p using(tenant_id,purchase_id)
  where pi.tenant_id=t and p.status='received'
  and (p_from is null or p.received_at >= p_from::timestamp at time zone 'Asia/Dhaka')
  and (p_to is null or p.received_at < (p_to+1)::timestamp at time zone 'Asia/Dhaka') group by pi.item_id
 ), groups as materialized(
  select i.brand_id,b.brand_name,i.size_kg,count(*) variants,
  coalesce(sum((select qty from sold s where s.item_id=i.item_id and s.type='refill')),0) sold_refill,
  coalesce(sum((select qty from sold s where s.item_id=i.item_id and s.type='package')),0) sold_package,
  coalesce(sum(p.refill),0) bought_refill,coalesce(sum(p.package),0) bought_package
  from public.items i join public.lpg_brands b using(tenant_id,brand_id) left join bought p using(item_id)
  where i.tenant_id=t and i.business_category='lpg' group by i.brand_id,b.brand_name,i.size_kg
 ), page as(select * from groups order by brand_name,brand_id,size_kg limit 25 offset p_offset)
 select jsonb_build_object('total',(select count(*) from groups),'generated_at',now(),
 'rows',coalesce((select jsonb_agg(to_jsonb(p) order by brand_name,brand_id,size_kg) from page p),'[]'),
 'totals',(select jsonb_build_object('sold_refill',coalesce(sum(sold_refill),0),'sold_package',coalesce(sum(sold_package),0),'bought_refill',coalesce(sum(bought_refill),0),'bought_package',coalesce(sum(bought_package),0)) from groups)) into result;
 return result;end$$;

create function public.get_lpg_fifo_products(p_search text default '',p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('finance:stock');begin
 if p_offset is null or p_offset<0 or p_offset>1000000 or p_search is null or length(p_search)>200 then raise exception 'Invalid product search';end if;
 return (with matching as materialized(select i.item_id,b.brand_name,i.size_kg,i.mouth_size from public.items i join public.lpg_brands b using(tenant_id,brand_id)
 where i.tenant_id=t and i.business_category='lpg' and position(lower(trim(p_search)) in lower(b.brand_name||' '||i.size_kg||' kg '||i.mouth_size))>0),
 page as(select * from matching order by brand_name,size_kg,mouth_size,item_id limit 25 offset p_offset)
 select jsonb_build_object('total',(select count(*) from matching),'entries',coalesce((select jsonb_agg(to_jsonb(p) order by brand_name,size_kg,mouth_size,item_id) from page p),'[]')));
end$$;

create function public.get_lpg_fifo_stock(p_item_id uuid,p_tier text default 'retail',p_offset integer default 0)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('finance:stock');result jsonb;begin
 if p_tier is null or p_tier not in ('retail','wholesale') or p_offset is null or p_offset<0 or p_offset>1000000 then raise exception 'Invalid FIFO filters';end if;
 if not exists(select 1 from public.items where tenant_id=t and item_id=p_item_id and business_category='lpg') then raise insufficient_privilege using message='Product unavailable';end if;
 with prices as materialized(select distinct on (price_type) price_type,price,effective_from from public.price_books
 where tenant_id=t and item_id=p_item_id and customer_tier=p_tier and effective_from<=now() and (effective_to is null or effective_to>now()) order by price_type,effective_from desc),
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
revoke all on function public.get_lpg_performance(date,date,integer),public.get_lpg_fifo_products(text,integer),public.get_lpg_fifo_stock(uuid,text,integer) from public,anon;
grant execute on function public.get_lpg_performance(date,date,integer),public.get_lpg_fifo_products(text,integer),public.get_lpg_fifo_stock(uuid,text,integer) to authenticated;
notify pgrst,'reload schema';
