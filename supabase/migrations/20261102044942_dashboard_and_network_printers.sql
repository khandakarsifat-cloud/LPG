-- Dashboard reads use one statement snapshot and the business clock, never a browser cutoff.
alter table public.items add column low_stock_threshold integer not null default 5
 check (low_stock_threshold between 0 and 1000000);
create index dashboard_payment_time on public.sale_payments(tenant_id,created_at desc,payment_id);
create index dashboard_purchase_activity on public.purchase_activity(tenant_id,created_at desc,activity_id);
create index dashboard_financial_activity on public.financial_entries(tenant_id,created_at desc,entry_id);
create index inventory_below_threshold on public.items(tenant_id,item_id)
 where filled_quantity < low_stock_threshold;
create index dashboard_bottle_expectations on public.sale_items(tenant_id,sale_id) include(quantity) where type='empty_return';

create function app_private.printer_lan_address(ip text) returns boolean language plpgsql immutable strict set search_path='' as $$
begin
 return ip=host(ip::inet) and family(ip::inet)=4 and
  (ip::inet <<= '10.0.0.0/8'::inet or ip::inet <<= '172.16.0.0/12'::inet or ip::inet <<= '192.168.0.0/16'::inet);
exception when invalid_text_representation then return false;
end $$;
grant execute on function app_private.printer_lan_address(text) to authenticated;
alter table public.receipt_printers drop constraint receipt_printer_identity;
alter table public.receipt_printers add constraint receipt_printer_identity check (
 jsonb_typeof(printer)='object' and
 coalesce(length(printer->>'queue_id') between 1 and 200,false) and
 coalesce(length(printer->>'host_id') between 1 and 200,false) and
 coalesce(length(printer->>'queue_name') between 1 and 500,false) and
 coalesce(length(printer->>'port_name') between 1 and 500,false) and
 (printer->>'transport'='windows_usb' or
  (printer->>'transport'='network_tcp' and printer->>'protocol'='escpos' and
   coalesce(app_private.printer_lan_address(printer->>'ip_address'),false) and
   coalesce(jsonb_typeof(printer->'port')='number' and (printer->>'port')::numeric between 1024 and 65535 and mod((printer->>'port')::numeric,1)=0,false))) is true
);

create function public.get_stock_alerts(p_only_low boolean default true,p_search text default '',p_offset integer default 0,p_limit integer default 20)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['inventory:view','inventory:manage']);r jsonb;
begin
 if p_offset<0 or p_limit not between 1 and 50 or length(p_search)>200 then raise exception 'Invalid stock page';end if;
 with products as materialized(
  select i.item_id,i.business_category,i.filled_quantity,i.low_stock_threshold,
   coalesce(i.product_name,b.brand_name||' '||i.size_kg||' kg '||coalesce(i.mouth_size::text,'')) name
  from public.items i left join public.lpg_brands b using(tenant_id,brand_id)
  where i.tenant_id=t and (not p_only_low or i.filled_quantity<i.low_stock_threshold)
  and (p_search='' or concat_ws(' ',i.product_name,b.brand_name,i.size_kg,i.mouth_size) ilike '%'||p_search||'%'))
 select jsonb_build_object('total',(select count(*) from products),'entries',coalesce((select jsonb_agg(p) from
  (select * from products order by name,item_id offset p_offset limit p_limit)p),'[]')) into r;return r;
end $$;
create function public.set_stock_threshold(p_item_id uuid,p_threshold integer,p_expected integer) returns void
language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('inventory:manage');begin
 if p_threshold is null or p_threshold not between 0 and 1000000 then raise exception 'Threshold must be between 0 and 1000000';end if;
 update public.items set low_stock_threshold=p_threshold where tenant_id=t and item_id=p_item_id and low_stock_threshold=p_expected;
 if not found then raise exception 'Product or threshold changed. Refresh before saving.';end if;
end $$;

create function public.get_dashboard_activity(p_offset integer default 0,p_limit integer default 6) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('dashboard:view');r jsonb;n integer;
begin
 if p_offset<0 or p_offset>10000 or p_limit not between 1 and 30 then raise exception 'Invalid activity page';end if;
 n:=p_offset+p_limit+1;
 with events as (
 (select 'sale:'||s.sale_id id,'sale' kind,s.sale_id record_id,'sale' record_kind,
  case when s.status='completed' then 'POS sale' else 'Sale (cancelled)' end title,
  coalesce(c.shop_name,c.name,'Customer') description,s.total_amount+s.additional_charges amount,s.created_at
  from public.sales s left join public.customers c using(tenant_id,customer_id) where s.tenant_id=t
  order by s.created_at desc,s.sale_id desc limit n)
 union all
 (select 'purchase:'||a.activity_id,'purchase',a.purchase_id,'purchase',
  'Purchase · '||replace(a.action,'_',' '),coalesce(p.supplier_name,g.plant_name,'Purchase'),null::numeric,a.created_at
  from public.purchase_activity a join public.purchases p using(tenant_id,purchase_id) left join public.gas_plants g on g.tenant_id=p.tenant_id and g.plant_id=p.plant_id
  where a.tenant_id=t and app_private.has_any_permission(array['purchases:view','purchases:manage'])
  order by a.created_at desc,a.activity_id desc limit n)
 union all
 (select 'payment:'||p.payment_id,'payment',p.sale_id,'sale','Customer payment',coalesce(c.shop_name,c.name,'Customer')||' · '||p.wallet_name,p.amount,p.created_at
  from public.sale_payments p join public.sales s using(tenant_id,sale_id) left join public.customers c using(tenant_id,customer_id)
  where p.tenant_id=t and p.phase='collection' and app_private.has_any_permission(array['sales:view','finance:view','finance:manage'])
  order by p.created_at desc,p.payment_id desc limit n)
 union all
 (select 'entry:'||e.entry_id,'financial_entry',e.entry_id,'financial_entry','Financial entry · '||e.type_name,e.description,e.amount,e.created_at
  from public.financial_entries e where e.tenant_id=t and app_private.has_any_permission(array['finance:view','finance:manage'])
  order by e.created_at desc,e.entry_id desc limit n)
 union all
 (select 'cancel:'||j.journal_id,'sale',j.source_id,'sale','Sale cancelled',j.description,null::numeric,j.created_at
  from public.accounting_journals j where j.tenant_id=t and j.source='sale_reversal'
  order by j.created_at desc,j.journal_id desc limit n)
 ), page as materialized(select * from events order by created_at desc,id desc offset p_offset limit p_limit+1)
 select jsonb_build_object('hasMore',(select count(*)>p_limit from page),'entries',coalesce((select jsonb_agg(p) from
  (select * from page order by created_at desc,id desc limit p_limit)p),'[]')) into r;return r;
end $$;

create function app_private.dashboard_snapshot(t uuid) returns jsonb language plpgsql stable set search_path='' as $$
declare d date:=(now() at time zone 'Asia/Dhaka')::date;r jsonb;
 finance boolean:=app_private.has_any_permission(array['finance:view','finance:manage']);
 customers boolean:=app_private.has_any_permission(array['customers:view','customers:manage']);
 inventory boolean:=app_private.has_any_permission(array['inventory:view','inventory:manage']);
begin
 with days as (select generate_series(d-6,d,interval '1 day')::date business_day),
 recognition as materialized(
  select j.occurred_on business_day,
   coalesce(-sum(l.consolidated_amount) filter(where case when finance then a.kind='income' else l.account='sales_revenue' end),0) revenue,
   case when finance then coalesce(sum(l.consolidated_amount) filter(where a.kind='expense'),0) end expense
  from public.accounting_journals j join public.accounting_lines l using(tenant_id,journal_id) join public.accounting_accounts a on a.code=l.account
  where j.tenant_id=t and j.occurred_on between d-6 and d and not j.is_opening group by j.occurred_on),
 collections as (select (p.created_at at time zone 'Asia/Dhaka')::date business_day,sum(p.amount) collected
  from public.sale_payments p where p.tenant_id=t and p.created_at >= (d-6)::timestamp at time zone 'Asia/Dhaka'
  and p.created_at < (d+1)::timestamp at time zone 'Asia/Dhaka' group by 1),
 sale_counts as (select (s.created_at at time zone 'Asia/Dhaka')::date business_day,count(*) sales
  from public.sales s where s.tenant_id=t and s.status='completed' and s.created_at >= (d-6)::timestamp at time zone 'Asia/Dhaka'
  and s.created_at < (d+1)::timestamp at time zone 'Asia/Dhaka' group by 1),
 today_sales as materialized(select s.* from public.sales s where s.tenant_id=t and s.status='completed'
  and s.created_at>=d::timestamp at time zone 'Asia/Dhaka' and s.created_at<(d+1)::timestamp at time zone 'Asia/Dhaka'),
 sold as materialized(select i.item_id,i.size_kg,i.business_category,i.product_name,i.image_url,sum(si.quantity) quantity
  from today_sales s join public.sale_items si using(tenant_id,sale_id) join public.items i using(tenant_id,item_id)
  where si.type in ('refill','package') group by i.item_id,i.size_kg,i.business_category,i.product_name,i.image_url),
 expected as (select si.sale_id,sum(si.quantity) quantity from public.sale_items si where customers and si.tenant_id=t and si.type='empty_return' group by si.sale_id),
 received as (select b.sale_id,sum(b.quantity) quantity from public.sale_bottle_receipt_lines b where customers and b.tenant_id=t group by b.sale_id),
 bottle_due as materialized(select s.customer_id,greatest(0,e.quantity-coalesce(b.quantity,0)) quantity
  from expected e join public.sales s on s.tenant_id=t and s.sale_id=e.sale_id left join received b on b.sale_id=e.sale_id where s.status='completed'),
 weights as (select size_kg from public.business_weights where tenant_id=t and is_active
  union select size_kg from sold where business_category='lpg')
 select jsonb_build_object('date',d,'generated_at',now(),'finance_visible',finance,
 'days',(select jsonb_agg(jsonb_build_object('date',days.business_day,'revenue',coalesce(x.revenue,0),'expense',case when finance then coalesce(x.expense,0) end,
  'collected',coalesce(c.collected,0),'sales',coalesce(s.sales,0)) order by days.business_day) from days left join recognition x using(business_day) left join collections c using(business_day) left join sale_counts s using(business_day)),
 'bottles',coalesce((select jsonb_agg(jsonb_build_object('size_kg',w.size_kg,'quantity',coalesce((select sum(quantity) from sold where business_category='lpg' and size_kg=w.size_kg),0)) order by w.size_kg) from weights w),'[]'),
 'products',coalesce((select jsonb_agg(jsonb_build_object('item_id',item_id,'name',product_name,'image_url',image_url,'quantity',quantity) order by quantity desc,product_name,item_id) from sold where business_category='stove'),'[]'),
 'attention',jsonb_build_object(
  'customer_due',case when customers then (select coalesce(sum(total_due),0) from app_private.customer_metrics where tenant_id=t and total_due>0) end,
  'customers',case when customers then (select count(*) from app_private.customer_metrics where tenant_id=t and total_due>0) end,
  'bottles',case when customers then (select coalesce(sum(quantity),0) from bottle_due) end,
  'bottle_customers',case when customers then (select count(distinct customer_id) from bottle_due where quantity>0) end,
  'low_stock',case when inventory then (select count(*) from public.items where tenant_id=t and filled_quantity<low_stock_threshold) end),
 'sales',coalesce((select jsonb_agg(x order by x.created_at desc,x.sale_id desc) from (
  select s.sale_id,s.created_at,s.total_amount+s.additional_charges amount,coalesce(c.shop_name,c.name,'Customer') customer,
   (select string_agg(coalesce(i.product_name,'LPG '||i.size_kg||' kg')||' × '||si.quantity||case when si.type='package' then ' (Package)' else '' end,', ' order by si.item_id,si.type)
    from public.sale_items si join public.items i using(tenant_id,item_id) where si.tenant_id=t and si.sale_id=s.sale_id and si.type<>'empty_return') items
  from today_sales s left join public.customers c using(tenant_id,customer_id) order by s.created_at desc,s.sale_id desc limit 5)x),'[]'),
 'activity',public.get_dashboard_activity(0,6)) into r;
 return r;
end $$;

-- Match Finance's existing monthly accrual preparation before the stable snapshot.
-- The established sync skips an already-current payroll month. No synthetic reporting entries.
create function public.get_dashboard_snapshot() returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('dashboard:view');begin
 if app_private.has_any_permission(array['finance:view','finance:manage']) then perform app_private.sync_payroll(t);end if;
 return app_private.dashboard_snapshot(t);
end $$;
revoke all on function app_private.dashboard_snapshot(uuid) from public,anon,authenticated;
drop function public.get_dashboard_stats(timestamptz);

revoke all on function public.get_dashboard_snapshot(),public.get_dashboard_activity(integer,integer),public.get_stock_alerts(boolean,text,integer,integer),public.set_stock_threshold(uuid,integer,integer) from public,anon;
grant execute on function public.get_dashboard_snapshot(),public.get_dashboard_activity(integer,integer),public.get_stock_alerts(boolean,text,integer,integer),public.set_stock_threshold(uuid,integer,integer) to authenticated;
notify pgrst,'reload schema';

