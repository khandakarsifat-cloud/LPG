-- Weekly operational receipts follow the same completed-sale boundary as sales.
-- Original receipt and cancellation movements remain immutable accounting evidence.
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
      coalesce((select sum(l.quantity) from public.sale_bottle_receipt_lines l join public.sale_bottle_receipts r on r.tenant_id=t and r.receipt_id=l.receipt_id join public.sales actual_sale on actual_sale.tenant_id=r.tenant_id and actual_sale.sale_id=r.sale_id and actual_sale.status='completed' where l.tenant_id=t and l.received_item_id=p_item_id and r.created_at >= (w.start_date::timestamp at time zone 'Asia/Dhaka') and r.created_at < (w.end_date::timestamp at time zone 'Asia/Dhaka')),0) empty_return,
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

