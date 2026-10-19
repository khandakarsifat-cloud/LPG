-- Preserve existing attributed shared rates; until changed, their saved value applies to both types.
-- New rows atomically record the owner's separate refill and package commission per unit.
alter table public.product_commission_rates add column package_commission_per_unit numeric(12,2)
  check (package_commission_per_unit>=0 and package_commission_per_unit<10000000000);

create function public.set_product_commissions(p_item_id uuid,p_refill_rate numeric,p_package_rate numeric,p_expected uuid default null) returns void
language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('inventory:manage'); current_version uuid;
begin
  if not app_private.can_manage_inventory_prices() then
    raise exception 'Only the owner can edit product prices or commission' using errcode='42501';
  end if;
  if p_refill_rate is null or p_package_rate is null
    or p_refill_rate::text in ('NaN','Infinity','-Infinity') or p_package_rate::text in ('NaN','Infinity','-Infinity')
    or p_refill_rate<0 or p_package_rate<0 or p_refill_rate>=10000000000 or p_package_rate>=10000000000
    or p_refill_rate<>round(p_refill_rate,2) or p_package_rate<>round(p_package_rate,2) then
    raise exception 'Commission rates must be nonnegative with at most two decimal places';
  end if;
  perform 1 from public.items where tenant_id=t and item_id=p_item_id for update;
  if not found then raise exception 'Product not found'; end if;
  select rate_id into current_version from public.product_commission_rates
    where tenant_id=t and item_id=p_item_id order by created_at desc,rate_id desc limit 1;
  if current_version is distinct from p_expected then
    raise exception 'Commission changed. Reload the saved rates before saving.' using errcode='40001';
  end if;
  insert into public.product_commission_rates(tenant_id,item_id,commission_per_unit,package_commission_per_unit,created_by)
    values(t,p_item_id,p_refill_rate,p_package_rate,auth.uid());
end $$;

-- Older open clients must reload rather than overwrite two rates with a shared value.
create or replace function public.set_product_commission(p_item_id uuid,p_rate numeric,p_expected uuid default null) returns void
language plpgsql security definer set search_path='' as $$
begin
  perform app_private.require_permission('inventory:manage');
  if not app_private.can_manage_inventory_prices() then
    raise exception 'Only the owner can edit product prices or commission' using errcode='42501';
  end if;
  raise exception 'Commission now has separate refill and package rates. Reload the application before saving.' using errcode='40001';
end $$;

create or replace function public.get_product_inventory(p_item_id uuid) returns jsonb
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
  with current_commission as (
    select coalesce((select c.commission_per_unit from public.product_commission_rates c
      where c.tenant_id=t and c.item_id=p_item_id order by c.created_at desc,c.rate_id desc limit 1),0) refill_rate,
      coalesce((select coalesce(c.package_commission_per_unit,c.commission_per_unit) from public.product_commission_rates c
      where c.tenant_id=t and c.item_id=p_item_id order by c.created_at desc,c.rate_id desc limit 1),0) package_rate,
      (select c.rate_id from public.product_commission_rates c where c.tenant_id=t and c.item_id=p_item_id
        order by c.created_at desc,c.rate_id desc limit 1) version
  ), current_prices as (
    select distinct on (customer_tier,price_type) customer_tier,price_type,price,mrp,effective_from
    from public.price_books
    where tenant_id=t and item_id=p_item_id and effective_from<=as_of
      and (effective_to is null or effective_to>as_of)
    order by customer_tier,price_type,effective_from desc
  ), latest_receipts as (
    select distinct on (pi.type) pi.type,p.purchase_id,p.received_at,p.transport_cost,p.labour_cost
    from public.purchase_items pi join public.purchases p using(tenant_id,purchase_id)
    where pi.tenant_id=t and pi.item_id=p_item_id and p.status='received'
      and coalesce(pi.received_quantity,pi.quantity)>0
    order by pi.type,p.received_at desc nulls last,p.created_at desc,p.purchase_id desc
  ), buying as (
    select r.type,r.received_at,
      round(lines.amount/lines.units,2) bottle_cost,
      case when r.type='refill' then c.refill_rate else c.package_rate end commission_per_unit,
      round((coalesce(r.transport_cost,0)+coalesce(r.labour_cost,0))/shipment.units,2) overhead_per_unit,
      round(lines.amount/lines.units
        + (coalesce(r.transport_cost,0)+coalesce(r.labour_cost,0))/shipment.units
        - case when r.type='refill' then c.refill_rate else c.package_rate end,2) estimated_unit_cost
    from latest_receipts r cross join current_commission c
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
    'can_manage_prices',app_private.can_manage_inventory_prices(),
    'commission',(select to_jsonb(c) from current_commission c),
    'prices',coalesce((select jsonb_agg(to_jsonb(c) order by customer_tier,price_type) from current_prices c),'[]'::jsonb),
    'buying_costs',coalesce((select jsonb_agg(to_jsonb(b) order by type) from buying b),'[]'::jsonb),
    'weeks',(select jsonb_agg(to_jsonb(h) order by start_date desc) from history h)
  ) into result;
  return result;
end $$;

-- Save both line types atomically; detect another operator changing the loaded prices.

alter function public.set_product_commissions(uuid,numeric,numeric,uuid) owner to postgres;
revoke all on function public.set_product_commissions(uuid,numeric,numeric,uuid) from public,anon,authenticated;
grant execute on function public.set_product_commissions(uuid,numeric,numeric,uuid) to authenticated;
