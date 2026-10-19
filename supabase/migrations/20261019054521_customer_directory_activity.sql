-- Customer reporting exposes scoped quantities; detailed sales retain their own capability gate.
create index sales_customer_activity on public.sales(tenant_id,customer_id,created_at desc,sale_id) where status='completed';

create function app_private.validate_customer_filters(f jsonb) returns void
language plpgsql immutable set search_path='' as $$
declare k text; lo bigint; hi bigint;
begin
  if f is null or jsonb_typeof(f)<>'object' then raise exception 'Invalid customer filters'; end if;
  if length(coalesce(f->>'search',''))>500 then raise exception 'Search is too long'; end if;
  if coalesce(f->>'tier','all') not in ('all','retail','wholesale')
    or coalesce(f->>'sort','name_asc') not in ('name_asc','name_desc','sold_asc','sold_desc') then raise exception 'Invalid customer filter'; end if;
  if nullif(f->>'from','')::date > nullif(f->>'to','')::date then raise exception 'Start date must not follow end date'; end if;
  if f ? 'item_ids' and f->'item_ids'<>'null'::jsonb then
    if jsonb_typeof(f->'item_ids')<>'array' or jsonb_array_length(f->'item_ids')>2000 then raise exception 'Invalid selected products'; end if;
    perform value::uuid from jsonb_array_elements_text(f->'item_ids');
  end if;
  foreach k in array array['transactions','refill','package'] loop
    lo:=nullif(f->>(k||'_min'),'')::bigint; hi:=nullif(f->>(k||'_max'),'')::bigint;
    if lo<0 or hi<0 or lo>hi then raise exception 'Invalid activity range'; end if;
  end loop;
end $$;

-- Unexposed helper; every sale and line join includes tenant identity.
create function app_private.customer_activity_rows(t uuid,from_day date,to_day date,ids uuid[])
returns table(customer_id uuid,sale_id uuid,created_at timestamptz,sale_tier text,total_amount numeric,refill bigint,package bigint)
language sql stable set search_path='' as $$
  select s.customer_id,s.sale_id,s.created_at,s.sale_tier,s.total_amount,
    coalesce(q.refill,0),coalesce(q.package,0)
  from public.sales s
  cross join lateral (
    select sum(si.quantity) filter(where si.type='refill') refill,
      sum(si.quantity) filter(where si.type='package') package,
      count(*) matched
    from public.sale_items si where si.tenant_id=t and si.sale_id=s.sale_id
      and si.type in ('refill','package') and (ids is null or si.item_id=any(ids))
  ) q
  where s.tenant_id=t and s.status='completed'
    and (from_day is null or s.created_at >= (from_day::timestamp at time zone 'Asia/Dhaka'))
    and (to_day is null or s.created_at < ((to_day+1)::timestamp at time zone 'Asia/Dhaka'))
    and (ids is null or q.matched>0)
$$;

create function public.get_customer_overview() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare
  t uuid:=app_private.require_any_permission(array['customers:view','customers:manage']);
  today date:=(now() at time zone 'Asia/Dhaka')::date;
  week_start date; cutoff timestamptz; result jsonb;
begin
  week_start:=today-((extract(dow from today)::integer+1)%7);
  cutoff:=((today::timestamp-interval '2 months') at time zone 'Asia/Dhaka');
  select jsonb_build_object(
    'wholesale',count(*) filter(where c.tier='wholesale'),
    'retail',count(*) filter(where c.tier is distinct from 'wholesale'),
    'new_wholesale',count(*) filter(where c.tier='wholesale' and c.created_at >= (week_start::timestamp at time zone 'Asia/Dhaka')),
    'new_retail',count(*) filter(where c.tier is distinct from 'wholesale' and c.created_at >= (week_start::timestamp at time zone 'Asia/Dhaka')),
    'inactive_wholesale',count(*) filter(where c.tier='wholesale' and c.created_at<cutoff and not exists(select 1 from public.sales s where s.tenant_id=t and s.customer_id=c.customer_id and s.status='completed' and s.created_at>=cutoff)),
    'inactive_retail',count(*) filter(where c.tier is distinct from 'wholesale' and c.created_at<cutoff and not exists(select 1 from public.sales s where s.tenant_id=t and s.customer_id=c.customer_id and s.status='completed' and s.created_at>=cutoff)),
    'week_start',week_start,'inactive_since',(cutoff at time zone 'Asia/Dhaka')::date
  ) into result from public.customers c where c.tenant_id=t;
  return result;
end $$;

create function public.get_customer_directory(p_filters jsonb default '{}'::jsonb,p_offset integer default 0,p_limit integer default 12,p_customer_id uuid default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare
  t uuid:=app_private.require_any_permission(array['customers:view','customers:manage']);
  ids uuid[]; result jsonb; ordering text:=coalesce(p_filters->>'sort','name_asc');
begin
  perform app_private.validate_customer_filters(p_filters);
  if p_offset is null or p_limit is null or p_offset<0 or p_offset>1000000 or p_limit not between 1 and 100 then raise exception 'Invalid customer page'; end if;
  if jsonb_typeof(p_filters->'item_ids')='array' then select coalesce(array_agg(value::uuid),'{}'::uuid[]) into ids from jsonb_array_elements_text(p_filters->'item_ids'); end if;
  with activity as materialized (
    select a.customer_id,count(*) transactions,sum(a.refill) refill,sum(a.package) package
    from app_private.customer_activity_rows(t,nullif(p_filters->>'from','')::date,nullif(p_filters->>'to','')::date,ids) a
    where p_customer_id is null or a.customer_id=p_customer_id group by a.customer_id
  ), candidates as (
    select c.tenant_id,c.customer_id,c.name,c.phone,c.shop_name,c.address,
      case when c.tier='wholesale' then 'wholesale' else 'retail' end tier,c.created_at,
      coalesce(nullif(case when c.tier='wholesale' then c.shop_name end,''),c.name) display_name,
      coalesce(a.transactions,0) transactions,coalesce(a.refill,0) refill,coalesce(a.package,0) package,
      coalesce(a.refill,0)+coalesce(a.package,0) total_sold,
      (select max(s.created_at) from public.sales s where s.tenant_id=t and s.customer_id=c.customer_id and s.status='completed') last_transaction_at
    from public.customers c left join activity a on a.customer_id=c.customer_id
    where c.tenant_id=t and (p_customer_id is null or c.customer_id=p_customer_id)
      and (coalesce(p_filters->>'tier','all')='all' or coalesce(p_filters->>'tier','all')=case when c.tier='wholesale' then 'wholesale' else 'retail' end)
      and (not exists(select 1 from regexp_split_to_table(coalesce(p_filters->>'search',''),'\s*,\s*') g where btrim(g)<>'')
        or exists(select 1 from regexp_split_to_table(lower(p_filters->>'search'),'\s*,\s*') g where btrim(g)<>'' and not exists(
          select 1 from regexp_split_to_table(btrim(g),'\s+') token where token<>''
          and position(token in lower(concat_ws(' ',c.name,c.shop_name,c.phone,c.address,c.tier,
            case when c.phone like '08801%' then substring(c.phone from 4) else '088'||c.phone end)))=0)))
  ), filtered as materialized (
    select * from candidates c where (ids is null or cardinality(ids)>0)
      and c.transactions>=coalesce(nullif(p_filters->>'transactions_min','')::bigint,0)
      and (nullif(p_filters->>'transactions_max','') is null or c.transactions<=(p_filters->>'transactions_max')::bigint)
      and c.refill>=coalesce(nullif(p_filters->>'refill_min','')::bigint,0)
      and (nullif(p_filters->>'refill_max','') is null or c.refill<=(p_filters->>'refill_max')::bigint)
      and c.package>=coalesce(nullif(p_filters->>'package_min','')::bigint,0)
      and (nullif(p_filters->>'package_max','') is null or c.package<=(p_filters->>'package_max')::bigint)
  ), page as (
    select * from filtered order by
      case when ordering='name_asc' then lower(display_name) end asc,
      case when ordering='name_desc' then lower(display_name) end desc,
      case when ordering='sold_asc' then total_sold end asc,
      case when ordering='sold_desc' then total_sold end desc,customer_id
    limit p_limit offset p_offset
  ) select jsonb_build_object('total',(select count(*) from filtered),'entries',coalesce((select jsonb_agg(to_jsonb(page)) from page),'[]'::jsonb)) into result;
  return result;
end $$;

create function public.get_customer_transactions(p_customer_id uuid,p_filters jsonb default '{}'::jsonb,p_offset integer default 0,p_limit integer default 4) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare
  t uuid:=app_private.require_any_permission(array['customers:view','customers:manage']);
  ids uuid[]; result jsonb;
begin
  perform app_private.require_any_permission(array['sales:view','receipts:print','dashboard:view']);
  perform app_private.validate_customer_filters(p_filters);
  if p_offset is null or p_limit is null or p_offset<0 or p_offset>1000000 or p_limit not between 1 and 100 then raise exception 'Invalid transaction page'; end if;
  if not exists(select 1 from public.customers where tenant_id=t and customer_id=p_customer_id) then raise exception 'Customer not found'; end if;
  if jsonb_typeof(p_filters->'item_ids')='array' then select coalesce(array_agg(value::uuid),'{}'::uuid[]) into ids from jsonb_array_elements_text(p_filters->'item_ids'); end if;
  with activity as materialized (
    select a.* from app_private.customer_activity_rows(t,nullif(p_filters->>'from','')::date,nullif(p_filters->>'to','')::date,ids) a
    where a.customer_id=p_customer_id and (coalesce(p_filters->>'search','')='' or a.sale_id::text ilike '%'||(p_filters->>'search')||'%' or exists(
      select 1 from public.sale_items si join public.items i on i.tenant_id=si.tenant_id and i.item_id=si.item_id
      left join public.lpg_brands b on b.tenant_id=i.tenant_id and b.brand_id=i.brand_id
      where si.tenant_id=t and si.sale_id=a.sale_id and concat_ws(' ',coalesce(b.brand_name,i.brand),i.size_kg,i.mouth_size) ilike '%'||(p_filters->>'search')||'%'))
  ), page as (
    select * from activity order by created_at desc,sale_id desc limit p_limit offset p_offset
  ) select jsonb_build_object('total',(select count(*) from activity),'entries',coalesce((select jsonb_agg(to_jsonb(p)||jsonb_build_object('products',coalesce((
    select string_agg(distinct concat_ws(' ',coalesce(b.brand_name,i.brand),i.size_kg||' kg',i.mouth_size),', ')
    from public.sale_items si join public.items i on i.tenant_id=si.tenant_id and i.item_id=si.item_id
    left join public.lpg_brands b on b.tenant_id=i.tenant_id and b.brand_id=i.brand_id where si.tenant_id=t and si.sale_id=p.sale_id and si.type in ('refill','package')),''))) from page p),'[]'::jsonb)) into result;
  return result;
end $$;

create function public.get_customer_filter_products() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['customers:view','customers:manage']);
begin
  return jsonb_build_object('items',coalesce((select jsonb_agg(jsonb_build_object('item_id',i.item_id,'brand_id',i.brand_id,'brand',i.brand,'size_kg',i.size_kg,'mouth_size',i.mouth_size,'lpg_brands',case when b.brand_id is null then null else jsonb_build_object('brand_id',b.brand_id,'brand_name',b.brand_name) end)) from public.items i left join public.lpg_brands b on b.tenant_id=i.tenant_id and b.brand_id=i.brand_id where i.tenant_id=t),'[]'::jsonb),
    'brands',coalesce((select jsonb_agg(jsonb_build_object('brand_id',b.brand_id,'brand_name',b.brand_name) order by b.display_order,b.brand_name,b.brand_id) from public.lpg_brands b where b.tenant_id=t),'[]'::jsonb));
end $$;

create function public.update_customer_details(p_customer_id uuid,p_payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['customers:manage']); c public.customers; v_phone text:=btrim(p_payload->>'phone'); v_tier text:=p_payload->>'tier';
begin
  if v_tier is null or v_tier not in ('retail','wholesale') then raise exception 'Choose retail or wholesale'; end if;
  if v_phone is null or v_phone !~ '^(01[3-9][0-9]{8}|08801[3-9][0-9]{8})$' then raise exception 'Enter a valid Bangladesh mobile number'; end if;
  if v_tier='wholesale' and nullif(btrim(p_payload->>'shop_name'),'') is null then raise exception 'Shop name is required for wholesale customers'; end if;
  select * into c from public.customers where tenant_id=t and customer_id=p_customer_id for update;
  if not found then raise exception 'Customer not found'; end if;
  update public.customers set name=coalesce(nullif(btrim(p_payload->>'name'),''),'Unknown'),phone=v_phone,
    tier=v_tier,shop_name=nullif(btrim(p_payload->>'shop_name'),''),address=nullif(btrim(p_payload->>'address'),'')
    where tenant_id=t and customer_id=p_customer_id returning * into c;
  return to_jsonb(c);
exception when unique_violation then raise exception 'A customer with this phone number already exists';
end $$;

alter function public.get_customer_overview() owner to postgres;
alter function public.get_customer_directory(jsonb,integer,integer,uuid) owner to postgres;
alter function public.get_customer_transactions(uuid,jsonb,integer,integer) owner to postgres;
alter function public.get_customer_filter_products() owner to postgres;
alter function public.update_customer_details(uuid,jsonb) owner to postgres;
alter function app_private.validate_customer_filters(jsonb) owner to postgres;
alter function app_private.customer_activity_rows(uuid,date,date,uuid[]) owner to postgres;
revoke all on function app_private.validate_customer_filters(jsonb),app_private.customer_activity_rows(uuid,date,date,uuid[]) from public,anon,authenticated;
revoke all on function public.get_customer_overview(),public.get_customer_directory(jsonb,integer,integer,uuid),public.get_customer_transactions(uuid,jsonb,integer,integer),public.get_customer_filter_products(),public.update_customer_details(uuid,jsonb) from public,anon,authenticated;
grant execute on function public.get_customer_overview(),public.get_customer_directory(jsonb,integer,integer,uuid),public.get_customer_transactions(uuid,jsonb,integer,integer),public.get_customer_filter_products(),public.update_customer_details(uuid,jsonb) to authenticated;
