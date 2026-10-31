-- Complete shared catalog search and preserve access to cancelled sales / refunds.
CREATE OR REPLACE FUNCTION public.get_sales_directory(p_filters jsonb DEFAULT '{}'::jsonb, p_offset integer DEFAULT 0, p_limit integer DEFAULT 25) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    SET plan_cache_mode TO 'force_custom_plan'
    AS $$
declare t uuid:=app_private.require_permission('sales:view'); result jsonb; ordering text:=coalesce(p_filters->>'sort','date_desc');
 payment text:=coalesce(p_filters->>'payment','all'); bottles text:=coalesce(p_filters->>'bottles','all');
 from_day date:=nullif(p_filters->>'from','')::date; to_day date:=nullif(p_filters->>'to','')::date;
begin
 if p_filters is null or jsonb_typeof(p_filters)<>'object' or length(coalesce(p_filters->>'search',''))>500 or p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid sales page'; end if;
 if ordering not in ('date_desc','date_asc','amount_desc','amount_asc','due_desc','bottles_desc') or payment not in ('all','unpaid','partial','paid','outstanding') or bottles not in ('all','outstanding','partial','none_received','received') or coalesce(p_filters->>'tier','all') not in ('all','retail','wholesale') or from_day>to_day then raise exception 'Invalid sales filter'; end if;
 with headers as materialized (
  select s.sale_id,s.status,s.business_category,s.created_at,s.customer_id,s.sale_tier,s.total_amount original_total,s.additional_charges,s.total_amount+s.additional_charges total_amount,s.paid_amount,case when s.status='voided' then 0 else s.total_amount+s.additional_charges-s.paid_amount end due,(case when s.status='voided' then s.paid_amount-coalesce((select sum(amount) from public.sale_refunds where tenant_id=t and sale_id=s.sale_id),0) else 0 end) refund_due,
   c.name,c.phone,c.shop_name,
   coalesce(q.expected,0) expected,case when s.status='voided' then 0 else greatest(0,coalesce(q.expected,0)-coalesce(q.received,0)) end outstanding_bottles,coalesce(q.received,0) received_bottles
  from public.sales s join public.customers c on c.tenant_id=t and c.customer_id=s.customer_id
  left join lateral (select
   (select coalesce(sum(quantity),0) from public.sale_items where type='empty_return' and tenant_id=t and sale_id=s.sale_id) expected,
   (select coalesce(sum(quantity),0) from public.sale_bottle_receipt_lines where tenant_id=t and sale_id=s.sale_id) received) q on true
  where s.tenant_id=t and (coalesce(p_filters->>'status','completed')='all' or s.status=coalesce(p_filters->>'status','completed')::public.sale_status)
   and (from_day is null or s.created_at>=from_day::timestamp at time zone 'Asia/Dhaka') and (to_day is null or s.created_at<(to_day+1)::timestamp at time zone 'Asia/Dhaka')
   and (coalesce(p_filters->>'tier','all')='all' or s.sale_tier=p_filters->>'tier')
   and app_private.finance_search(concat_ws(' ',s.sale_id,c.name,c.phone,c.shop_name,s.sale_tier,s.notes,
    (select string_agg(concat_ws(' ',i.product_name,b.brand_name,i.size_kg||'kg',i.mouth_size,si.type),' ') from public.sale_items si join public.items i on i.tenant_id=t and i.item_id=si.item_id left join public.lpg_brands b on b.tenant_id=t and b.brand_id=i.brand_id where si.tenant_id=t and si.sale_id=s.sale_id)),coalesce(p_filters->>'search',''))
 ), matching as materialized (
  select * from headers where (payment='all' or payment='unpaid' and paid_amount=0 and due>0 or payment='partial' and paid_amount>0 and due>0 or payment='paid' and due=0 or payment='outstanding' and due>0)
   and (bottles='all' or bottles='outstanding' and outstanding_bottles>0 or bottles='partial' and received_bottles>0 and outstanding_bottles>0 or bottles='none_received' and received_bottles=0 and outstanding_bottles>0 or bottles='received' and outstanding_bottles=0)
 ), page as (
  select * from matching order by case when ordering='date_desc' then created_at end desc,case when ordering='date_asc' then created_at end asc,
   case when ordering='amount_desc' then total_amount end desc,case when ordering='amount_asc' then total_amount end asc,
   case when ordering='due_desc' then due end desc,case when ordering='bottles_desc' then outstanding_bottles end desc,sale_id desc limit p_limit offset p_offset
 ), details as (
  select p.*,coalesce((select jsonb_agg(jsonb_build_object('item_id',si.item_id,'type',si.type,'quantity',si.quantity,'name',concat_ws(' ',i.product_name,b.brand_name,i.size_kg||'kg',i.mouth_size)) order by si.type,si.item_id)
   from public.sale_items si join public.items i on i.tenant_id=t and i.item_id=si.item_id left join public.lpg_brands b on b.tenant_id=t and b.brand_id=i.brand_id where si.tenant_id=t and si.sale_id=p.sale_id),'[]') items
  from page p
 ) select jsonb_build_object('total',(select count(*) from matching),'entries',coalesce((select jsonb_agg(to_jsonb(d) order by
  case when ordering='date_desc' then created_at end desc,case when ordering='date_asc' then created_at end asc,
  case when ordering='amount_desc' then total_amount end desc,case when ordering='amount_asc' then total_amount end asc,
  case when ordering='due_desc' then due end desc,case when ordering='bottles_desc' then outstanding_bottles end desc,sale_id desc) from details d),'[]')) into result;
 return result;
end $$;
CREATE OR REPLACE FUNCTION public.get_customer_filter_products() RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare t uuid:=app_private.require_any_permission(array['customers:view','customers:manage']);
begin
  return jsonb_build_object('items',coalesce((select jsonb_agg(jsonb_build_object('item_id',i.item_id,'brand_id',i.brand_id,'product_name',i.product_name,'size_kg',i.size_kg,'mouth_size',i.mouth_size,'lpg_brands',case when b.brand_id is null then null else jsonb_build_object('brand_id',b.brand_id,'brand_name',b.brand_name) end)) from public.items i left join public.lpg_brands b on b.tenant_id=i.tenant_id and b.brand_id=i.brand_id where i.tenant_id=t),'[]'::jsonb),
    'brands',coalesce((select jsonb_agg(jsonb_build_object('brand_id',b.brand_id,'brand_name',b.brand_name) order by b.display_order,b.brand_name,b.brand_id) from public.lpg_brands b where b.tenant_id=t),'[]'::jsonb));
end $$;
CREATE OR REPLACE FUNCTION public.get_customer_transactions(p_customer_id uuid, p_filters jsonb DEFAULT '{}'::jsonb, p_offset integer DEFAULT 0, p_limit integer DEFAULT 4) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare t uuid:=app_private.require_any_permission(array['customers:view','customers:manage']); ids uuid[]; result jsonb;
begin
  perform app_private.require_any_permission(array['sales:view','receipts:print','dashboard:view']);
  perform app_private.validate_customer_filters(p_filters);
  if p_offset is null or p_limit is null or p_offset<0 or p_offset>1000000 or p_limit not between 1 and 100 then raise exception 'Invalid transaction page'; end if;
  if not exists(select 1 from public.customers where tenant_id=t and customer_id=p_customer_id) then raise exception 'Customer not found'; end if;
  if jsonb_typeof(p_filters->'item_ids')='array' then select coalesce(array_agg(value::uuid),'{}'::uuid[]) into ids from jsonb_array_elements_text(p_filters->'item_ids'); end if;
  -- Count/search headers first. Aggregate line quantities only for this page.
  with matching as materialized (
    select s.customer_id,s.sale_id,s.created_at,s.sale_tier,s.total_amount+s.additional_charges total_amount,s.total_amount original_total,s.additional_charges from public.sales s
    where s.tenant_id=t and s.customer_id=p_customer_id and s.status='completed'
      and (nullif(p_filters->>'from','') is null or s.created_at >= (nullif(p_filters->>'from','')::date::timestamp at time zone 'Asia/Dhaka'))
      and (nullif(p_filters->>'to','') is null or s.created_at < ((nullif(p_filters->>'to','')::date+1)::timestamp at time zone 'Asia/Dhaka'))
      and (ids is null or exists(select 1 from public.sale_items si where si.tenant_id=t and si.sale_id=s.sale_id and si.type in ('refill','package') and si.item_id=any(ids)))
      and (coalesce(p_filters->>'search','')='' or s.sale_id::text ilike '%'||(p_filters->>'search')||'%' or exists(
        select 1 from public.sale_items si join public.items i on i.tenant_id=si.tenant_id and i.item_id=si.item_id
        left join public.lpg_brands b on b.tenant_id=i.tenant_id and b.brand_id=i.brand_id
        where si.tenant_id=t and si.sale_id=s.sale_id and concat_ws(' ',i.product_name,b.brand_name,i.size_kg,i.mouth_size) ilike '%'||(p_filters->>'search')||'%'))
  ), page as materialized (
    select * from matching order by created_at desc,sale_id desc limit p_limit offset p_offset
  ), enriched as (
    select p.*,q.refill,q.package,q.products from page p cross join lateral (
      select coalesce(sum(si.quantity) filter(where si.type='refill' and (ids is null or si.item_id=any(ids))),0) refill,
        coalesce(sum(si.quantity) filter(where si.type='package' and (ids is null or si.item_id=any(ids))),0) package,
        coalesce(string_agg(distinct concat_ws(' ',i.product_name,b.brand_name,i.size_kg||' kg',i.mouth_size),', '),'') products
      from public.sale_items si join public.items i on i.tenant_id=si.tenant_id and i.item_id=si.item_id
      left join public.lpg_brands b on b.tenant_id=i.tenant_id and b.brand_id=i.brand_id
      where si.tenant_id=t and si.sale_id=p.sale_id and si.type in ('refill','package')
    ) q
  ) select jsonb_build_object('total',(select count(*) from matching),'entries',coalesce((select jsonb_agg(to_jsonb(e) order by created_at desc,sale_id desc) from enriched e),'[]'::jsonb)) into result;
  return result;
end $$;
create trigger immutable_inventory_movement before update or delete on public.inventory_movements for each row execute function app_private.immutable_finance_record();
