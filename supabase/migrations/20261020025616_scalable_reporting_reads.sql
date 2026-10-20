-- Bound historical detail work to the requested page; preserve existing reporting contracts.
create or replace function public.get_customer_directory(p_filters jsonb default '{}'::jsonb,p_offset integer default 0,p_limit integer default 12,p_customer_id uuid default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare
  t uuid:=app_private.require_any_permission(array['customers:view','customers:manage']);
  ids uuid[]; result jsonb; ordering text:=coalesce(p_filters->>'sort','name_asc');
begin
  perform app_private.validate_customer_filters(p_filters);
  if p_offset is null or p_limit is null or p_offset<0 or p_offset>1000000 or p_limit not between 1 and 100 then raise exception 'Invalid customer page'; end if;
  if jsonb_typeof(p_filters->'item_ids')='array' then select coalesce(array_agg(value::uuid),'{}'::uuid[]) into ids from jsonb_array_elements_text(p_filters->'item_ids'); end if;

  -- Name-sorted, unscoped reads need quantities only for the displayed customers.
  -- Activity-filtered and quantity-sorted reads retain the full reporting path.
  if nullif(p_filters->>'from','') is null and nullif(p_filters->>'to','') is null
    and ids is null and ordering in ('name_asc','name_desc')
    and not exists(select 1 from jsonb_each_text(p_filters) f
      where f.key in ('transactions_min','transactions_max','refill_min','refill_max','package_min','package_max')
      and nullif(f.value,'') is not null) then
    with candidates as materialized (
      select c.*,coalesce(nullif(case when c.tier='wholesale' then c.shop_name end,''),c.name) display_name
      from public.customers c where c.tenant_id=t and (p_customer_id is null or c.customer_id=p_customer_id)
        and (coalesce(p_filters->>'tier','all')='all' or coalesce(p_filters->>'tier','all')=case when c.tier='wholesale' then 'wholesale' else 'retail' end)
        and (not exists(select 1 from regexp_split_to_table(coalesce(p_filters->>'search',''),'\s*,\s*') g where btrim(g)<>'')
          or exists(select 1 from regexp_split_to_table(lower(p_filters->>'search'),'\s*,\s*') g where btrim(g)<>'' and not exists(
            select 1 from regexp_split_to_table(btrim(g),'\s+') token where token<>''
            and position(token in lower(concat_ws(' ',c.name,c.shop_name,c.phone,c.address,c.tier,
              case when c.phone like '08801%' then substring(c.phone from 4) else '088'||c.phone end)))=0)))
    ), page as materialized (
      select * from candidates order by
        case when ordering='name_asc' then lower(display_name) end asc,
        case when ordering='name_desc' then lower(display_name) end desc,customer_id
      limit p_limit offset p_offset
    ), enriched as (
      select p.tenant_id,p.customer_id,p.name,p.phone,p.shop_name,p.address,
        case when p.tier='wholesale' then 'wholesale' else 'retail' end tier,p.created_at,p.display_name,
        a.transactions,a.refill,a.package,a.refill+a.package total_sold,a.last_transaction_at
      from page p cross join lateral (
        select count(*) transactions,coalesce(sum(q.refill),0) refill,coalesce(sum(q.package),0) package,max(s.created_at) last_transaction_at
        from public.sales s cross join lateral (
          select sum(si.quantity) filter(where si.type='refill') refill,sum(si.quantity) filter(where si.type='package') package
          from public.sale_items si where si.tenant_id=t and si.sale_id=s.sale_id and si.type in ('refill','package')
        ) q where s.tenant_id=t and s.customer_id=p.customer_id and s.status='completed'
      ) a
    ) select jsonb_build_object('total',(select count(*) from candidates),'entries',coalesce((select jsonb_agg(to_jsonb(e) order by
      case when ordering='name_asc' then lower(display_name) end asc,
      case when ordering='name_desc' then lower(display_name) end desc,customer_id) from enriched e),'[]'::jsonb)) into result;
    return result;
  end if;
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

create or replace function public.get_customer_transactions(p_customer_id uuid,p_filters jsonb default '{}'::jsonb,p_offset integer default 0,p_limit integer default 4) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['customers:view','customers:manage']); ids uuid[]; result jsonb;
begin
  perform app_private.require_any_permission(array['sales:view','receipts:print','dashboard:view']);
  perform app_private.validate_customer_filters(p_filters);
  if p_offset is null or p_limit is null or p_offset<0 or p_offset>1000000 or p_limit not between 1 and 100 then raise exception 'Invalid transaction page'; end if;
  if not exists(select 1 from public.customers where tenant_id=t and customer_id=p_customer_id) then raise exception 'Customer not found'; end if;
  if jsonb_typeof(p_filters->'item_ids')='array' then select coalesce(array_agg(value::uuid),'{}'::uuid[]) into ids from jsonb_array_elements_text(p_filters->'item_ids'); end if;
  -- Count/search headers first. Aggregate line quantities only for this page.
  with matching as materialized (
    select s.customer_id,s.sale_id,s.created_at,s.sale_tier,s.total_amount from public.sales s
    where s.tenant_id=t and s.customer_id=p_customer_id and s.status='completed'
      and (nullif(p_filters->>'from','') is null or s.created_at >= (nullif(p_filters->>'from','')::date::timestamp at time zone 'Asia/Dhaka'))
      and (nullif(p_filters->>'to','') is null or s.created_at < ((nullif(p_filters->>'to','')::date+1)::timestamp at time zone 'Asia/Dhaka'))
      and (ids is null or exists(select 1 from public.sale_items si where si.tenant_id=t and si.sale_id=s.sale_id and si.type in ('refill','package') and si.item_id=any(ids)))
      and (coalesce(p_filters->>'search','')='' or s.sale_id::text ilike '%'||(p_filters->>'search')||'%' or exists(
        select 1 from public.sale_items si join public.items i on i.tenant_id=si.tenant_id and i.item_id=si.item_id
        left join public.lpg_brands b on b.tenant_id=i.tenant_id and b.brand_id=i.brand_id
        where si.tenant_id=t and si.sale_id=s.sale_id and concat_ws(' ',coalesce(b.brand_name,i.brand),i.size_kg,i.mouth_size) ilike '%'||(p_filters->>'search')||'%'))
  ), page as materialized (
    select * from matching order by created_at desc,sale_id desc limit p_limit offset p_offset
  ), enriched as (
    select p.*,q.refill,q.package,q.products from page p cross join lateral (
      select coalesce(sum(si.quantity) filter(where si.type='refill' and (ids is null or si.item_id=any(ids))),0) refill,
        coalesce(sum(si.quantity) filter(where si.type='package' and (ids is null or si.item_id=any(ids))),0) package,
        coalesce(string_agg(distinct concat_ws(' ',coalesce(b.brand_name,i.brand),i.size_kg||' kg',i.mouth_size),', '),'') products
      from public.sale_items si join public.items i on i.tenant_id=si.tenant_id and i.item_id=si.item_id
      left join public.lpg_brands b on b.tenant_id=i.tenant_id and b.brand_id=i.brand_id
      where si.tenant_id=t and si.sale_id=p.sale_id and si.type in ('refill','package')
    ) q
  ) select jsonb_build_object('total',(select count(*) from matching),'entries',coalesce((select jsonb_agg(to_jsonb(e) order by created_at desc,sale_id desc) from enriched e),'[]'::jsonb)) into result;
  return result;
end $$;
create function app_private.purchase_rows(t uuid,ids uuid[]) returns setof jsonb
language sql stable set search_path='' as $$
select to_jsonb(p) || jsonb_build_object(
    'truck_name',tr.name,'plant_name',gp.plant_name,'company_name',b.brand_name,
    'operating_cost',(select coalesce(sum(total_cost),0) from public.transits where tenant_id=t and purchase_id=p.purchase_id),
    'items',coalesce((select jsonb_agg(to_jsonb(pi)||jsonb_build_object('brand_name',coalesce(lb.brand_name,i.brand),
      'size_kg',i.size_kg,'mouth_size',i.mouth_size) order by pi.created_at,pi.purchase_item_id)
      from public.purchase_items pi join public.items i on i.tenant_id=pi.tenant_id and i.item_id=pi.item_id
      left join public.lpg_brands lb on lb.tenant_id=i.tenant_id and lb.brand_id=i.brand_id
      where pi.tenant_id=t and pi.purchase_id=p.purchase_id),'[]'::jsonb))
    from public.purchases p left join public.trucks tr on tr.tenant_id=p.tenant_id and tr.truck_id=p.truck_id
    left join public.gas_plants gp on gp.tenant_id=p.tenant_id and gp.plant_id=p.plant_id
    left join public.lpg_brands b on b.tenant_id=p.tenant_id and b.brand_id=p.brand_id
    where p.tenant_id=t and p.purchase_id=any(ids) order by p.created_at desc,p.purchase_id;

$$;

create function public.get_purchases_by_ids(p_ids uuid[]) returns setof jsonb
language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['purchases:view','purchases:manage']);
begin
  if p_ids is null or cardinality(p_ids)>100 then raise exception 'Invalid purchase selection'; end if;
  return query select * from app_private.purchase_rows(t,p_ids);
end $$;

create function public.get_purchase_overview() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['purchases:view','purchases:manage']); result jsonb;
begin
  select jsonb_build_object('total',count(*),'created',count(*) filter(where status='created'),
    'in_transit',count(*) filter(where status='in_transit'),
    'unpaid',count(*) filter(where payment_status='unpaid' and status not in ('created','cancelled')),
    'company_payable',coalesce(sum(company_payable) filter(where payment_status='unpaid' and status not in ('created','cancelled')),0))
  into result from public.purchases where tenant_id=t;
  return result;
end $$;

create function public.get_purchase_directory(p_filters jsonb default '{}'::jsonb,p_offset integer default 0,p_limit integer default 6) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['purchases:view','purchases:manage']); result jsonb;
  ordering text:=coalesce(p_filters->>'sort','date_desc'); searching boolean:=false;
begin
  if p_filters is null or jsonb_typeof(p_filters)<>'object' or length(coalesce(p_filters->>'search',''))>500
    or coalesce(p_filters->>'status','all') not in ('all','created','in_transit','received','cancelled')
    or coalesce(p_filters->>'payment','all') not in ('all','unpaid','paid')
    or ordering not in ('date_desc','date_asc','amount_desc','amount_asc') then raise exception 'Invalid purchase filters'; end if;
  if p_offset is null or p_limit is null or p_offset<0 or p_offset>1000000 or p_limit not between 1 and 100 then raise exception 'Invalid purchase page'; end if;
  searching:=exists(select 1 from regexp_split_to_table(coalesce(p_filters->>'search',''),'\s*,\s*') g where btrim(g)<>'');
  with matching as materialized (
    select p.purchase_id,p.created_at,p.total_cost from public.purchases p
    left join public.trucks tr on tr.tenant_id=t and tr.truck_id=p.truck_id
    left join public.gas_plants gp on gp.tenant_id=t and gp.plant_id=p.plant_id
    left join public.lpg_brands b on b.tenant_id=t and b.brand_id=p.brand_id
    where p.tenant_id=t
      and (coalesce(p_filters->>'status','all')='all' or p.status::text=p_filters->>'status')
      and (coalesce(p_filters->>'payment','all')='all' or p.payment_status=p_filters->>'payment')
      and (nullif(p_filters->>'from','') is null or p.created_at >= (nullif(p_filters->>'from','')::date::timestamp at time zone 'Asia/Dhaka'))
      and (nullif(p_filters->>'to','') is null or p.created_at < ((nullif(p_filters->>'to','')::date+1)::timestamp at time zone 'Asia/Dhaka'))
      and (not searching or exists(
        select 1 from (select lower(concat_ws(' ',p.purchase_id,b.brand_name,gp.plant_name,tr.name,p.notes,p.receipt_notes,p.status,p.payment_status,
          (select string_agg(concat_ws(' ',coalesce(lb.brand_name,i.brand),trim_scale(i.size_kg)||'kg',trim_scale(i.size_kg)||' kg',i.mouth_size,
            case when pi.type='refill' then 'refill exchange' else 'package new cylinders' end),' ')
          from public.purchase_items pi join public.items i on i.tenant_id=pi.tenant_id and i.item_id=pi.item_id
          left join public.lpg_brands lb on lb.tenant_id=i.tenant_id and lb.brand_id=i.brand_id where pi.tenant_id=t and pi.purchase_id=p.purchase_id))) text) document
        where exists(select 1 from regexp_split_to_table(lower(p_filters->>'search'),'\s*,\s*') g where btrim(g)<>'' and not exists(
          select 1 from regexp_split_to_table(btrim(g),'\s+') token where token<>'' and position(token in document.text)=0))))
  ), page as materialized (
    select * from matching order by
      case when ordering='date_desc' then created_at end desc,case when ordering='date_asc' then created_at end asc,
      case when ordering='amount_desc' then total_cost end desc,case when ordering='amount_asc' then total_cost end asc,purchase_id
    limit p_limit offset p_offset
  ), details as (
    select r.* from app_private.purchase_rows(t,coalesce((select array_agg(purchase_id) from page),'{}'::uuid[])) r
  ) select jsonb_build_object('total',(select count(*) from matching),'entries',coalesce((select jsonb_agg(d.r order by
    case when ordering='date_desc' then p.created_at end desc,case when ordering='date_asc' then p.created_at end asc,
    case when ordering='amount_desc' then p.total_cost end desc,case when ordering='amount_asc' then p.total_cost end asc,p.purchase_id)
    from details d(r) join page p on p.purchase_id=(d.r->>'purchase_id')::uuid),'[]'::jsonb)) into result;
  return result;
end $$;

alter function app_private.purchase_rows(uuid,uuid[]) owner to postgres;
alter function public.get_purchase_directory(jsonb,integer,integer) owner to postgres;
alter function public.get_purchase_overview() owner to postgres;
alter function public.get_purchases_by_ids(uuid[]) owner to postgres;
revoke all on function app_private.purchase_rows(uuid,uuid[]) from public,anon,authenticated;
revoke all on function public.get_purchase_directory(jsonb,integer,integer),public.get_purchase_overview(),public.get_purchases_by_ids(uuid[]) from public,anon,authenticated;
grant execute on function public.get_purchase_directory(jsonb,integer,integer),public.get_purchase_overview(),public.get_purchases_by_ids(uuid[]) to authenticated;
