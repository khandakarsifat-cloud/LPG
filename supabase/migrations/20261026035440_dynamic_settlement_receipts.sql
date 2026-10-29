-- Preserve original invoices, payments, physical receipts and historical expenses.
-- New customer settlement costs reuse receipt.fee and sales.additional_charges.
create or replace function app_private.receive_sale_bottles(t uuid,sid uuid,body jsonb,phase text,op uuid) returns uuid
language plpgsql set search_path='' as $$
declare s public.sales; x jsonb; rid uuid; qty integer; expected bigint; received bigint; incoming bigint:=0;
 original bigint; previous bigint; note text:=btrim(coalesce(body->>'note',''));
begin
 select * into s from public.sales where tenant_id=t and sale_id=sid for update;
 if not found or not s.bottle_tracking or s.status<>'completed' then raise exception 'Sale does not support bottle collection'; end if;
 if body is null or jsonb_typeof(body)<>'object' or jsonb_typeof(body->'lines') is distinct from 'array' or jsonb_array_length(body->'lines')>200 then raise exception 'Use up to 200 received products'; end if;
 if length(note)>1000 then raise exception 'Bottle note is too long'; end if;
 if coalesce(body->'payments','[]')<>'[]'::jsonb then raise exception 'Use the separate customer payment collection action'; end if;
 if coalesce((body->>'expense')::numeric,0)<>0 or nullif(body->>'expense_wallet_id','') is not null then raise exception 'Refresh the app. Collection expenses have been replaced by customer settlement costs'; end if;
 if phase='checkout' and coalesce((body->>'fee')::numeric,0)<>0 then raise exception 'Use the checkout exchange cost field'; end if;
 if exists(select 1 from jsonb_array_elements(body->'lines') l group by l->>'received_item_id' having count(*)>1) then raise exception 'Use one quantity per received product'; end if;
 select coalesce(sum(expected_quantity),0) into expected from public.sale_bottle_obligations where tenant_id=t and sale_id=sid;
 select coalesce(sum(quantity),0) into received from public.sale_bottle_receipt_lines where tenant_id=t and sale_id=sid;
 for x in select value from jsonb_array_elements(body->'lines') loop
  qty:=app_private.purchase_integer(x->'quantity');
  if qty<=0 then raise exception 'Received quantities must be positive whole numbers'; end if;
  incoming:=incoming+qty;
 end loop;
 if phase='collection' and incoming=0 then raise exception 'Add at least one received bottle'; end if;
 if phase='collection' and received>=expected then raise exception 'Bottle obligation is already settled'; end if;
 if expected=0 and incoming>0 then raise exception 'Sale has no bottle obligation'; end if;
 -- Keep actual quantities uncapped. Product acknowledgements below cover excess.
 -- Same lock order as checkout/purchases: sale, actual products.
 perform 1 from public.items where tenant_id=t and item_id in(select (l->>'received_item_id')::uuid from jsonb_array_elements(body->'lines') l) order by item_id for update;
 for x in select value from jsonb_array_elements(body->'lines') loop
  if not exists(select 1 from public.items where tenant_id=t and item_id=(x->>'received_item_id')::uuid) then raise exception 'Received product not found in this business'; end if;
  select coalesce(sum(expected_quantity),0) into original from public.sale_bottle_obligations where tenant_id=t and sale_id=sid and item_id=(x->>'received_item_id')::uuid;
  select coalesce(sum(quantity),0) into previous from public.sale_bottle_receipt_lines where tenant_id=t and sale_id=sid and received_item_id=(x->>'received_item_id')::uuid;
  if (original=0 or previous+(x->>'quantity')::integer>original) and coalesce((x->>'acknowledged')::boolean,false) is not true then raise exception 'Acknowledge unexpected products or receipts exceeding the original product quantity'; end if;
 end loop;
 insert into public.sale_bottle_receipts(tenant_id,sale_id,phase,operation_id,note,created_by,fee)
 values(t,sid,phase,op,note,auth.uid(),coalesce((body->>'fee')::numeric,0)) returning receipt_id into rid;
 for x in select value from jsonb_array_elements(body->'lines') loop
  qty:=app_private.purchase_integer(x->'quantity');
  insert into public.sale_bottle_receipt_lines(tenant_id,receipt_id,sale_id,received_item_id,quantity,acknowledged)
  values(t,rid,sid,(x->>'received_item_id')::uuid,qty,coalesce((x->>'acknowledged')::boolean,false));
  insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,filled_quantity_change,empty_quantity_change,notes,created_by)
  values(t,(x->>'received_item_id')::uuid,'sale','sale',sid,0,qty,'Bottle '||phase||' #'||rid::text||case when note='' then '' else ': '||note end,auth.uid());
 end loop;
 return rid;
end $$;


create or replace function public.collect_sale_bottles(p_sale_id uuid,p_payload jsonb,p_request_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('sales:collect_bottles'); prior public.finance_requests;
 payload jsonb; s public.sales; rid uuid; cost numeric; result jsonb;
begin
 if p_request_id is null then raise exception 'Bottle request ID is required'; end if;
 payload:=jsonb_build_object('action','bottles','sale',p_sale_id,'body',p_payload,'actor',auth.uid());
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 -- Replay completed historical expense/fee operations without reinterpreting them.
 if found then
  if prior.payload is distinct from payload then raise exception 'Request ID already used with different details'; end if;
  return prior.result;
 end if;
 if p_payload is null or jsonb_typeof(p_payload)<>'object' then raise exception 'Invalid bottle collection'; end if;
 if p_payload ? 'fee' and jsonb_typeof(p_payload->'fee')<>'number' then raise exception 'Settlement cost must be a finite number'; end if;
 cost:=app_private.purchase_money(coalesce((p_payload->>'fee')::numeric,0));
 if cost<>coalesce((p_payload->>'fee')::numeric,0) then raise exception 'Settlement cost must have at most two decimal places'; end if;
 if cost>0 then perform app_private.require_permission('finance:manage'); end if;
 select * into s from public.sales where tenant_id=t and sale_id=p_sale_id for update;
 if not found or not s.bottle_tracking then raise exception 'Sale does not support bottle collection'; end if;
 rid:=app_private.receive_sale_bottles(t,p_sale_id,p_payload,'collection',p_request_id);
 if cost>0 then
  -- Reuse the existing later exchange-charge mechanism. No money is received yet.
  update public.sales set additional_charges=additional_charges+cost where tenant_id=t and sale_id=p_sale_id;
  insert into public.customer_transactions(tenant_id,customer_id,type,amount,reference_id,created_by)
   values(t,s.customer_id,'invoice_charge',-cost,p_sale_id,auth.uid());
 end if;
 select jsonb_build_object('sale_id',sale_id,'receipt_id',rid,'fee',cost,'due',total_amount+additional_charges-paid_amount)
 into result from public.sales where tenant_id=t and sale_id=p_sale_id;
 insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,payload,result,auth.uid());
 return result;
end $$;

create or replace function public.get_sale_bottles(p_sale_id uuid,p_offset integer default 0,p_limit integer default 10) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['sales:view','receipts:print','dashboard:view','sales:collect_bottles']); s public.sales; result jsonb;
begin
 if p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid bottle history page'; end if;
 select * into s from public.sales where tenant_id=t and sale_id=p_sale_id;
 if not found then raise exception 'Sale not found'; end if;
 with obligations as materialized (
  select o.item_id,concat_ws(' ',coalesce(b.brand_name,i.brand),i.size_kg||'kg',i.mouth_size) name,i.size_kg,i.mouth_size,o.expected_quantity expected,
    coalesce(sum(l.quantity),0) received,o.expected_quantity-coalesce(sum(l.quantity),0) difference
  from public.sale_bottle_obligations o join public.items i on i.tenant_id=t and i.item_id=o.item_id
  left join public.lpg_brands b on b.tenant_id=t and b.brand_id=i.brand_id
  left join public.sale_bottle_receipt_lines l on l.tenant_id=t and l.sale_id=o.sale_id and l.received_item_id=o.item_id
  where o.tenant_id=t and o.sale_id=p_sale_id group by o.item_id,o.expected_quantity,i.brand,i.size_kg,i.mouth_size,b.brand_name
 ), actual as materialized (
  select r.phase,l.received_item_id item_id,concat_ws(' ',coalesce(b.brand_name,i.brand),i.size_kg||'kg',i.mouth_size) name,sum(l.quantity) quantity
  from public.sale_bottle_receipts r join public.sale_bottle_receipt_lines l on l.tenant_id=t and l.receipt_id=r.receipt_id
  join public.items i on i.tenant_id=t and i.item_id=l.received_item_id left join public.lpg_brands b on b.tenant_id=t and b.brand_id=i.brand_id
  where r.tenant_id=t and r.sale_id=p_sale_id group by r.phase,l.received_item_id,b.brand_name,i.brand,i.size_kg,i.mouth_size
 ), events as materialized (
  select r.receipt_id id,r.created_at,'bottles' kind,r.phase,r.note,r.fee amount,r.expense,r.expense_wallet_name,coalesce(u.full_name,u.email,'Operator') actor,
   coalesce((select jsonb_agg(jsonb_build_object('expected_item_id',l.expected_item_id,'received_item_id',l.received_item_id,'quantity',l.quantity,'allow_incompatible',l.allow_incompatible,'acknowledged',l.acknowledged,
     'expected_name',concat_ws(' ',coalesce(eb.brand_name,ei.brand),ei.size_kg||'kg',ei.mouth_size),
     'received_name',concat_ws(' ',coalesce(rb.brand_name,ri.brand),ri.size_kg||'kg',ri.mouth_size)) order by l.line_id)
    from public.sale_bottle_receipt_lines l left join public.items ei on ei.tenant_id=t and ei.item_id=l.expected_item_id
    join public.items ri on ri.tenant_id=t and ri.item_id=l.received_item_id
    left join public.lpg_brands eb on eb.tenant_id=t and eb.brand_id=ei.brand_id left join public.lpg_brands rb on rb.tenant_id=t and rb.brand_id=ri.brand_id
    where l.tenant_id=t and l.receipt_id=r.receipt_id),'[]') lines
  from public.sale_bottle_receipts r left join public.user_profiles u on u.tenant_id=t and u.user_id=r.created_by where r.tenant_id=t and r.sale_id=p_sale_id
  union all
  select s.sale_id,s.created_at,'sale','checkout',coalesce(s.notes,''),s.total_amount,0::numeric,null::text,coalesce(u.full_name,u.email,'Operator'),'[]'::jsonb
  from public.user_profiles u where u.tenant_id=t and u.user_id=s.created_by
  union all
  select p.payment_id,p.created_at,'payment',p.phase,concat_ws(' · ',p.wallet_name,nullif(p.reference,'')),p.amount,0::numeric,null::text,coalesce(u.full_name,u.email,'Operator'),'[]'::jsonb
  from public.sale_payments p left join public.user_profiles u on u.tenant_id=t and u.user_id=p.created_by where p.tenant_id=t and p.sale_id=p_sale_id
 ), page as (select * from events order by created_at desc,id desc limit p_limit offset p_offset)
 select jsonb_build_object('tracking',s.bottle_tracking,'expected',coalesce((select sum(expected) from obligations),0),
  'received',coalesce((select sum(quantity) from actual),0),'outstanding',greatest(0,coalesce((select sum(expected) from obligations),0)-coalesce((select sum(quantity) from actual),0)),
  'obligations',coalesce((select jsonb_agg(to_jsonb(o) order by name,item_id) from obligations o),'[]'),
  'actual',coalesce((select jsonb_agg(to_jsonb(a) order by phase,name,item_id) from actual a),'[]'),
  'event_count',(select count(*) from events),'events',coalesce((select jsonb_agg(to_jsonb(p) order by created_at desc,id desc) from page p),'[]')) into result;
 return result;
end $$;

create or replace function public.get_sales_overview() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('sales:view'); result jsonb;
begin
 select jsonb_build_object('total',count(*),'amount',coalesce(sum(total_amount+additional_charges),0),'due',coalesce(sum(total_amount+additional_charges-paid_amount),0),
 'bottles',coalesce((select sum(greatest(0,
   (select coalesce(sum(expected_quantity),0) from public.sale_bottle_obligations where tenant_id=t and sale_id=s.sale_id)-
   (select coalesce(sum(quantity),0) from public.sale_bottle_receipt_lines where tenant_id=t and sale_id=s.sale_id)))
   from public.sales s where tenant_id=t and status='completed'),0)) into result from public.sales where tenant_id=t and status='completed';
 return result;
end $$;

create or replace function public.get_sales_directory(p_filters jsonb default '{}',p_offset integer default 0,p_limit integer default 25) returns jsonb
language plpgsql stable security definer set search_path='' set plan_cache_mode='force_custom_plan' as $$
declare t uuid:=app_private.require_permission('sales:view'); result jsonb; ordering text:=coalesce(p_filters->>'sort','date_desc');
 payment text:=coalesce(p_filters->>'payment','all'); bottles text:=coalesce(p_filters->>'bottles','all');
 from_day date:=nullif(p_filters->>'from','')::date; to_day date:=nullif(p_filters->>'to','')::date;
begin
 if p_filters is null or jsonb_typeof(p_filters)<>'object' or length(coalesce(p_filters->>'search',''))>500 or p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid sales page'; end if;
 if ordering not in ('date_desc','date_asc','amount_desc','amount_asc','due_desc','bottles_desc') or payment not in ('all','unpaid','partial','paid','outstanding') or bottles not in ('all','outstanding','partial','none_received','received','legacy') or coalesce(p_filters->>'tier','all') not in ('all','retail','wholesale') or from_day>to_day then raise exception 'Invalid sales filter'; end if;
 with headers as materialized (
  select s.sale_id,s.created_at,s.customer_id,s.sale_tier,s.total_amount original_total,s.additional_charges,s.total_amount+s.additional_charges total_amount,s.paid_amount,s.total_amount+s.additional_charges-s.paid_amount due,s.bottle_tracking,
   c.name,c.phone,c.shop_name,
   coalesce(q.expected,0) expected,greatest(0,coalesce(q.expected,0)-coalesce(q.received,0)) outstanding_bottles,coalesce(q.received,0) received_bottles
  from public.sales s join public.customers c on c.tenant_id=t and c.customer_id=s.customer_id
  left join lateral (select
   (select coalesce(sum(expected_quantity),0) from public.sale_bottle_obligations where tenant_id=t and sale_id=s.sale_id) expected,
   (select coalesce(sum(quantity),0) from public.sale_bottle_receipt_lines where tenant_id=t and sale_id=s.sale_id) received) q on true
  where s.tenant_id=t and s.status='completed'
   and (from_day is null or s.created_at>=from_day::timestamp at time zone 'Asia/Dhaka') and (to_day is null or s.created_at<(to_day+1)::timestamp at time zone 'Asia/Dhaka')
   and (coalesce(p_filters->>'tier','all')='all' or s.sale_tier=p_filters->>'tier')
   and app_private.finance_search(concat_ws(' ',s.sale_id,c.name,c.phone,c.shop_name,s.sale_tier,s.notes,
    (select string_agg(concat_ws(' ',i.brand,b.brand_name,i.size_kg||'kg',i.mouth_size,si.type),' ') from public.sale_items si join public.items i on i.tenant_id=t and i.item_id=si.item_id left join public.lpg_brands b on b.tenant_id=t and b.brand_id=i.brand_id where si.tenant_id=t and si.sale_id=s.sale_id)),coalesce(p_filters->>'search',''))
 ), matching as materialized (
  select * from headers where (payment='all' or payment='unpaid' and paid_amount=0 and due>0 or payment='partial' and paid_amount>0 and due>0 or payment='paid' and due=0 or payment='outstanding' and due>0)
   and (bottles='all' or bottles='outstanding' and outstanding_bottles>0 or bottles='partial' and received_bottles>0 and outstanding_bottles>0 or bottles='none_received' and received_bottles=0 and outstanding_bottles>0 or bottles='received' and bottle_tracking and outstanding_bottles=0 or bottles='legacy' and not bottle_tracking)
 ), page as (
  select * from matching order by case when ordering='date_desc' then created_at end desc,case when ordering='date_asc' then created_at end asc,
   case when ordering='amount_desc' then total_amount end desc,case when ordering='amount_asc' then total_amount end asc,
   case when ordering='due_desc' then due end desc,case when ordering='bottles_desc' then outstanding_bottles end desc,sale_id desc limit p_limit offset p_offset
 ), details as (
  select p.*,coalesce((select jsonb_agg(jsonb_build_object('item_id',si.item_id,'type',si.type,'quantity',si.quantity,'name',concat_ws(' ',coalesce(b.brand_name,i.brand),i.size_kg||'kg',i.mouth_size)) order by si.type,si.item_id)
   from public.sale_items si join public.items i on i.tenant_id=t and i.item_id=si.item_id left join public.lpg_brands b on b.tenant_id=t and b.brand_id=i.brand_id where si.tenant_id=t and si.sale_id=p.sale_id),'[]') items,
   -- Empty compatibility field for older directory readers; no product debts.
   '[]'::jsonb bottle_dues
  from page p
 ) select jsonb_build_object('total',(select count(*) from matching),'entries',coalesce((select jsonb_agg(to_jsonb(d) order by
  case when ordering='date_desc' then created_at end desc,case when ordering='date_asc' then created_at end asc,
  case when ordering='amount_desc' then total_amount end desc,case when ordering='amount_asc' then total_amount end asc,
  case when ordering='due_desc' then due end desc,case when ordering='bottles_desc' then outstanding_bottles end desc,sale_id desc) from details d),'[]')) into result;
 return result;
end $$;

create or replace function public.get_customer_bottle_balance(p_customer_id uuid) returns bigint
language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['customers:view','customers:manage','finance:view','finance:manage']); result bigint;
begin
 if not exists(select 1 from public.customers where tenant_id=t and customer_id=p_customer_id) then raise exception 'Customer not found'; end if;
 select coalesce(sum(greatest(0,
 (select coalesce(sum(expected_quantity),0) from public.sale_bottle_obligations where tenant_id=t and sale_id=s.sale_id)-
 (select coalesce(sum(quantity),0) from public.sale_bottle_receipt_lines where tenant_id=t and sale_id=s.sale_id))),0) into result
 from public.sales s where s.tenant_id=t and s.customer_id=p_customer_id;
 return result;
end $$;

-- One statement snapshot for preview, checkout printing and every reprint.
-- No receipt content is stored; mutable identity comes from current tenant records.
create function public.get_sale_receipt(p_sale_id uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('receipts:print'); result jsonb;
begin
 select jsonb_build_object(
  'shop_name',business.business_name,
  'sale',jsonb_build_object('sale_id',s.sale_id,'created_at',s.created_at,'sale_tier',s.sale_tier,
   'subtotal',s.subtotal,'discount_amount',s.discount_amount,'exchange_fee',s.exchange_fee,'total_amount',s.total_amount,'notes',s.notes,
   'customers',jsonb_build_object('name',c.name,'phone',c.phone),
   'sale_items',coalesce((select jsonb_agg(jsonb_build_object('item_id',si.item_id,'type',si.type,'quantity',si.quantity,
    'unit_price',si.unit_price,'line_total',si.line_total,'items',jsonb_build_object('item_id',i.item_id,'brand_id',i.brand_id,
    'brand',i.brand,'size_kg',i.size_kg,'mouth_size',i.mouth_size,'lpg_brands',jsonb_build_object('brand_name',b.brand_name))) order by si.sale_item_id)
    from public.sale_items si join public.items i on i.tenant_id=t and i.item_id=si.item_id
    left join public.lpg_brands b on b.tenant_id=t and b.brand_id=i.brand_id where si.tenant_id=t and si.sale_id=s.sale_id),'[]')),
  'settlement',public.get_sale_settlement(s.sale_id),
  'bottles',public.get_sale_bottles(s.sale_id),
  'brands',coalesce((select jsonb_agg(jsonb_build_object('brand_id',brand_id,'brand_name',brand_name) order by display_order,created_at desc,brand_id)
    from public.lpg_brands where tenant_id=t),'[]')) into result
 from public.sales s join public.customers c on c.tenant_id=t and c.customer_id=s.customer_id
 join public.tenants business on business.tenant_id=t
 where s.tenant_id=t and s.sale_id=p_sale_id and s.status='completed';
 if result is null then raise exception 'Completed sale not found'; end if;
 return result;
end $$;
alter function public.get_sale_receipt(uuid) owner to postgres;
revoke all on function public.get_sale_receipt(uuid) from public,anon,authenticated;
grant execute on function public.get_sale_receipt(uuid) to authenticated;
