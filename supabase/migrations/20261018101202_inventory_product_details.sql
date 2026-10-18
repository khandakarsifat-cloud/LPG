-- Keep price_books.price as the selling price. MRP is optional display metadata.
alter table public.price_books add column mrp numeric(12,2);
alter table public.price_books add constraint price_books_mrp_nonnegative check (mrp >= 0);
alter table public.price_books drop constraint price_books_pkey;
alter table public.price_books add primary key (tenant_id,item_id,customer_tier,price_type,effective_from);

create index inventory_sales_item_history on public.sale_items(tenant_id,item_id,sale_id);
create index inventory_purchase_item_history on public.purchase_items(tenant_id,item_id,purchase_id);

-- Inventory readers receive only this product's aggregates, not customer/supplier data.
create function public.get_product_inventory(p_item_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
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
  ), latest_receipts as (
    select distinct on (pi.type) pi.type,p.purchase_id,p.received_at,p.transport_cost,p.labour_cost,
      p.commission,p.subtotal
    from public.purchase_items pi join public.purchases p using(tenant_id,purchase_id)
    where pi.tenant_id=t and pi.item_id=p_item_id and p.status='received'
      and coalesce(pi.received_quantity,pi.quantity)>0
    order by pi.type,p.received_at desc nulls last,p.created_at desc,p.purchase_id desc
  ), buying as (
    select r.type,r.received_at,
      round(lines.amount/lines.units,2) bottle_cost,
      round((coalesce(r.transport_cost,0)+coalesce(r.labour_cost,0))/shipment.units,2) overhead_per_unit,
      round(case when r.subtotal>0 then r.commission*lines.amount/r.subtotal/lines.units else 0 end,2) commission_per_unit,
      round(lines.amount/lines.units
        - case when r.subtotal>0 then r.commission*lines.amount/r.subtotal/lines.units else 0 end
        + (coalesce(r.transport_cost,0)+coalesce(r.labour_cost,0))/shipment.units,2) estimated_unit_cost
    from latest_receipts r
    cross join lateral (
      select sum(pi.line_total) amount,sum(coalesce(pi.received_quantity,pi.quantity)) units
      from public.purchase_items pi where pi.tenant_id=t and pi.purchase_id=r.purchase_id
        and pi.item_id=p_item_id and pi.type=r.type
    ) lines
    cross join lateral (
      select sum(coalesce(pi.received_quantity,pi.quantity)) units
      from public.purchase_items pi where pi.tenant_id=t and pi.purchase_id=r.purchase_id
    ) shipment
  ), weeks as (
    select (saturday - n*7) start_date,(saturday - n*7 + 7) end_date
    from generate_series(0,7) n
  ), history as (
    select w.start_date,w.end_date-1 end_date,
      coalesce(s.sold_refill,0) sold_refill,coalesce(s.sold_package,0) sold_package,
      coalesce(s.empty_return,0) empty_return,
      coalesce(p.bought_package,0) bought_package,coalesce(p.bought_refill,0) bought_refill
    from weeks w
    cross join lateral (
      select sum(si.quantity) filter(where si.type='refill') sold_refill,
        sum(si.quantity) filter(where si.type='package') sold_package,
        sum(si.quantity) filter(where si.type='empty_return') empty_return
      from public.sale_items si join public.sales s using(tenant_id,sale_id)
      where si.tenant_id=t and si.item_id=p_item_id and s.status='completed'
        and s.created_at >= (w.start_date::timestamp at time zone 'Asia/Dhaka')
        and s.created_at < (w.end_date::timestamp at time zone 'Asia/Dhaka')
    ) s
    cross join lateral (
      select sum(coalesce(pi.received_quantity,pi.quantity)) filter(where pi.type='package') bought_package,
        sum(coalesce(pi.received_quantity,pi.quantity)) filter(where pi.type='refill') bought_refill
      from public.purchase_items pi join public.purchases p using(tenant_id,purchase_id)
      where pi.tenant_id=t and pi.item_id=p_item_id and p.status='received'
        and p.received_at >= (w.start_date::timestamp at time zone 'Asia/Dhaka')
        and p.received_at < (w.end_date::timestamp at time zone 'Asia/Dhaka')
    ) p
  )
  select jsonb_build_object(
    'prices',coalesce((select jsonb_agg(to_jsonb(c) order by customer_tier,price_type) from current_prices c),'[]'::jsonb),
    'buying_costs',coalesce((select jsonb_agg(to_jsonb(b) order by type) from buying b),'[]'::jsonb),
    'weeks',(select jsonb_agg(to_jsonb(h) order by start_date desc) from history h)
  ) into result;
  return result;
end $$;

-- Save both line types atomically; detect another operator changing the loaded prices.
create function public.save_product_prices(p_item_id uuid,p_customer_tier text,p_prices jsonb,p_expected jsonb)
returns void language plpgsql security definer set search_path='' as $$
declare
  t uuid := app_private.require_permission('inventory:manage');
  kind text; entry jsonb; selling numeric; display_mrp numeric; current_version timestamptz;
  saved_at timestamptz; next_start timestamptz;
begin
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
      raise exception 'Prices changed. Reload saved prices before saving.' using errcode='40001';
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
end $$;

alter function public.get_product_inventory(uuid) owner to postgres;
alter function public.save_product_prices(uuid,text,jsonb,jsonb) owner to postgres;
revoke all on function public.get_product_inventory(uuid),public.save_product_prices(uuid,text,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.get_product_inventory(uuid),public.save_product_prices(uuid,text,jsonb,jsonb) to authenticated;
