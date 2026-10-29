-- Preserve original expectations and every historical receipt/stock/fee entry.
-- Historical allocation columns remain evidence only; new receipts have no allocation.
alter table public.sale_bottle_receipt_lines alter column expected_item_id drop not null,
 add column acknowledged boolean not null default false;
create index bottle_lines_actual on public.sale_bottle_receipt_lines(tenant_id,sale_id,received_item_id) include(quantity);
alter table public.sale_bottle_receipts add constraint bottle_receipt_sale_unique unique(tenant_id,receipt_id,sale_id);
alter table public.sale_bottle_receipt_lines add constraint bottle_line_receipt_sale_fk
 foreign key(tenant_id,receipt_id,sale_id) references public.sale_bottle_receipts(tenant_id,receipt_id,sale_id);
alter table public.sale_bottle_receipts add column expense numeric(12,2) not null default 0
 check(expense>=0 and expense not in ('NaN'::numeric,'Infinity'::numeric,'-Infinity'::numeric)),
 add column expense_wallet_id uuid,add column expense_wallet_name text,
 add constraint bottle_expense_wallet_fk foreign key(tenant_id,expense_wallet_id) references public.wallets(tenant_id,wallet_id),
 add constraint bottle_expense_wallet_required check((expense=0 and expense_wallet_id is null) or (expense>0 and expense_wallet_id is not null));
update public.permissions set description='Collect physical bottles against aggregate sale quantity' where permission_id='sales:collect_bottles';

create or replace function app_private.receive_sale_bottles(t uuid,sid uuid,body jsonb,phase text,op uuid) returns uuid
language plpgsql set search_path='' as $$
declare s public.sales; x jsonb; rid uuid; qty integer; expected bigint; received bigint; incoming bigint:=0;
 original bigint; previous bigint; expense_wallet public.wallets; note text:=btrim(coalesce(body->>'note',''));
begin
 select * into s from public.sales where tenant_id=t and sale_id=sid for update;
 if not found or not s.bottle_tracking or s.status<>'completed' then raise exception 'Sale does not support bottle collection'; end if;
 if body is null or jsonb_typeof(body)<>'object' or jsonb_typeof(body->'lines') is distinct from 'array' or jsonb_array_length(body->'lines')>200 then raise exception 'Use up to 200 received products'; end if;
 if length(note)>1000 then raise exception 'Bottle note is too long'; end if;
 if coalesce((body->>'fee')::numeric,0)<>0 or coalesce(body->'payments','[]')<>'[]'::jsonb then raise exception 'Refresh the app. Use the separate payment collection action'; end if;
 if phase='checkout' and coalesce((body->>'expense')::numeric,0)<>0 then raise exception 'Collection expenses are only available after sale'; end if;
 if exists(select 1 from jsonb_array_elements(body->'lines') l group by l->>'received_item_id' having count(*)>1) then raise exception 'Use one quantity per received product'; end if;
 select coalesce(sum(expected_quantity),0) into expected from public.sale_bottle_obligations where tenant_id=t and sale_id=sid;
 select coalesce(sum(quantity),0) into received from public.sale_bottle_receipt_lines where tenant_id=t and sale_id=sid;
 for x in select value from jsonb_array_elements(body->'lines') loop
  qty:=app_private.purchase_integer(x->'quantity');
  if qty<=0 then raise exception 'Received quantities must be positive whole numbers'; end if;
  incoming:=incoming+qty;
 end loop;
 if phase='collection' and incoming=0 then raise exception 'Add at least one received bottle'; end if;
 if incoming>expected-received then raise exception 'Received bottles exceed aggregate outstanding quantity'; end if;
 -- Same lock order as checkout/purchases: sale, actual products, then wallets.
 perform 1 from public.items where tenant_id=t and item_id in(select (l->>'received_item_id')::uuid from jsonb_array_elements(body->'lines') l) order by item_id for update;
 for x in select value from jsonb_array_elements(body->'lines') loop
  if not exists(select 1 from public.items where tenant_id=t and item_id=(x->>'received_item_id')::uuid) then raise exception 'Received product not found in this business'; end if;
  select coalesce(sum(expected_quantity),0) into original from public.sale_bottle_obligations where tenant_id=t and sale_id=sid and item_id=(x->>'received_item_id')::uuid;
  if phase='checkout' and original=0 then raise exception 'Select a checkout expected product'; end if;
  select coalesce(sum(quantity),0) into previous from public.sale_bottle_receipt_lines where tenant_id=t and sale_id=sid and received_item_id=(x->>'received_item_id')::uuid;
  if (original=0 or previous+(x->>'quantity')::integer>original) and coalesce((x->>'acknowledged')::boolean,false) is not true then raise exception 'Acknowledge unexpected products or receipts exceeding the original product quantity'; end if;
 end loop;
 if coalesce((body->>'expense')::numeric,0)>0 then
  select * into expense_wallet from public.wallets where tenant_id=t and wallet_id=(body->>'expense_wallet_id')::uuid and is_active and kind<>'logistics' for no key update;
  if not found then raise exception 'Select an active expense wallet belonging to this business'; end if;
 end if;
 insert into public.sale_bottle_receipts(tenant_id,sale_id,phase,operation_id,note,created_by,expense,expense_wallet_id,expense_wallet_name)
 values(t,sid,phase,op,note,auth.uid(),coalesce((body->>'expense')::numeric,0),nullif(body->>'expense_wallet_id','')::uuid,
 expense_wallet.name) returning receipt_id into rid;
 for x in select value from jsonb_array_elements(body->'lines') loop
  qty:=app_private.purchase_integer(x->'quantity');
  insert into public.sale_bottle_receipt_lines(tenant_id,receipt_id,sale_id,received_item_id,quantity,acknowledged)
  values(t,rid,sid,(x->>'received_item_id')::uuid,qty,coalesce((x->>'acknowledged')::boolean,false));
  insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,filled_quantity_change,empty_quantity_change,notes,created_by)
  values(t,(x->>'received_item_id')::uuid,'sale','sale',sid,0,qty,'Bottle '||phase||' #'||rid::text||case when note='' then '' else ': '||note end,auth.uid());
 end loop;
 return rid;
end $$;


create or replace function public.create_pos_sale(
  p_customer_phone varchar,p_customer_name varchar,p_customer_shop_name varchar,p_customer_address text,
  p_customer_tier varchar,p_discount_amount numeric,p_exchange_fee numeric,p_notes text,p_items jsonb,
  p_customer_id uuid default null,p_request_id uuid default null,p_payments jsonb default null,p_bottles jsonb default null
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  t uuid:=app_private.require_permission('pos:sell'); actor uuid:=auth.uid();
  tier text:=coalesce(p_customer_tier,'retail'); payload jsonb; saved public.sales;
  customer public.customers; sale uuid; x jsonb; stock record; qty integer; price numeric;
  expected numeric; subtotal numeric:=0; discount numeric; fee numeric; total numeric;
  refills bigint:=0; empties bigint:=0; filled_delta integer; empty_delta integer;
  wallet uuid; result jsonb; payments jsonb; paid numeric; bottles jsonb;
begin
  if p_request_id is null then raise exception 'Checkout request ID is required. Refresh the application.'; end if;
  payload:=jsonb_build_object('actor',actor,'customer_id',p_customer_id,'phone',trim(p_customer_phone),
    'name',p_customer_name,'shop',p_customer_shop_name,'address',p_customer_address,'tier',tier,
    'discount',coalesce(p_discount_amount,0),'fee',coalesce(p_exchange_fee,0),'notes',p_notes,'items',p_items,'payments',p_payments,'bottles',p_bottles);
  perform pg_advisory_xact_lock(hashtextextended(t::text||':pos:'||p_request_id::text,0));
  select * into saved from public.sales where tenant_id=t and checkout_request_id=p_request_id;
  if found then
    if (saved.checkout_payload||jsonb_build_object('payments',saved.checkout_payload->'payments','bottles',saved.checkout_payload->'bottles')) is distinct from payload then
      raise exception 'Checkout request ID was already used with different sale details';
    end if;
    return saved.checkout_result;
  end if;
  if tier not in ('retail','wholesale') then raise exception 'Invalid sale tier'; end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then
    raise exception 'Cart must be a nonempty array';
  end if;
  discount:=app_private.purchase_money(coalesce(p_discount_amount,0));
  fee:=app_private.purchase_money(coalesce(p_exchange_fee,0));
  if nullif(trim(p_customer_phone),'') is null then raise exception 'Customer phone number is required to complete a sale'; end if;

  if p_bottles is not null and (jsonb_typeof(p_bottles)<>'object' or jsonb_typeof(p_bottles->'lines') is distinct from 'array') then raise exception 'Invalid received bottles'; end if;
  bottles:=coalesce(p_bottles,jsonb_build_object('lines',(select coalesce(jsonb_agg(jsonb_build_object('received_item_id',e.value->>'item_id','quantity',e.value->'quantity')),'[]') from jsonb_array_elements(p_items) e where e.value->>'type'='empty_return')));
  -- Every participating item is locked before any stock write, in the same order
  -- as purchases and inventory price saves. Price saves also lock the item first.
  for stock in select i.item_id from public.items i where i.tenant_id=t and i.item_id in
    (select (value->>'item_id')::uuid from jsonb_array_elements(p_items) union select (value->>'received_item_id')::uuid from jsonb_array_elements(bottles->'lines')) order by i.item_id for update
  loop null; end loop;
  for x in select value from jsonb_array_elements(p_items) loop
    if jsonb_typeof(x)<>'object' or x->>'type' is null or x->>'type' not in ('refill','package','empty_return') then
      raise exception 'Invalid sale line';
    end if;
    qty:=app_private.purchase_integer(x->'quantity');
    if qty=0 then raise exception 'Sale quantities must be positive whole numbers'; end if;
    if jsonb_typeof(x->'unit_price') is distinct from 'number' then raise exception 'Sale prices must be finite numbers'; end if;
    price:=app_private.purchase_money((x->>'unit_price')::numeric);
    if not exists(select 1 from public.items where tenant_id=t and item_id=(x->>'item_id')::uuid) then
      raise exception 'Item not found';
    end if;
    if x->>'type'='empty_return' then
      if price<>0 then raise exception 'Empty returns must have a zero price'; end if;
      empties:=empties+qty;
    else
      select pb.price into expected from public.price_books pb
        where pb.tenant_id=t and pb.item_id=(x->>'item_id')::uuid and pb.price_type=x->>'type'
          and pb.customer_tier in (tier,'retail') and pb.effective_from<=statement_timestamp()
          and (pb.effective_to is null or pb.effective_to>statement_timestamp())
        order by (pb.customer_tier=tier) desc,pb.effective_from desc limit 1;
      if not found then raise exception 'No active selling price. Set the product price before checkout.'; end if;
      expected:=app_private.purchase_money(expected);
      if price<>expected then raise exception 'Selling price changed or does not match the price book. Refresh prices and review the cart.'; end if;
      if x->>'type'='refill' then refills:=refills+qty; end if;
    end if;
    subtotal:=subtotal+qty*price;
  end loop;
  if refills<>empties then raise exception 'Refill count (%) must equal empty bottle return count (%)',refills,empties; end if;
  subtotal:=app_private.purchase_money(subtotal);
  if discount>subtotal then raise exception 'Discount cannot exceed the product subtotal'; end if;
  total:=app_private.purchase_money(subtotal-discount+fee);
  -- Validate net stock across the complete cart, independently of line order.
  for stock in select i.item_id,i.filled_quantity,i.empty_quantity,
    sum(case when l.value->>'type' in ('refill','package') then -(l.value->>'quantity')::numeric else 0 end) filled,
    sum(case when l.value->>'type'='package' then -(l.value->>'quantity')::numeric
      else 0 end) + coalesce((select sum((r->>'quantity')::numeric) from jsonb_array_elements(bottles->'lines') r where (r->>'received_item_id')::uuid=i.item_id),0) empty
    from jsonb_array_elements(p_items) l join public.items i on i.tenant_id=t and i.item_id=(l.value->>'item_id')::uuid
    group by i.tenant_id,i.item_id order by i.item_id loop
    if stock.filled_quantity+stock.filled<0 or stock.empty_quantity+stock.empty<0 then raise exception 'Insufficient stock'; end if;
  end loop;
  if p_customer_id is not null then
    select * into customer from public.customers where tenant_id=t and customer_id=p_customer_id for share;
    if not found then raise exception 'Selected customer was not found'; end if;
    if tier is distinct from customer.tier::text then
      raise exception 'Sale pricing must match the selected customer type. Select the customer again.';
    end if;
  else
    if exists(select 1 from public.customers where tenant_id=t and phone=trim(p_customer_phone)) then
      raise exception 'This phone number belongs to a saved customer. Select the saved customer before completing the sale.';
    end if;
    insert into public.customers(tenant_id,name,phone,shop_name,address,tier)
      values(t,coalesce(nullif(trim(p_customer_name),''),'Unknown'),trim(p_customer_phone),
        nullif(trim(p_customer_shop_name),''),nullif(trim(p_customer_address),''),tier) returning * into customer;
  end if;
  insert into public.sales(tenant_id,customer_id,sale_tier,status,subtotal,discount_amount,exchange_fee,total_amount,
    notes,created_by,checkout_request_id,checkout_payload,payment_tracking,bottle_tracking)
    values(t,customer.customer_id,tier,'completed',subtotal,discount,fee,total,p_notes,actor,p_request_id,payload,true,true) returning sale_id into sale;
  insert into public.sale_bottle_obligations(tenant_id,sale_id,item_id,expected_quantity)
    select t,sale,(e.value->>'item_id')::uuid,sum((e.value->>'quantity')::integer) from jsonb_array_elements(p_items) e where e.value->>'type'='empty_return' group by (e.value->>'item_id')::uuid;
  perform app_private.receive_sale_bottles(t,sale,bottles,'checkout',p_request_id);
  for x in select value from jsonb_array_elements(p_items) loop
    qty:=app_private.purchase_integer(x->'quantity'); price:=(x->>'unit_price')::numeric;
    filled_delta:=0; empty_delta:=0;
    if x->>'type'='refill' then filled_delta:=-qty;
    elsif x->>'type'='package' then filled_delta:=-qty; empty_delta:=-qty;
    else empty_delta:=0; end if;
    if x->>'type'<>'empty_return' then
    insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,
      filled_quantity_change,empty_quantity_change,notes,created_by)
      values(t,(x->>'item_id')::uuid,'sale','sale',sale,filled_delta,empty_delta,'POS Sale #'||left(sale::text,8),actor);
    end if;
    insert into public.sale_items(tenant_id,sale_id,item_id,type,quantity,unit_price,line_total)
      values(t,sale,(x->>'item_id')::uuid,(x->>'type')::public.sale_item_type,qty,price,qty*price);
  end loop;
  insert into public.customer_transactions(tenant_id,customer_id,type,amount,reference_id,created_by)
    values(t,customer.customer_id,'invoice_charge',-total,sale,actor);
  select wallet_id into wallet from public.wallets where tenant_id=t and type='cash';
  payments:=coalesce(p_payments,case when total=0 then '[]'::jsonb else jsonb_build_array(jsonb_build_object('wallet_id',wallet,'amount',total)) end);
  paid:=app_private.receive_sale_payments(t,sale,payments,'checkout',p_request_id);
  update public.sales set paid_at_checkout=paid,checkout_payments=coalesce((select jsonb_agg(jsonb_build_object('wallet_id',wallet_id,'wallet_name',wallet_name,'method',method,'amount',amount,'reference',reference) order by created_at,payment_id)
    from public.sale_payments where tenant_id=t and sale_id=sale),'[]') where tenant_id=t and sale_id=sale;
  result:=jsonb_build_object('sale_id',sale,'sale_tier',tier,'customer_id',customer.customer_id,'subtotal',subtotal,
    'total_amount',total,'paid_amount',paid,'due',total-paid,'customer_phone',customer.phone,'customer_name',coalesce(nullif(trim(customer.name),''),'Unknown'));
  update public.sales set checkout_result=result where tenant_id=t and sale_id=sale;
  return result;
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
 if found then
  if prior.payload is distinct from payload then raise exception 'Request ID already used with different details'; end if;
  return prior.result;
 end if;
 cost:=app_private.purchase_money(coalesce((p_payload->>'expense')::numeric,0));
 if cost<>coalesce((p_payload->>'expense')::numeric,0) then raise exception 'Expense must have at most two decimal places'; end if;
 if cost>0 then perform app_private.require_permission('finance:manage');
 elsif nullif(p_payload->>'expense_wallet_id','') is not null then raise exception 'Select a wallet only when recording an expense'; end if;
 select * into s from public.sales where tenant_id=t and sale_id=p_sale_id for update;
 if not found or not s.bottle_tracking then raise exception 'Sale does not support bottle collection'; end if;
 rid:=app_private.receive_sale_bottles(t,p_sale_id,p_payload,'collection',p_request_id);
 if cost>0 then
  insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description,operation_id)
  values(t,(p_payload->>'expense_wallet_id')::uuid,-cost,'sale_bottle_expense',p_sale_id,'Bottle collection #'||rid::text||' · Sale #'||left(p_sale_id::text,8),p_request_id);
 end if;
 result:=jsonb_build_object('sale_id',p_sale_id,'receipt_id',rid,'expense',cost,'due',s.total_amount+s.additional_charges-s.paid_amount);
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
  'received',coalesce((select sum(quantity) from actual),0),'outstanding',coalesce((select sum(expected) from obligations),0)-coalesce((select sum(quantity) from actual),0),
  'obligations',coalesce((select jsonb_agg(to_jsonb(o) order by name,item_id) from obligations o),'[]'),
  'actual',coalesce((select jsonb_agg(to_jsonb(a) order by phase,name,item_id) from actual a),'[]'),
  'event_count',(select count(*) from events),'events',coalesce((select jsonb_agg(to_jsonb(p) order by created_at desc,id desc) from page p),'[]')) into result;
 return result;
end $$;

create or replace function public.get_sales_overview() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('sales:view'); result jsonb;
begin
 select jsonb_build_object('total',count(*),'amount',coalesce(sum(total_amount+additional_charges),0),'due',coalesce(sum(total_amount+additional_charges-paid_amount),0),
 'bottles',coalesce((select sum(expected_quantity) from public.sale_bottle_obligations where tenant_id=t),0)-coalesce((select sum(quantity) from public.sale_bottle_receipt_lines where tenant_id=t),0)) into result from public.sales where tenant_id=t and status='completed';
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
   coalesce(q.expected,0) expected,coalesce(q.expected,0)-coalesce(q.received,0) outstanding_bottles,coalesce(q.received,0) received_bottles
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
 select coalesce(sum(
 (select coalesce(sum(expected_quantity),0) from public.sale_bottle_obligations where tenant_id=t and sale_id=s.sale_id)-
 (select coalesce(sum(quantity),0) from public.sale_bottle_receipt_lines where tenant_id=t and sale_id=s.sale_id)),0) into result
 from public.sales s where s.tenant_id=t and s.customer_id=p_customer_id;
 return result;
end $$;

create or replace function public.get_wallet_ledger(p_filters jsonb default '{}',p_offset integer default 0,p_limit integer default 25) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['finance:view','finance:manage']); result jsonb;
 sorting text:=coalesce(p_filters->>'sort','date_desc');
 search_condition text:=''; group_condition text; search_group text; token text;
begin
 if p_filters is null or jsonb_typeof(p_filters)<>'object' or length(coalesce(p_filters->>'search',''))>500
  or sorting not in ('date_desc','date_asc','amount_desc','amount_asc')
  or coalesce(p_filters->>'direction','all') not in ('all','in','out')
  or p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid ledger filters or page'; end if;
 if nullif(p_filters->>'min','') is not null then perform app_private.purchase_money((p_filters->>'min')::numeric); end if;
 if nullif(p_filters->>'max','') is not null then perform app_private.purchase_money((p_filters->>'max')::numeric); end if;
 if nullif(p_filters->>'min','')::numeric> nullif(p_filters->>'max','')::numeric or nullif(p_filters->>'from','')::date>nullif(p_filters->>'to','')::date then raise exception 'Invalid filter range'; end if;

 -- Compile token groups once, quoting every literal. Direct LIKE predicates let
 -- pg_trgm use its index; user '%'/'_'/'\' remain literal substring characters.
 for search_group in select value from regexp_split_to_table(lower(coalesce(p_filters->>'search','')),'\s*,\s*') value loop
  group_condition:='';
  for token in select value from regexp_split_to_table(trim(search_group),'\s+') value where value<>'' loop
   group_condition:=concat_ws(' and ',nullif(group_condition,''),format('x.search_document like %L',
    '%'||replace(replace(replace(token,chr(92),chr(92)||chr(92)),'%',chr(92)||'%'),'_',chr(92)||'_')||'%'));
  end loop;
  if group_condition<>'' then search_condition:=concat_ws(' or ',nullif(search_condition,''),'('||group_condition||')'); end if;
 end loop;
 search_condition:=coalesce(nullif(search_condition,''),'true');
 execute format($ledger$ with matching as materialized (
  select x.transaction_id,x.created_at,x.entry_no,x.amount from public.wallet_transactions x where x.tenant_id=$1
   and (nullif($2->>'wallet','') is null or x.wallet_id=($2->>'wallet')::uuid)
   and (nullif($2->>'type','') is null or x.type=$2->>'type')
   and (coalesce($2->>'direction','all')='all' or ($2->>'direction'='in' and x.amount>0) or ($2->>'direction'='out' and x.amount<0))
   and (nullif($2->>'from','') is null or x.created_at >= (nullif($2->>'from','')::date::timestamp at time zone 'Asia/Dhaka'))
   and (nullif($2->>'to','') is null or x.created_at < ((nullif($2->>'to','')::date+1)::timestamp at time zone 'Asia/Dhaka'))
   and (nullif($2->>'min','') is null or abs(x.amount)>=($2->>'min')::numeric)
   and (nullif($2->>'max','') is null or abs(x.amount)<=($2->>'max')::numeric)
   and (%s)
 ), page as materialized (
  select * from matching order by
   case when $3='date_desc' then created_at end desc,case when $3='date_asc' then created_at end,
   case when $3='amount_desc' then abs(amount) end desc,case when $3='amount_asc' then abs(amount) end,entry_no desc limit $4 offset $5
 ) select jsonb_build_object('total',(select count(*) from matching),
  'received',(select coalesce(sum(amount) filter(where amount>0),0) from matching),
  'paid_out',(select -coalesce(sum(amount) filter(where amount<0),0) from matching),
  'entries',coalesce((select jsonb_agg((to_jsonb(p)-'search_document')||jsonb_build_object('wallet_name',coalesce(p.wallet_name_snapshot,w.name),'counterparty',cw.name,'actor',up.full_name,
   'payment_reference',coalesce(sp.reference,pp.reference),'customer_name',c.name,'customer_phone',c.phone,'source',case when sp.payment_id is not null or p.type='sale_bottle_expense' then 'sale' when p.type like 'purchase%%' then 'purchase' when p.type like 'transit%%' or p.type like 'transport%%' then 'transit' else null end) order by
   case when $3='date_desc' then p.created_at end desc,case when $3='date_asc' then p.created_at end,
   case when $3='amount_desc' then abs(p.amount) end desc,case when $3='amount_asc' then abs(p.amount) end,p.entry_no desc)
   from page keys join public.wallet_transactions p on p.tenant_id=$1 and p.transaction_id=keys.transaction_id
   join public.wallets w on w.tenant_id=$1 and w.wallet_id=p.wallet_id
   left join public.wallets cw on cw.tenant_id=$1 and cw.wallet_id=p.counterparty_wallet_id
   left join public.user_profiles up on up.tenant_id=$1 and up.user_id=p.created_by
   left join public.sale_payments sp on sp.tenant_id=$1 and sp.payment_id=p.payment_id
   left join public.purchase_payments pp on pp.tenant_id=$1 and pp.payment_id=p.purchase_payment_id
   left join public.sales s on s.tenant_id=$1 and s.sale_id=case when p.type='sale_bottle_expense' then p.reference_id else sp.sale_id end
   left join public.customers c on c.tenant_id=$1 and c.customer_id=s.customer_id),'[]'))
 $ledger$,search_condition) into result using t,p_filters,sorting,p_limit,p_offset;
 return result;
end $$;
create or replace function app_private.post_wallet_entry() returns trigger language plpgsql set search_path='' as $$
begin
 if new.amount is null or new.amount in ('NaN'::numeric,'Infinity'::numeric,'-Infinity'::numeric) then raise exception 'Invalid wallet amount'; end if;
 select name,kind into new.wallet_name_snapshot,new.wallet_method_snapshot from public.wallets where tenant_id=new.tenant_id and wallet_id=new.wallet_id;
 new.created_by:=auth.uid();
 update public.wallets set balance=balance+new.amount,updated_at=clock_timestamp()
 where tenant_id=new.tenant_id and wallet_id=new.wallet_id returning balance into new.balance_after;
 if not found then raise exception 'Wallet not found'; end if;
 new.created_at:=clock_timestamp();
 select lower(concat_ws(' ',new.description,new.type,new.reference_id,new.operation_id,new.transaction_id,w.name,sp.reference,c.name,c.phone,c.shop_name))
 into new.search_document from public.wallets w
 left join public.sale_payments sp on sp.tenant_id=new.tenant_id and sp.payment_id=new.payment_id
 left join public.sales s on s.tenant_id=new.tenant_id and s.sale_id=case when new.type='sale_bottle_expense' then new.reference_id else sp.sale_id end
 left join public.customers c on c.tenant_id=new.tenant_id and c.customer_id=s.customer_id
 where w.tenant_id=new.tenant_id and w.wallet_id=new.wallet_id;
 return new;
end $$;
notify pgrst,'reload schema';
