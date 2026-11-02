-- Directory-only filtering/sorting; source transactions and permissions are unchanged.
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
 if ordering not in ('date_desc','date_asc','amount_desc','amount_asc','due_desc','due_asc','bottles_desc','bottles_asc','customer_asc','customer_desc') or payment not in ('all','unpaid','partial','paid','outstanding') or bottles not in ('all','outstanding','partial','none_received','received') or coalesce(p_filters->>'tier','all') not in ('all','retail','wholesale') or coalesce(p_filters->>'business_category','all') not in ('all','lpg','stove') or from_day>to_day then raise exception 'Invalid sales filter'; end if;
 with headers as materialized (
  select s.sale_id,s.status,s.business_category,s.created_at,s.customer_id,s.sale_tier,s.total_amount original_total,s.additional_charges,s.total_amount+s.additional_charges total_amount,s.paid_amount,case when s.status='voided' then 0 else s.total_amount+s.additional_charges-s.paid_amount end due,(case when s.status='voided' then s.paid_amount-coalesce((select sum(amount) from public.sale_refunds where tenant_id=t and sale_id=s.sale_id),0) else 0 end) refund_due,
   c.name,c.phone,c.shop_name,
   coalesce(q.expected,0) expected,case when s.status='voided' then 0 else greatest(0,coalesce(q.expected,0)-coalesce(q.received,0)) end outstanding_bottles,coalesce(q.received,0) received_bottles
  from public.sales s join public.customers c on c.tenant_id=t and c.customer_id=s.customer_id
  left join lateral (select
   (select coalesce(sum(quantity),0) from public.sale_items where type='empty_return' and tenant_id=t and sale_id=s.sale_id) expected,
   (select coalesce(sum(quantity),0) from public.sale_bottle_receipt_lines where tenant_id=t and sale_id=s.sale_id) received) q on true
  where s.tenant_id=t and (coalesce(p_filters->>'business_category','all')='all' or s.business_category=p_filters->>'business_category') and (coalesce(p_filters->>'status','completed')='all' or s.status=coalesce(p_filters->>'status','completed')::public.sale_status)
   and (from_day is null or s.created_at>=from_day::timestamp at time zone 'Asia/Dhaka') and (to_day is null or s.created_at<(to_day+1)::timestamp at time zone 'Asia/Dhaka')
   and (coalesce(p_filters->>'tier','all')='all' or s.sale_tier=p_filters->>'tier')
   and app_private.finance_search(concat_ws(' ',s.sale_id,c.name,c.phone,c.shop_name,s.sale_tier,s.notes,
    (select string_agg(concat_ws(' ',i.product_name,b.brand_name,case when i.business_category='lpg' then i.size_kg||'kg' end,i.mouth_size,si.type),' ') from public.sale_items si join public.items i on i.tenant_id=t and i.item_id=si.item_id left join public.lpg_brands b on b.tenant_id=t and b.brand_id=i.brand_id where si.tenant_id=t and si.sale_id=s.sale_id)),coalesce(p_filters->>'search',''))
 ), matching as materialized (
  select * from headers where (payment='all' or payment='unpaid' and paid_amount=0 and due>0 or payment='partial' and paid_amount>0 and due>0 or payment='paid' and due=0 or payment='outstanding' and due>0)
   and (bottles='all' or bottles='outstanding' and outstanding_bottles>0 or bottles='partial' and received_bottles>0 and outstanding_bottles>0 or bottles='none_received' and received_bottles=0 and outstanding_bottles>0 or bottles='received' and outstanding_bottles=0)
 ), page as (
  select * from matching order by case when ordering='date_desc' then created_at end desc,case when ordering='date_asc' then created_at end asc,
   case when ordering='amount_desc' then total_amount end desc,case when ordering='amount_asc' then total_amount end asc,
   case when ordering='due_desc' then due end desc,case when ordering='due_asc' then due end asc,case when ordering='bottles_desc' then outstanding_bottles end desc,case when ordering='bottles_asc' then outstanding_bottles end asc,case when ordering='customer_asc' then lower(case when sale_tier='wholesale' then coalesce(nullif(shop_name,''),name) else name end) end asc,case when ordering='customer_desc' then lower(case when sale_tier='wholesale' then coalesce(nullif(shop_name,''),name) else name end) end desc,sale_id desc limit p_limit offset p_offset
 ), details as (
  select p.*,coalesce((select jsonb_agg(jsonb_build_object('item_id',si.item_id,'type',si.type,'quantity',si.quantity,'name',concat_ws(' ',i.product_name,b.brand_name,case when i.business_category='lpg' then i.size_kg||'kg' end,i.mouth_size)) order by si.type,si.item_id)
   from public.sale_items si join public.items i on i.tenant_id=t and i.item_id=si.item_id left join public.lpg_brands b on b.tenant_id=t and b.brand_id=i.brand_id where si.tenant_id=t and si.sale_id=p.sale_id),'[]') items
  from page p
 ) select jsonb_build_object('total',(select count(*) from matching),'entries',coalesce((select jsonb_agg(to_jsonb(d) order by
  case when ordering='date_desc' then created_at end desc,case when ordering='date_asc' then created_at end asc,
  case when ordering='amount_desc' then total_amount end desc,case when ordering='amount_asc' then total_amount end asc,
  case when ordering='due_desc' then due end desc,case when ordering='due_asc' then due end asc,case when ordering='bottles_desc' then outstanding_bottles end desc,case when ordering='bottles_asc' then outstanding_bottles end asc,case when ordering='customer_asc' then lower(case when sale_tier='wholesale' then coalesce(nullif(shop_name,''),name) else name end) end asc,case when ordering='customer_desc' then lower(case when sale_tier='wholesale' then coalesce(nullif(shop_name,''),name) else name end) end desc,sale_id desc) from details d),'[]')) into result;
 return result;
end $$;
CREATE OR REPLACE FUNCTION public.get_purchase_directory(p_filters jsonb DEFAULT '{}'::jsonb, p_offset integer DEFAULT 0, p_limit integer DEFAULT 6) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare t uuid:=app_private.require_any_permission(array['purchases:view','purchases:manage']); result jsonb;
  ordering text:=coalesce(p_filters->>'sort','date_desc'); searching boolean:=false;
begin
  if p_filters is null or jsonb_typeof(p_filters)<>'object' or length(coalesce(p_filters->>'search',''))>500
    or coalesce(p_filters->>'status','all') not in ('all','created','in_transit','received','cancelled','pending_refund','closed')
    or coalesce(p_filters->>'payment','all') not in ('all','unpaid','partial','paid')
    or coalesce(p_filters->>'business_category','all') not in ('all','lpg','stove')
    or ordering not in ('date_desc','date_asc','amount_desc','amount_asc','due_asc','due_desc','supplier_asc','supplier_desc') then raise exception 'Invalid purchase filters'; end if;
  if p_offset is null or p_limit is null or p_offset<0 or p_offset>1000000 or p_limit not between 1 and 100 then raise exception 'Invalid purchase page'; end if;
  searching:=exists(select 1 from regexp_split_to_table(coalesce(p_filters->>'search',''),'\s*,\s*') g where btrim(g)<>'');
  with matching as materialized (
    select p.purchase_id,p.created_at,p.total_cost,case when p.status='cancelled' then 0 else greatest(0,p.payable_amount-p.paid_amount) end due,lower(coalesce(b.brand_name,p.supplier_name,'')) supplier from public.purchases p
    left join public.vehicles tr on tr.tenant_id=t and tr.vehicle_id=p.vehicle_id
    left join public.gas_plants gp on gp.tenant_id=t and gp.plant_id=p.plant_id
    left join public.lpg_brands b on b.tenant_id=t and b.brand_id=p.brand_id
    where p.tenant_id=t and (coalesce(p_filters->>'business_category','all')='all' or p.business_category=p_filters->>'business_category')
      and (coalesce(p_filters->>'status','all')='all' or p.status::text=p_filters->>'status' or p_filters->>'status'='pending_refund' and p.status='cancelled' and p.financial_closed_at is null or p_filters->>'status'='closed' and p.status='cancelled' and p.financial_closed_at is not null)
      and (coalesce(p_filters->>'payment','all')='all' or p.payment_status=p_filters->>'payment')
      and (nullif(p_filters->>'from','') is null or p.created_at >= (nullif(p_filters->>'from','')::date::timestamp at time zone 'Asia/Dhaka'))
      and (nullif(p_filters->>'to','') is null or p.created_at < ((nullif(p_filters->>'to','')::date+1)::timestamp at time zone 'Asia/Dhaka'))
      and (not searching or exists(
        select 1 from (select lower(concat_ws(' ',p.purchase_id,p.supplier_name,b.brand_name,gp.plant_name,tr.name,p.notes,p.receipt_notes,p.status,p.payment_status,
          (select string_agg(concat_ws(' ',i.product_name,lb.brand_name,trim_scale(i.size_kg)||'kg',trim_scale(i.size_kg)||' kg',i.mouth_size,
            case when pi.type='refill' then 'refill exchange' else 'package new cylinders' end),' ')
          from public.purchase_items pi join public.items i on i.tenant_id=pi.tenant_id and i.item_id=pi.item_id
          left join public.lpg_brands lb on lb.tenant_id=i.tenant_id and lb.brand_id=i.brand_id where pi.tenant_id=t and pi.purchase_id=p.purchase_id))) text) document
        where exists(select 1 from regexp_split_to_table(lower(p_filters->>'search'),'\s*,\s*') g where btrim(g)<>'' and not exists(
          select 1 from regexp_split_to_table(btrim(g),'\s+') token where token<>'' and position(token in document.text)=0))))
  ), page as materialized (
    select * from matching order by
      case when ordering='date_desc' then created_at end desc,case when ordering='date_asc' then created_at end asc,
      case when ordering='amount_desc' then total_cost end desc,case when ordering='amount_asc' then total_cost end asc,
      case when ordering='due_asc' then due end asc,case when ordering='due_desc' then due end desc,
      case when ordering='supplier_asc' then supplier end asc,case when ordering='supplier_desc' then supplier end desc,purchase_id
    limit p_limit offset p_offset
  ), details as (
    select r.* from app_private.purchase_rows(t,coalesce((select array_agg(purchase_id) from page),'{}'::uuid[])) r
  ) select jsonb_build_object('total',(select count(*) from matching),'entries',coalesce((select jsonb_agg(d.r order by
    case when ordering='date_desc' then p.created_at end desc,case when ordering='date_asc' then p.created_at end asc,
    case when ordering='amount_desc' then p.total_cost end desc,case when ordering='amount_asc' then p.total_cost end asc,
    case when ordering='due_asc' then p.due end asc,case when ordering='due_desc' then p.due end desc,
    case when ordering='supplier_asc' then p.supplier end asc,case when ordering='supplier_desc' then p.supplier end desc,p.purchase_id)
    from details d(r) join page p on p.purchase_id=(d.r->>'purchase_id')::uuid),'[]'::jsonb)) into result;
  return result;
end $$;

create or replace function public.get_employee_directory(p_filters jsonb default '{}',p_offset integer default 0,p_limit integer default 25) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['employees:view','employees:manage','payroll:view','payroll:pay']); result jsonb;
 sorting text:=coalesce(p_filters->>'sort','name_asc');
begin
 if p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100 or length(coalesce(p_filters->>'search',''))>500
 or sorting not in ('name_asc','name_desc','salary_desc','salary_asc','joined_desc','joined_asc')
 or coalesce(p_filters->>'status','all') not in ('all','active','inactive')
 or coalesce(p_filters->>'unit','all') not in ('all','gas_business','truck_business') then raise exception 'Invalid employee filters or page'; end if;
 with profiles as materialized(select app_private.employee_summary(t,employee_id) row from public.employees where tenant_id=t),
 matching as materialized(select row from profiles
 where (coalesce(p_filters->>'status','all')='all' or (row->>'is_active')::boolean=(p_filters->>'status'='active'))
 and (coalesce(p_filters->>'unit','all')='all' or row->>'business_unit'=p_filters->>'unit')
 and (nullif(p_filters->>'type','') is null or row->>'employee_type_name'=p_filters->>'type')
 and app_private.employee_search(concat_ws(' ',row->>'name',row->>'address',row->>'employee_type_name',row->'phones',row->>'notes'),p_filters->>'search')),
 page as(select row from matching order by
 case when sorting='name_asc' then lower(row->>'name') end asc,
 case when sorting='name_desc' then lower(row->>'name') end desc,
 case when sorting='salary_desc' then (row->>'current_salary')::numeric end desc,
 case when sorting='salary_asc' then (row->>'current_salary')::numeric end asc,
 case when sorting='joined_asc' then row->>'joining_date' end asc,
 case when sorting='joined_desc' then row->>'joining_date' end desc,row->>'name',row->>'employee_id' offset p_offset limit p_limit)
 select jsonb_build_object('entries',coalesce((select jsonb_agg(row) from page),'[]'),'total',(select count(*) from matching)) into result;
 return result;
end $$;
