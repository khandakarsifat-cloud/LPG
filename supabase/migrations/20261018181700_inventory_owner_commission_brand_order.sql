-- Product estimates ignore purchase commission. Explicit product rates are append-only.
create function app_private.can_manage_inventory_prices() returns boolean
language sql stable security definer set search_path='' as $$
  select app_private.has_permission('inventory:manage') and exists(
    select 1 from public.user_roles ur join public.roles r using(tenant_id,role_id)
    where ur.tenant_id=app_private.current_tenant_id() and ur.user_id=auth.uid() and r.name='OWNER'
  )
$$;

create table public.product_commission_rates (
  tenant_id uuid not null,
  item_id uuid not null,
  rate_id uuid not null default gen_random_uuid(),
  commission_per_unit numeric(12,2) not null check (commission_per_unit>=0 and commission_per_unit<10000000000),
  created_by uuid not null,
  created_at timestamptz not null default clock_timestamp(),
  primary key(tenant_id,rate_id),
  foreign key(tenant_id,item_id) references public.items(tenant_id,item_id),
  foreign key(tenant_id,created_by) references public.user_profiles(tenant_id,user_id)
);
alter table public.product_commission_rates owner to postgres;
alter table public.product_commission_rates enable row level security;
-- Deliberately no browser table grants/policies: only the current rate is returned by the product RPC.
revoke all on public.product_commission_rates from public,anon,authenticated;
create index product_commission_latest on public.product_commission_rates(tenant_id,item_id,created_at desc,rate_id desc);
create function app_private.product_commission_immutable() returns trigger
language plpgsql set search_path='' as $$
begin raise exception 'Product commission history is immutable'; end $$;
create trigger product_commission_immutable before update or delete on public.product_commission_rates
  for each row execute function app_private.product_commission_immutable();

create function public.set_product_commission(p_item_id uuid,p_rate numeric,p_expected uuid default null) returns void
language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('inventory:manage'); current_version uuid;
begin
  if not app_private.can_manage_inventory_prices() then
    raise exception 'Only the owner can edit product prices or commission' using errcode='42501';
  end if;
  if p_rate is null or p_rate::text in ('NaN','Infinity','-Infinity') or p_rate<0 or p_rate>=10000000000 or p_rate<>round(p_rate,2) then
    raise exception 'Commission must be nonnegative with at most two decimal places';
  end if;
  perform 1 from public.items where tenant_id=t and item_id=p_item_id for update;
  if not found then raise exception 'Product not found'; end if;
  select rate_id into current_version from public.product_commission_rates
    where tenant_id=t and item_id=p_item_id order by created_at desc,rate_id desc limit 1;
  if current_version is distinct from p_expected then
    raise exception 'Commission changed. Reload the saved rate before saving.' using errcode='40001';
  end if;
  insert into public.product_commission_rates(tenant_id,item_id,commission_per_unit,created_by)
    values(t,p_item_id,p_rate,auth.uid());
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
  with current_prices as (
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
      round((coalesce(r.transport_cost,0)+coalesce(r.labour_cost,0))/shipment.units,2) overhead_per_unit,
      round(lines.amount/lines.units
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
    'can_manage_prices',app_private.can_manage_inventory_prices(),
    'commission',jsonb_build_object(
      'rate',coalesce((select c.commission_per_unit from public.product_commission_rates c where c.tenant_id=t and c.item_id=p_item_id order by c.created_at desc,c.rate_id desc limit 1),0),
      'version',(select c.rate_id from public.product_commission_rates c where c.tenant_id=t and c.item_id=p_item_id order by c.created_at desc,c.rate_id desc limit 1)),
    'prices',coalesce((select jsonb_agg(to_jsonb(c) order by customer_tier,price_type) from current_prices c),'[]'::jsonb),
    'buying_costs',coalesce((select jsonb_agg(to_jsonb(b) order by type) from buying b),'[]'::jsonb),
    'weeks',(select jsonb_agg(to_jsonb(h) order by start_date desc) from history h)
  ) into result;
  return result;
end $$;

-- Save both line types atomically; detect another operator changing the loaded prices.
create or replace function public.save_product_prices(p_item_id uuid,p_customer_tier text,p_prices jsonb,p_expected jsonb)
returns void language plpgsql security definer set search_path='' as $$
declare
  t uuid := app_private.require_permission('inventory:manage');
  kind text; entry jsonb; selling numeric; display_mrp numeric; current_version timestamptz;
  saved_at timestamptz; next_start timestamptz;
begin
  if not app_private.can_manage_inventory_prices() then
    raise exception 'Only the owner can edit product prices or commission' using errcode='42501';
  end if;
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


-- Preserve the previous newest-first ordering until Settings explicitly reorders brands.
alter table public.lpg_brands add column display_order integer not null default 0 check(display_order>=0);

create or replace function public.list_lpg_brands(p_active_only boolean default true)
returns table(brand_id uuid,brand_name varchar,description text,is_active boolean,created_at timestamptz)
language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['settings:manage','inventory:view','inventory:manage','pos:sell','purchases:view','purchases:manage','gas_plants:view','gas_plants:manage']);
begin
  return query select b.brand_id,b.brand_name,b.description,b.is_active,b.created_at
    from public.lpg_brands b where b.tenant_id=t and (not p_active_only or b.is_active)
    order by b.display_order,b.created_at desc,b.brand_id;
end $$;

create or replace function public.create_lpg_brand(p_brand_name text,p_description text default null) returns jsonb
language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('settings:manage'); id uuid; next_order integer;
begin
  perform 1 from public.tenants where tenant_id=t for update;
  select coalesce(max(display_order),-1)+1 into next_order from public.lpg_brands where tenant_id=t;
  insert into public.lpg_brands(tenant_id,brand_name,description,display_order)
    values(t,p_brand_name,p_description,next_order) returning brand_id into id;
  return jsonb_build_object('brand_id',id,'brand_name',p_brand_name,'description',p_description);
end $$;

create function public.set_lpg_brand_order(p_brand_ids uuid[],p_expected uuid[]) returns void
language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('settings:manage'); current_order uuid[];
begin
  -- Serialize brand creation/reordering; reject stale full-list edits instead of losing another editor's order.
  perform 1 from public.tenants where tenant_id=t for update;
  select coalesce(array_agg(b.brand_id order by b.display_order,b.created_at desc,b.brand_id),array[]::uuid[])
    into current_order from public.lpg_brands b where b.tenant_id=t;
  if current_order is distinct from p_expected then
    raise exception 'Brand order changed. Reload brands before reordering.' using errcode='40001';
  end if;
  if p_brand_ids is null or cardinality(p_brand_ids)<>cardinality(current_order)
    or (select count(distinct id) from unnest(p_brand_ids) id)<>cardinality(current_order)
    or exists(select 1 from unnest(p_brand_ids) id where id is null or not id=any(current_order)) then
    raise exception 'Include each brand in this business exactly once';
  end if;
  update public.lpg_brands b set display_order=position.ordinality-1,updated_at=clock_timestamp()
    from unnest(p_brand_ids) with ordinality position(brand_id,ordinality)
    where b.tenant_id=t and b.brand_id=position.brand_id and b.display_order<>position.ordinality-1;
end $$;

alter function app_private.can_manage_inventory_prices() owner to postgres;
alter function app_private.product_commission_immutable() owner to postgres;
alter function public.set_product_commission(uuid,numeric,uuid) owner to postgres;
alter function public.get_product_inventory(uuid) owner to postgres;
alter function public.save_product_prices(uuid,text,jsonb,jsonb) owner to postgres;
alter function public.list_lpg_brands(boolean) owner to postgres;
alter function public.create_lpg_brand(text,text) owner to postgres;
alter function public.set_lpg_brand_order(uuid[],uuid[]) owner to postgres;
revoke all on function app_private.can_manage_inventory_prices(),app_private.product_commission_immutable() from public,anon,authenticated;
revoke all on function public.set_product_commission(uuid,numeric,uuid),public.set_lpg_brand_order(uuid[],uuid[]) from public,anon,authenticated;
grant execute on function public.set_product_commission(uuid,numeric,uuid),public.set_lpg_brand_order(uuid[],uuid[]) to authenticated;
