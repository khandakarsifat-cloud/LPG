-- One sale header per qualifying sale: money never multiplies with matching lines.
-- Existing tenant/date, tenant/customer/date and tenant/item/sale indexes are reused.
create or replace function app_private.validate_customer_filters(f jsonb) returns void
language plpgsql immutable set search_path='' as $$
declare k text; lo bigint; hi bigint;
begin
  if f is null or jsonb_typeof(f)<>'object' then raise exception 'Invalid customer filters'; end if;
  if length(coalesce(f->>'search',''))>500 then raise exception 'Search is too long'; end if;
  if coalesce(f->>'tier','all') not in ('all','retail','wholesale')
    or coalesce(f->>'sort','name_asc') not in ('name_asc','name_desc','sold_asc','sold_desc','due_asc','due_desc','last_sale_asc','last_sale_desc') then raise exception 'Invalid customer filter'; end if;
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


create or replace function public.get_customer_directory(p_filters jsonb default '{}'::jsonb,p_offset integer default 0,p_limit integer default 12,p_customer_id uuid default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare
  t uuid:=app_private.require_any_permission(array['customers:view','customers:manage']);
  ids uuid[]; result jsonb; ordering text:=coalesce(p_filters->>'sort','name_asc');
  from_day date:=nullif(p_filters->>'from','')::date; to_day date:=nullif(p_filters->>'to','')::date;
  activity_filter boolean; page_first boolean;
begin
  perform app_private.validate_customer_filters(p_filters);
  if p_offset is null or p_limit is null or p_offset<0 or p_offset>1000000 or p_limit not between 1 and 100 then raise exception 'Invalid customer page'; end if;
  if jsonb_typeof(p_filters->'item_ids')='array' then select coalesce(array_agg(distinct value::uuid),'{}'::uuid[]) into ids from jsonb_array_elements_text(p_filters->'item_ids'); end if;
  activity_filter:=from_day is not null or to_day is not null or ids is not null
    or exists(select 1 from jsonb_each_text(p_filters) f
      where f.key in ('transactions_min','transactions_max','refill_min','refill_max','package_min','package_max') and nullif(f.value,'') is not null);
  -- Only unscoped name ordering can safely select customers before reading sales.
  -- Both paths share one relational sales scope and response shape.
  page_first:=not activity_filter and ordering in ('name_asc','name_desc');
  with candidates as materialized (
    select c.tenant_id,c.customer_id,c.name,c.phone,c.shop_name,c.address,
      case when c.tier='wholesale' then 'wholesale' else 'retail' end tier,c.created_at,
      coalesce(nullif(case when c.tier='wholesale' then c.shop_name end,''),c.name) display_name
    from public.customers c where c.tenant_id=t and (p_customer_id is null or c.customer_id=p_customer_id)
      and (coalesce(p_filters->>'tier','all')='all' or p_filters->>'tier'=case when c.tier='wholesale' then 'wholesale' else 'retail' end)
      and (not exists(select 1 from regexp_split_to_table(coalesce(p_filters->>'search',''),'\s*,\s*') g where btrim(g)<>'')
        or exists(select 1 from regexp_split_to_table(lower(p_filters->>'search'),'\s*,\s*') g where btrim(g)<>'' and not exists(
          select 1 from regexp_split_to_table(btrim(g),'\s+') token where token<>''
          and position(token in lower(concat_ws(' ',c.name,c.shop_name,c.phone,c.address,c.tier,
            case when c.phone like '08801%' then substring(c.phone from 4) else '088'||c.phone end)))=0)))
  ), scoped_customers as materialized (
    select * from candidates order by
      case when page_first and ordering='name_asc' then lower(display_name) end asc,
      case when page_first and ordering='name_desc' then lower(display_name) end desc,customer_id
    limit case when page_first then p_limit end offset case when page_first then p_offset else 0 end
  ), headers as materialized (
    select s.customer_id,s.sale_id,s.created_at,s.total_amount,
      case when s.payment_tracking then greatest(0,s.total_amount-s.paid_amount) else 0 end due
    from public.sales s join scoped_customers c on c.customer_id=s.customer_id
    where s.tenant_id=t and s.status='completed'
      and (from_day is null or s.created_at >= (from_day::timestamp at time zone 'Asia/Dhaka'))
      and (to_day is null or s.created_at < ((to_day+1)::timestamp at time zone 'Asia/Dhaka'))
  ), quantities as (
    select si.sale_id,
      sum(si.quantity) filter(where si.type='refill') refill,
      sum(si.quantity) filter(where si.type='package') package
    from public.sale_items si join headers h on h.sale_id=si.sale_id
    where si.tenant_id=t and si.type in ('refill','package') and (ids is null or si.item_id=any(ids))
    group by si.sale_id
  ), qualifying as (
    select h.*,coalesce(q.refill,0) refill,coalesce(q.package,0) package
    from headers h left join quantities q on q.sale_id=h.sale_id
    where ids is null or q.sale_id is not null
  ), activity as materialized (
    select a.customer_id,count(*) transactions,sum(a.refill) refill,sum(a.package) package,
      sum(a.total_amount) total_sold_amount,sum(a.due) total_due,max(a.created_at) last_transaction_at
    from qualifying a group by a.customer_id
  ), filtered as materialized (
    select c.*,coalesce(a.transactions,0) transactions,coalesce(a.refill,0) refill,coalesce(a.package,0) package,
      coalesce(a.refill,0)+coalesce(a.package,0) total_sold,
      coalesce(a.total_sold_amount,0) total_sold_amount,coalesce(a.total_due,0) total_due,a.last_transaction_at
    from scoped_customers c left join activity a on a.customer_id=c.customer_id
    where (not activity_filter or a.transactions>0)
      and coalesce(a.transactions,0)>=coalesce(nullif(p_filters->>'transactions_min','')::bigint,0)
      and (nullif(p_filters->>'transactions_max','') is null or a.transactions<=(p_filters->>'transactions_max')::bigint)
      and coalesce(a.refill,0)>=coalesce(nullif(p_filters->>'refill_min','')::bigint,0)
      and (nullif(p_filters->>'refill_max','') is null or a.refill<=(p_filters->>'refill_max')::bigint)
      and coalesce(a.package,0)>=coalesce(nullif(p_filters->>'package_min','')::bigint,0)
      and (nullif(p_filters->>'package_max','') is null or a.package<=(p_filters->>'package_max')::bigint)
  ), ranked as (
    select f.*,row_number() over(order by
      case when ordering='name_asc' then lower(display_name) end asc,
      case when ordering='name_desc' then lower(display_name) end desc,
      case when ordering='sold_asc' then total_sold_amount end asc,
      case when ordering='sold_desc' then total_sold_amount end desc,
      case when ordering='due_asc' then total_due end asc,
      case when ordering='due_desc' then total_due end desc,
      case when ordering='last_sale_asc' then last_transaction_at end asc nulls last,
      case when ordering='last_sale_desc' then last_transaction_at end desc nulls last,customer_id) ordinal
    from filtered f
  ), page as (
    select * from ranked order by ordinal limit p_limit offset case when page_first then 0 else p_offset end
  ) select jsonb_build_object('total',case when page_first then (select count(*) from candidates) else (select count(*) from filtered) end,
    'entries',coalesce((select jsonb_agg(to_jsonb(p)-'ordinal' order by ordinal) from page p),'[]'::jsonb)) into result;
  return result;
end $$;

-- CREATE OR REPLACE retains the directory's ownership and authenticated-only grant.
notify pgrst, 'reload schema';
