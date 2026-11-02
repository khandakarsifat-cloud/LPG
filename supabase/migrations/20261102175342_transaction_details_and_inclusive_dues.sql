-- Attribution is held in the private actor registry, not the mutable membership
-- table. Expose only the fields belonging to an authorized source record.
create function public.get_sale_details(p_sale_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['sales:view','receipts:print']);result jsonb;
begin
 select jsonb_build_object(
  'sale_id',s.sale_id,'sale_tier',s.sale_tier,'status',s.status,'business_category',s.business_category,
  'created_at',s.created_at,'total_amount',s.total_amount,'additional_charges',s.additional_charges,
  'paid_amount',s.paid_amount,'subtotal',s.subtotal,'discount_amount',s.discount_amount,
  'exchange_fee',s.exchange_fee,'notes',s.notes,
  'customers',jsonb_build_object('name',c.name,'phone',c.phone,'shop_name',c.shop_name,'address',c.address,'tier',c.tier),
  'actor',case when a.user_id is not null then jsonb_build_object('full_name',a.full_name,'email',a.email) end,
  'sale_items',coalesce((select jsonb_agg(jsonb_build_object(
   'item_id',si.item_id,'quantity',si.quantity,'unit_price',si.unit_price,'line_total',si.line_total,'type',si.type,
   'items',jsonb_build_object('item_id',i.item_id,'image_url',i.image_url,'product_name',i.product_name,
    'brand_id',i.brand_id,'size_kg',i.size_kg,'mouth_size',i.mouth_size,
    'lpg_brands',case when b.brand_id is not null then jsonb_build_object('brand_name',b.brand_name) end)
   ) order by si.created_at,si.sale_item_id)
   from public.sale_items si join public.items i on i.tenant_id=si.tenant_id and i.item_id=si.item_id
   left join public.lpg_brands b on b.tenant_id=i.tenant_id and b.brand_id=i.brand_id
   where si.tenant_id=t and si.sale_id=s.sale_id),'[]'::jsonb)) into result
 from public.sales s join public.customers c on c.tenant_id=s.tenant_id and c.customer_id=s.customer_id
 left join app_private.tenant_actors a on a.tenant_id=s.tenant_id and a.user_id=s.created_by
 where s.tenant_id=t and s.sale_id=p_sale_id;
 if result is null then raise no_data_found using message='Sale not found';end if;
 return result;
end $$;

create function public.get_inventory_history(p_filters jsonb default '{}',p_offset integer default 0,p_limit integer default 10) returns jsonb
language plpgsql stable security definer set search_path='' as $$
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
    or source='purchase' and (m.reference_type in ('purchase_dispatch','purchase_receipt_refill','purchase_receipt_new','purchase_cancellation','stove_purchase_receipt','stove_purchase_cancellation') or m.movement_type in ('purchase','refill','purchase_adjustment')))
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
end $$;

alter function public.get_sale_details(uuid) owner to postgres;
alter function public.get_inventory_history(jsonb,integer,integer) owner to postgres;
revoke all on function public.get_sale_details(uuid),public.get_inventory_history(jsonb,integer,integer) from public,anon,authenticated;
grant execute on function public.get_sale_details(uuid),public.get_inventory_history(jsonb,integer,integer) to authenticated;

-- Payment/Bottle Due are inclusive; Both is their intersection, None the complement.
do $$declare definition text;before text:=
 'and (coalesce(m.ledger_balance,0)<0)=(p_filters->>''dues'' in (''payment'',''both''))
   and (b.customer_id is not null)=(p_filters->>''dues'' in (''bottle'',''both''))';
begin
 definition:=pg_get_functiondef('public.get_customer_directory(jsonb,integer,integer,uuid)'::regprocedure);
 if strpos(definition,before)=0 then raise exception 'Unexpected customer dues definition';end if;
 definition:=replace(definition,before,
 'and case p_filters->>''dues''
    when ''payment'' then coalesce(m.ledger_balance,0)<0
    when ''bottle'' then b.customer_id is not null
    when ''both'' then coalesce(m.ledger_balance,0)<0 and b.customer_id is not null
    when ''none'' then coalesce(m.ledger_balance,0)>=0 and b.customer_id is null
    else false end');
 execute definition;
end $$;
notify pgrst,'reload schema';
