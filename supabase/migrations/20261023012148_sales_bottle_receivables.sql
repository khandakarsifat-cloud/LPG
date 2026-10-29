-- Original invoices and all historical stock retain their meaning. Only new
-- checkouts opt into obligations; no backfill or compensating movements.
alter table public.sales add column bottle_tracking boolean not null default false,
 add column additional_charges numeric(12,2) not null default 0
 check(additional_charges>=0 and additional_charges not in ('NaN'::numeric,'Infinity'::numeric,'-Infinity'::numeric));
alter table public.sales drop constraint sale_paid_valid;
alter table public.sales add constraint sale_paid_valid check(paid_amount>=0 and paid_amount<=total_amount+additional_charges);
drop index public.sales_outstanding;
create index sales_outstanding on public.sales(tenant_id,customer_id,created_at desc) where payment_tracking and paid_amount<total_amount+additional_charges;

insert into public.permissions(permission_id,description) values('sales:collect_bottles','Collect and explicitly allocate customer bottle returns');
insert into public.role_permissions(tenant_id,role_id,permission_id)
 select tenant_id,role_id,'sales:collect_bottles' from public.roles where name in ('OWNER','MANAGER');

create table public.sale_bottle_obligations(
 tenant_id uuid not null,sale_id uuid not null,item_id uuid not null,expected_quantity integer not null check(expected_quantity>0),
 primary key(tenant_id,sale_id,item_id),
 foreign key(tenant_id,sale_id) references public.sales(tenant_id,sale_id),
 foreign key(tenant_id,item_id) references public.items(tenant_id,item_id)
);
create table public.sale_bottle_receipts(
 tenant_id uuid not null,receipt_id uuid not null default gen_random_uuid(),sale_id uuid not null,
 phase text not null check(phase in ('checkout','collection')),operation_id uuid not null,
 note text not null default '',fee numeric(12,2) not null default 0 check(fee>=0 and fee not in ('NaN'::numeric,'Infinity'::numeric,'-Infinity'::numeric)),
 created_by uuid not null,created_at timestamptz not null default clock_timestamp(),
 primary key(tenant_id,receipt_id),unique(tenant_id,operation_id),
 foreign key(tenant_id,sale_id) references public.sales(tenant_id,sale_id),
 foreign key(tenant_id,created_by) references public.user_profiles(tenant_id,user_id)
);
create table public.sale_bottle_receipt_lines(
 tenant_id uuid not null,line_id uuid not null default gen_random_uuid(),receipt_id uuid not null,sale_id uuid not null,
 expected_item_id uuid not null,received_item_id uuid not null,quantity integer not null check(quantity>0),
 allow_incompatible boolean not null default false,
 primary key(tenant_id,line_id),
 foreign key(tenant_id,receipt_id) references public.sale_bottle_receipts(tenant_id,receipt_id),
 foreign key(tenant_id,sale_id,expected_item_id) references public.sale_bottle_obligations(tenant_id,sale_id,item_id),
 foreign key(tenant_id,received_item_id) references public.items(tenant_id,item_id)
);
create index bottle_receipts_sale on public.sale_bottle_receipts(tenant_id,sale_id,created_at,receipt_id);
create index bottle_lines_obligation on public.sale_bottle_receipt_lines(tenant_id,sale_id,expected_item_id) include(quantity);
create index bottle_lines_receipt on public.sale_bottle_receipt_lines(tenant_id,receipt_id);
alter table public.sale_bottle_obligations enable row level security;
alter table public.sale_bottle_receipts enable row level security;
alter table public.sale_bottle_receipt_lines enable row level security;
revoke all on public.sale_bottle_obligations,public.sale_bottle_receipts,public.sale_bottle_receipt_lines from public,anon,authenticated;
-- Bounded, gated read RPCs own all exposure; there are no browser table grants.
create trigger immutable_bottle_obligation before update or delete on public.sale_bottle_obligations for each row execute function app_private.immutable_finance_record();
create trigger immutable_bottle_receipt before update or delete on public.sale_bottle_receipts for each row execute function app_private.immutable_finance_record();
create trigger immutable_bottle_line before update or delete on public.sale_bottle_receipt_lines for each row execute function app_private.immutable_finance_record();

create function app_private.receive_sale_bottles(t uuid,sid uuid,body jsonb,phase text,op uuid) returns uuid
language plpgsql set search_path='' as $$
declare s public.sales; x jsonb; obligation record; expected public.items; actual public.items;
 rid uuid; qty integer; note text:=btrim(coalesce(body->>'note','')); different boolean:=false;
begin
 select * into s from public.sales where tenant_id=t and sale_id=sid for update;
 if not found or not s.bottle_tracking or s.status<>'completed' then raise exception 'Sale does not support bottle collection'; end if;
 if body is null or jsonb_typeof(body)<>'object' or jsonb_typeof(body->'lines') is distinct from 'array' or jsonb_array_length(body->'lines')>200 then raise exception 'Use up to 200 bottle allocations'; end if;
 if phase='collection' and jsonb_array_length(body->'lines')=0 then raise exception 'Add at least one received bottle'; end if;
 if length(note)>1000 then raise exception 'Bottle note is too long'; end if;
 if phase='checkout' and coalesce((body->>'fee')::numeric,0)<>0 then raise exception 'Use the checkout exchange fee field'; end if;
 -- Sale lock serializes all allocations, including repeated products and fees.
 for obligation in select o.item_id,o.expected_quantity,coalesce((select sum(l.quantity) from public.sale_bottle_receipt_lines l where l.tenant_id=t and l.sale_id=sid and l.expected_item_id=o.item_id),0) received,
  coalesce((select sum(app_private.purchase_integer(l->'quantity')) from jsonb_array_elements(body->'lines') l where (l->>'expected_item_id')::uuid=o.item_id),0) incoming
  from public.sale_bottle_obligations o where o.tenant_id=t and o.sale_id=sid
 loop
  if obligation.incoming>obligation.expected_quantity-obligation.received then raise exception 'Bottle allocation exceeds remaining obligation'; end if;
  if obligation.incoming<>obligation.expected_quantity-obligation.received then different:=true; end if;
 end loop;
 perform 1 from public.items where tenant_id=t and item_id in(select (l->>'received_item_id')::uuid from jsonb_array_elements(body->'lines') l) order by item_id for update;
 for x in select value from jsonb_array_elements(body->'lines') loop
  qty:=app_private.purchase_integer(x->'quantity');
  if qty<=0 then raise exception 'Received quantities must be positive whole numbers'; end if;
  if not exists(select 1 from public.sale_bottle_obligations where tenant_id=t and sale_id=sid and item_id=(x->>'expected_item_id')::uuid) then raise exception 'Expected bottle product not found in this sale'; end if;
  select * into expected from public.items where tenant_id=t and item_id=(x->>'expected_item_id')::uuid;
  select * into actual from public.items where tenant_id=t and item_id=(x->>'received_item_id')::uuid;
  if not found then raise exception 'Received product not found in this business'; end if;
  if actual.item_id<>expected.item_id then different:=true; end if;
  if (actual.size_kg is distinct from expected.size_kg or actual.mouth_size is distinct from expected.mouth_size)
    and coalesce((x->>'allow_incompatible')::boolean,false) is not true then raise exception 'Size or mouth differs: explicitly acknowledge a one-for-one substitution'; end if;
 end loop;
 if (different or phase='collection') and length(regexp_replace(note,'\s','','g'))<5 then raise exception 'Explain the partial receipt or substitution in a meaningful bottle note'; end if;
 insert into public.sale_bottle_receipts(tenant_id,sale_id,phase,operation_id,note,fee,created_by)
  values(t,sid,phase,op,note,coalesce((body->>'fee')::numeric,0),auth.uid()) returning receipt_id into rid;
 for x in select value from jsonb_array_elements(body->'lines') loop
  qty:=app_private.purchase_integer(x->'quantity');
  insert into public.sale_bottle_receipt_lines(tenant_id,receipt_id,sale_id,expected_item_id,received_item_id,quantity,allow_incompatible)
   values(t,rid,sid,(x->>'expected_item_id')::uuid,(x->>'received_item_id')::uuid,qty,coalesce((x->>'allow_incompatible')::boolean,false));
  insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,filled_quantity_change,empty_quantity_change,notes,created_by)
   values(t,(x->>'received_item_id')::uuid,'sale','sale',sid,0,qty,'Bottle '||phase||' #'||rid::text||case when note='' then '' else ': '||note end,auth.uid());
 end loop;
 return rid;
end $$;

-- Replacement checkout retains existing price, customer, request and money rules.
drop function public.create_pos_sale(varchar,varchar,varchar,text,varchar,numeric,numeric,text,jsonb,uuid,uuid,jsonb);
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
  bottles:=coalesce(p_bottles,jsonb_build_object('lines',(select coalesce(jsonb_agg(jsonb_build_object('expected_item_id',e.value->>'item_id','received_item_id',e.value->>'item_id','quantity',e.value->'quantity')),'[]') from jsonb_array_elements(p_items) e where e.value->>'type'='empty_return')));
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

create or replace function app_private.receive_sale_payments(t uuid,sid uuid,entries jsonb,phase text,op uuid) returns numeric
language plpgsql set search_path='' as $$
declare s public.sales; x jsonb; w public.wallets; paid numeric:=0; amount numeric; pid uuid;
begin
 select * into s from public.sales where tenant_id=t and sale_id=sid for update;
 if not found or s.status<>'completed' or not s.payment_tracking then raise exception 'Sale does not support payment collection'; end if;
 if entries is null or jsonb_typeof(entries)<>'array' or jsonb_array_length(entries)>20 then raise exception 'Use up to 20 payment entries'; end if;
 -- Lock only participating wallets, in the same order as purchase funding.
 perform 1 from public.wallets where tenant_id=t and wallet_id in (select (value->>'wallet_id')::uuid from jsonb_array_elements(entries)) order by wallet_id for update;
 for x in select value from jsonb_array_elements(entries) loop
  if jsonb_typeof(x)<>'object' or jsonb_typeof(x->'amount') is distinct from 'number' then raise exception 'Payment amounts must be numbers'; end if;
  amount:=app_private.purchase_money((x->>'amount')::numeric);
  if amount<=0 or amount<>(x->>'amount')::numeric then raise exception 'Payment must be positive with at most two decimal places'; end if;
  select * into w from public.wallets where tenant_id=t and wallet_id=(x->>'wallet_id')::uuid and is_active and kind<>'logistics';
  if not found then raise exception 'Select an active payment wallet belonging to this business'; end if;
  if length(coalesce(x->>'reference',''))>200 then raise exception 'Payment reference is too long'; end if;
  paid:=paid+amount;
  if paid+s.paid_amount>(s.total_amount+s.additional_charges) then raise exception 'Payments exceed the remaining sale balance'; end if;
  insert into public.sale_payments(tenant_id,sale_id,wallet_id,wallet_name,method,amount,phase,operation_id,reference,created_by)
   values(t,sid,w.wallet_id,w.name,w.kind,amount,phase,op,coalesce(x->>'reference',''),auth.uid()) returning payment_id into pid;
  insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description,operation_id,payment_id)
   values(t,w.wallet_id,amount,case phase when 'checkout' then 'pos_sale_income' else 'customer_collection' end,sid,
    'Sale #'||left(sid::text,8)||' · '||w.name,op,pid);
  insert into public.customer_transactions(tenant_id,customer_id,type,amount,reference_id,created_by,payment_id)
   values(t,s.customer_id,'payment_receipt',amount,sid,auth.uid(),pid);
 end loop;
 update public.sales set paid_amount=paid_amount+paid where tenant_id=t and sale_id=sid;
 return paid;
end $$;

create or replace function public.collect_sale_payment(p_sale_id uuid,p_payments jsonb,p_request_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('finance:manage'); payload jsonb; prior public.finance_requests; paid numeric; result jsonb;
begin
 if p_request_id is null then raise exception 'Payment request ID is required'; end if;
 payload:=jsonb_build_object('action','collection','sale',p_sale_id,'payments',p_payments,'actor',auth.uid());
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then
  if prior.payload is distinct from payload then raise exception 'Request ID already used with different details'; end if;
  return prior.result;
 end if;
 if p_payments is null or jsonb_typeof(p_payments)<>'array' or jsonb_array_length(p_payments)=0 then raise exception 'Add at least one payment'; end if;
 paid:=app_private.receive_sale_payments(t,p_sale_id,p_payments,'collection',p_request_id);
 select jsonb_build_object('sale_id',sale_id,'received',paid,'paid_amount',paid_amount,'due',total_amount+additional_charges-paid_amount) into result from public.sales where tenant_id=t and sale_id=p_sale_id;
 insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,payload,result,auth.uid());
 return result;
end $$;

create or replace function public.get_finance_dues(p_search text default '',p_customer_id uuid default null,p_offset integer default 0,p_limit integer default 25) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['finance:view','finance:manage']); result jsonb;
begin
 if p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100 or length(coalesce(p_search,''))>500 then raise exception 'Invalid due page'; end if;
 with matching as materialized (
  select s.sale_id,s.customer_id,s.created_at,(s.total_amount+s.additional_charges) total_amount,s.paid_amount,(s.total_amount+s.additional_charges)-s.paid_amount due,c.name,c.phone,c.shop_name
  from public.sales s join public.customers c on c.tenant_id=t and c.customer_id=s.customer_id
  where s.tenant_id=t and s.payment_tracking and s.status='completed' and s.paid_amount<(s.total_amount+s.additional_charges)
   and (p_customer_id is null or s.customer_id=p_customer_id)
   and app_private.finance_search(concat_ws(' ',s.sale_id,c.name,c.phone,c.shop_name),p_search)
 ), page as (select * from matching order by created_at desc,sale_id limit p_limit offset p_offset)
 select jsonb_build_object('total',(select count(*) from matching),'due',(select coalesce(sum(due),0) from matching),
  'entries',coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at desc,p.sale_id) from page p),'[]')) into result;
 return result;
end $$;

create or replace function public.get_sale_settlement(p_sale_id uuid,p_offset integer default 0,p_limit integer default 10) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['finance:view','finance:manage','sales:view','receipts:print','dashboard:view']); s public.sales; result jsonb;
begin
 if p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid payment page'; end if;
 select * into s from public.sales where tenant_id=t and sale_id=p_sale_id;
 if not found then raise exception 'Sale not found'; end if;
 select jsonb_build_object('sale_id',s.sale_id,'tracking',s.payment_tracking,'original_total',s.total_amount,'additional_charges',s.additional_charges,'total',(s.total_amount+s.additional_charges),'paid',s.paid_amount,'due',(s.total_amount+s.additional_charges)-s.paid_amount,
  'paid_at_checkout',s.paid_at_checkout,'checkout_payments',s.checkout_payments,
  'payment_count',(select count(*) from public.sale_payments where tenant_id=t and sale_id=p_sale_id),
  'payments',coalesce((select jsonb_agg(to_jsonb(p) order by created_at desc,payment_id) from
   (select * from public.sale_payments where tenant_id=t and sale_id=p_sale_id order by created_at desc,payment_id limit p_limit offset p_offset) p),'[]'),
  'receipt_payments',coalesce((select jsonb_agg(to_jsonb(p) order by phase,wallet_name,method) from
   (select wallet_name,method,phase,sum(amount) amount from public.sale_payments where tenant_id=t and sale_id=p_sale_id group by wallet_name,method,phase) p),'[]')) into result;
 return result;
end $$;

create or replace function public.get_customer_directory(p_filters jsonb default '{}'::jsonb,p_offset integer default 0,p_limit integer default 12,p_customer_id uuid default null) returns jsonb
language plpgsql stable security definer set search_path='' set plan_cache_mode='force_custom_plan' as $$
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
    select s.customer_id,s.sale_id,s.created_at,s.total_amount+s.additional_charges total_amount,
      case when s.payment_tracking then greatest(0,s.total_amount+s.additional_charges-s.paid_amount) else 0 end due
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

create function public.collect_sale_bottles(p_sale_id uuid,p_payload jsonb,p_request_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('sales:collect_bottles'); prior public.finance_requests;
 payload jsonb; s public.sales; rid uuid; fee numeric; paid numeric; result jsonb;
begin
 if p_request_id is null then raise exception 'Bottle request ID is required'; end if;
 payload:=jsonb_build_object('action','bottles','sale',p_sale_id,'body',p_payload,'actor',auth.uid());
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then
  if prior.payload is distinct from payload then raise exception 'Request ID already used with different details'; end if;
  return prior.result;
 end if;
 fee:=app_private.purchase_money(coalesce((p_payload->>'fee')::numeric,0));
 if fee<>coalesce((p_payload->>'fee')::numeric,0) then raise exception 'Fee must have at most two decimal places'; end if;
 if fee>0 or coalesce(p_payload->'payments','[]')<>'[]'::jsonb then perform app_private.require_permission('finance:manage'); end if;
 select * into s from public.sales where tenant_id=t and sale_id=p_sale_id for update;
 if not found or not s.bottle_tracking then raise exception 'Sale does not support bottle collection'; end if;
 if fee>0 and length(regexp_replace(coalesce(p_payload->>'note',''),'\s','','g'))<5 then raise exception 'Explain the exchange fee'; end if;
 rid:=app_private.receive_sale_bottles(t,p_sale_id,p_payload,'collection',p_request_id);
 if fee>0 then
  update public.sales set additional_charges=additional_charges+fee where tenant_id=t and sale_id=p_sale_id;
  insert into public.customer_transactions(tenant_id,customer_id,type,amount,reference_id,created_by)
   values(t,s.customer_id,'invoice_charge',-fee,p_sale_id,auth.uid());
 end if;
 paid:=app_private.receive_sale_payments(t,p_sale_id,coalesce(p_payload->'payments','[]'),'collection',p_request_id);
 select jsonb_build_object('sale_id',sale_id,'receipt_id',rid,'fee',fee,'paid',paid,'due',total_amount+additional_charges-paid_amount) into result from public.sales where tenant_id=t and sale_id=p_sale_id;
 insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,payload,result,auth.uid());
 return result;
end $$;

create function public.get_sale_bottles(p_sale_id uuid,p_offset integer default 0,p_limit integer default 10) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['sales:view','receipts:print','dashboard:view','sales:collect_bottles']); s public.sales; result jsonb;
begin
 if p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid bottle history page'; end if;
 select * into s from public.sales where tenant_id=t and sale_id=p_sale_id;
 if not found then raise exception 'Sale not found'; end if;
 with obligations as materialized (
  select o.item_id,concat_ws(' ',coalesce(b.brand_name,i.brand),i.size_kg||'kg',i.mouth_size) name,i.size_kg,i.mouth_size,o.expected_quantity expected,
    coalesce(sum(l.quantity),0) received,o.expected_quantity-coalesce(sum(l.quantity),0) outstanding
  from public.sale_bottle_obligations o join public.items i on i.tenant_id=t and i.item_id=o.item_id
  left join public.lpg_brands b on b.tenant_id=t and b.brand_id=i.brand_id
  left join public.sale_bottle_receipt_lines l on l.tenant_id=t and l.sale_id=o.sale_id and l.expected_item_id=o.item_id
  where o.tenant_id=t and o.sale_id=p_sale_id group by o.item_id,o.expected_quantity,i.brand,i.size_kg,i.mouth_size,b.brand_name
 ), actual as materialized (
  select r.phase,l.received_item_id item_id,concat_ws(' ',coalesce(b.brand_name,i.brand),i.size_kg||'kg',i.mouth_size) name,sum(l.quantity) quantity
  from public.sale_bottle_receipts r join public.sale_bottle_receipt_lines l on l.tenant_id=t and l.receipt_id=r.receipt_id
  join public.items i on i.tenant_id=t and i.item_id=l.received_item_id left join public.lpg_brands b on b.tenant_id=t and b.brand_id=i.brand_id
  where r.tenant_id=t and r.sale_id=p_sale_id group by r.phase,l.received_item_id,b.brand_name,i.brand,i.size_kg,i.mouth_size
 ), events as materialized (
  select r.receipt_id id,r.created_at,'bottles' kind,r.phase,r.note,r.fee amount,coalesce(u.full_name,u.email,'Operator') actor,
   coalesce((select jsonb_agg(jsonb_build_object('expected_item_id',l.expected_item_id,'received_item_id',l.received_item_id,'quantity',l.quantity,'allow_incompatible',l.allow_incompatible,
     'expected_name',concat_ws(' ',coalesce(eb.brand_name,ei.brand),ei.size_kg||'kg',ei.mouth_size),
     'received_name',concat_ws(' ',coalesce(rb.brand_name,ri.brand),ri.size_kg||'kg',ri.mouth_size)) order by l.line_id)
    from public.sale_bottle_receipt_lines l join public.items ei on ei.tenant_id=t and ei.item_id=l.expected_item_id
    join public.items ri on ri.tenant_id=t and ri.item_id=l.received_item_id
    left join public.lpg_brands eb on eb.tenant_id=t and eb.brand_id=ei.brand_id left join public.lpg_brands rb on rb.tenant_id=t and rb.brand_id=ri.brand_id
    where l.tenant_id=t and l.receipt_id=r.receipt_id),'[]') lines
  from public.sale_bottle_receipts r left join public.user_profiles u on u.tenant_id=t and u.user_id=r.created_by where r.tenant_id=t and r.sale_id=p_sale_id
  union all
  select s.sale_id,s.created_at,'sale','checkout',coalesce(s.notes,''),s.total_amount,coalesce(u.full_name,u.email,'Operator'),'[]'::jsonb
  from public.user_profiles u where u.tenant_id=t and u.user_id=s.created_by
  union all
  select p.payment_id,p.created_at,'payment',p.phase,concat_ws(' · ',p.wallet_name,nullif(p.reference,'')),p.amount,coalesce(u.full_name,u.email,'Operator'),'[]'::jsonb
  from public.sale_payments p left join public.user_profiles u on u.tenant_id=t and u.user_id=p.created_by where p.tenant_id=t and p.sale_id=p_sale_id
 ), page as (select * from events order by created_at desc,id desc limit p_limit offset p_offset)
 select jsonb_build_object('tracking',s.bottle_tracking,'expected',coalesce((select sum(expected) from obligations),0),
  'received',coalesce((select sum(received) from obligations),0),'outstanding',coalesce((select sum(outstanding) from obligations),0),
  'obligations',coalesce((select jsonb_agg(to_jsonb(o) order by name,item_id) from obligations o),'[]'),
  'actual',coalesce((select jsonb_agg(to_jsonb(a) order by phase,name,item_id) from actual a),'[]'),
  'event_count',(select count(*) from events),'events',coalesce((select jsonb_agg(to_jsonb(p) order by created_at desc,id desc) from page p),'[]')) into result;
 return result;
end $$;

create function public.get_sales_overview() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('sales:view'); result jsonb;
begin
 select jsonb_build_object('total',count(*),'amount',coalesce(sum(total_amount+additional_charges),0),'due',coalesce(sum(total_amount+additional_charges-paid_amount),0),
 'bottles',coalesce((select sum(o.expected_quantity-coalesce((select sum(l.quantity) from public.sale_bottle_receipt_lines l where l.tenant_id=t and l.sale_id=o.sale_id and l.expected_item_id=o.item_id),0)) from public.sale_bottle_obligations o where o.tenant_id=t),0)) into result from public.sales where tenant_id=t and status='completed';
 return result;
end $$;

create function public.get_sales_directory(p_filters jsonb default '{}',p_offset integer default 0,p_limit integer default 25) returns jsonb
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
  left join lateral (select sum(o.expected_quantity) expected,sum((select coalesce(sum(l.quantity),0) from public.sale_bottle_receipt_lines l where l.tenant_id=t and l.sale_id=s.sale_id and l.expected_item_id=o.item_id)) received from public.sale_bottle_obligations o where o.tenant_id=t and o.sale_id=s.sale_id) q on true
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
   coalesce((select jsonb_agg(jsonb_build_object('item_id',o.item_id,'name',concat_ws(' ',coalesce(b.brand_name,i.brand),i.size_kg||'kg',i.mouth_size),'quantity',o.expected_quantity-coalesce((select sum(l.quantity) from public.sale_bottle_receipt_lines l where l.tenant_id=t and l.sale_id=p.sale_id and l.expected_item_id=o.item_id),0)))
    from public.sale_bottle_obligations o join public.items i on i.tenant_id=t and i.item_id=o.item_id left join public.lpg_brands b on b.tenant_id=t and b.brand_id=i.brand_id where o.tenant_id=t and o.sale_id=p.sale_id),'[]') bottle_dues
  from page p
 ) select jsonb_build_object('total',(select count(*) from matching),'entries',coalesce((select jsonb_agg(to_jsonb(d) order by
  case when ordering='date_desc' then created_at end desc,case when ordering='date_asc' then created_at end asc,
  case when ordering='amount_desc' then total_amount end desc,case when ordering='amount_asc' then total_amount end asc,
  case when ordering='due_desc' then due end desc,case when ordering='bottles_desc' then outstanding_bottles end desc,sale_id desc) from details d),'[]')) into result;
 return result;
end $$;

alter function app_private.receive_sale_bottles(uuid,uuid,jsonb,text,uuid) owner to postgres;
revoke all on function app_private.receive_sale_bottles(uuid,uuid,jsonb,text,uuid) from public,anon,authenticated;
alter function public.create_pos_sale(varchar,varchar,varchar,text,varchar,numeric,numeric,text,jsonb,uuid,uuid,jsonb,jsonb) owner to postgres;
alter function public.collect_sale_bottles(uuid,jsonb,uuid) owner to postgres;
alter function public.get_sale_bottles(uuid,integer,integer) owner to postgres;
alter function public.get_sales_directory(jsonb,integer,integer) owner to postgres;
alter function public.get_sales_overview() owner to postgres;
revoke all on function public.create_pos_sale(varchar,varchar,varchar,text,varchar,numeric,numeric,text,jsonb,uuid,uuid,jsonb,jsonb),public.collect_sale_bottles(uuid,jsonb,uuid),public.get_sale_bottles(uuid,integer,integer),public.get_sales_directory(jsonb,integer,integer),public.get_sales_overview() from public,anon,authenticated;
grant execute on function public.create_pos_sale(varchar,varchar,varchar,text,varchar,numeric,numeric,text,jsonb,uuid,uuid,jsonb,jsonb),public.collect_sale_bottles(uuid,jsonb,uuid),public.get_sale_bottles(uuid,integer,integer),public.get_sales_directory(jsonb,integer,integer),public.get_sales_overview() to authenticated;
notify pgrst,'reload schema';

-- Weekly returned empties reflect physical receipt dates/products for new sales.
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
      coalesce(s.empty_return,0)+coalesce((select sum(l.quantity) from public.sale_bottle_receipt_lines l join public.sale_bottle_receipts r on r.tenant_id=t and r.receipt_id=l.receipt_id where l.tenant_id=t and l.received_item_id=p_item_id and r.created_at >= (w.start_date::timestamp at time zone 'Asia/Dhaka') and r.created_at < (w.end_date::timestamp at time zone 'Asia/Dhaka')),0) empty_return,
      coalesce(p.bought_package,0) bought_package,coalesce(p.bought_refill,0) bought_refill
    from weeks w
    cross join lateral (
      select sum(si.quantity) filter(where si.type='refill') sold_refill,
        sum(si.quantity) filter(where si.type='package') sold_package,
        sum(si.quantity) filter(where si.type='empty_return' and not s.bottle_tracking) empty_return
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
    select s.customer_id,s.sale_id,s.created_at,s.sale_tier,s.total_amount+s.additional_charges total_amount,s.total_amount original_total,s.additional_charges from public.sales s
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

create function public.get_customer_bottle_balance(p_customer_id uuid) returns bigint
language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['customers:view','customers:manage','finance:view','finance:manage']); result bigint;
begin
 if not exists(select 1 from public.customers where tenant_id=t and customer_id=p_customer_id) then raise exception 'Customer not found'; end if;
 select coalesce(sum(o.expected_quantity-coalesce((select sum(l.quantity) from public.sale_bottle_receipt_lines l where l.tenant_id=t and l.sale_id=o.sale_id and l.expected_item_id=o.item_id),0)),0) into result
 from public.sale_bottle_obligations o join public.sales s on s.tenant_id=t and s.sale_id=o.sale_id where o.tenant_id=t and s.customer_id=p_customer_id;
 return result;
end $$;
alter function public.get_customer_bottle_balance(uuid) owner to postgres;
revoke all on function public.get_customer_bottle_balance(uuid) from public,anon,authenticated;
grant execute on function public.get_customer_bottle_balance(uuid) to authenticated;

create or replace function public.get_dashboard_stats(p_since timestamptz) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('dashboard:view');
begin
 return jsonb_build_object(
 'todayRevenue',(select coalesce(sum(total_amount),0) from public.sales where tenant_id=t and status='completed' and created_at>=p_since)
   +(select coalesce(sum(fee),0) from public.sale_bottle_receipts where tenant_id=t and created_at>=p_since),
 'todayMovements',(select count(*) from public.inventory_movements where tenant_id=t and created_at>=p_since),
 'totalCustomers',(select count(*) from public.customers where tenant_id=t));
end $$;
