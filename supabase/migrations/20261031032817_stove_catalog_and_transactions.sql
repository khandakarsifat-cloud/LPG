-- Extend the shared catalog, purchase and POS contracts; do not create a
-- second stock/sales/payment architecture.
create table public.stove_product_types(
 tenant_id uuid not null references public.tenants(tenant_id),type_id uuid not null default gen_random_uuid(),name text not null check(length(trim(name)) between 1 and 80),is_active boolean not null default true,
 primary key(tenant_id,type_id),unique(tenant_id,name)
);
alter table public.stove_product_types enable row level security;
revoke all on public.stove_product_types from public,anon,authenticated;
create function app_private.seed_stove_types(t uuid) returns void language sql set search_path='' as $$
 insert into public.stove_product_types(tenant_id,name) select t,x from unnest(array['Single Stove','Double Stove','Regulator','Pipe','Others'])x on conflict do nothing;$$;
do $$declare t record;begin for t in select tenant_id from public.tenants loop perform app_private.seed_stove_types(t.tenant_id);end loop;end $$;
create function app_private.stove_types_created() returns trigger language plpgsql set search_path='' as $$begin perform app_private.seed_stove_types(new.tenant_id);return new;end $$;
create trigger stove_types_created after insert on public.tenants for each row execute function app_private.stove_types_created();
alter table public.items add column business_category text not null default 'lpg' check(business_category in ('lpg','stove')),
 add column product_name text,add column product_type_id uuid,
 alter column brand_id drop not null,alter column size_kg drop not null;
alter table public.items add foreign key(tenant_id,product_type_id) references public.stove_product_types(tenant_id,type_id),
 add constraint item_business_shape check((business_category='lpg' and brand_id is not null and size_kg>0 and product_name is null and product_type_id is null) or
 (business_category='stove' and brand_id is null and size_kg is null and mouth_size is null and length(trim(product_name)) between 1 and 150 and product_type_id is not null and empty_quantity=0));
create index item_stove_type on public.items(tenant_id,product_type_id);
create unique index stove_product_name on public.items(tenant_id,lower(product_name)) where business_category='stove';
alter table public.sales add column business_category text not null default 'lpg' check(business_category in ('lpg','stove'));
alter table public.purchases add column business_category text not null default 'lpg' check(business_category in ('lpg','stove')),add column supplier_name text,alter column plant_id drop not null;
alter table public.purchases add constraint purchase_business_shape check((business_category='lpg' and plant_id is not null) or (business_category='stove' and plant_id is null and vehicle_id is null and brand_id is null and length(trim(supplier_name)) between 1 and 150 and transport_cost=0 and labour_cost=0 and commission=0));
create index purchase_business_directory on public.purchases(tenant_id,business_category,created_at desc);
create function public.get_stove_product_types() returns setof public.stove_product_types language plpgsql stable security definer set search_path='' as $$begin
 return query select * from public.stove_product_types where tenant_id=app_private.require_any_permission(array['settings:manage','inventory:view','inventory:manage','pos:sell','purchases:manage']) order by name;end $$;
create function public.save_stove_product_type(p_name text,p_type_id uuid default null,p_active boolean default true) returns uuid language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('settings:manage');id uuid:=p_type_id;begin
 if length(trim(p_name)) not between 1 and 80 or p_name is null or p_active is null then raise exception 'Enter a valid product type';end if;
 if id is null then insert into public.stove_product_types(tenant_id,name) values(t,trim(p_name)) returning type_id into id;
 else update public.stove_product_types set name=trim(p_name),is_active=p_active where tenant_id=t and type_id=id;if not found then raise exception 'Product type not found';end if;end if;return id;end $$;
create function public.save_stove_product(p_payload jsonb,p_request_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('inventory:manage');id uuid:=(p_payload->>'item_id')::uuid;prior public.finance_requests;body jsonb:=jsonb_build_object('action','stove_product','actor',auth.uid(),'body',p_payload);result jsonb;begin
 if p_request_id is null then raise exception 'Request ID is required';end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from body then raise exception 'Request ID already used';end if;return prior.result;end if;
 if nullif(trim(p_payload->>'name'),'') is null or length(p_payload->>'name')>150 or not exists(select 1 from public.stove_product_types where tenant_id=t and type_id=(p_payload->>'type_id')::uuid and is_active) then raise exception 'Enter a name and active product type';end if;
 if id is null then insert into public.items(tenant_id,business_category,product_name,product_type_id) values(t,'stove',trim(p_payload->>'name'),(p_payload->>'type_id')::uuid) returning item_id into id;
 else update public.items set product_name=trim(p_payload->>'name'),product_type_id=(p_payload->>'type_id')::uuid where tenant_id=t and item_id=id and business_category='stove';if not found then raise exception 'Stove product not found';end if;end if;
 result:=jsonb_build_object('item_id',id);insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,result,auth.uid());return result;end $$;


CREATE OR REPLACE FUNCTION app_private.require_configured_weight() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
begin
 if new.business_category='stove' then return new;end if;
 perform 1 from public.business_weights where tenant_id=new.tenant_id and size_kg=new.size_kg and is_active for share;
 if not found then raise exception 'Select an active weight from Settings'; end if;
 return new;
end $$;

CREATE OR REPLACE FUNCTION public.create_pos_sale(p_customer_phone character varying, p_customer_name character varying, p_customer_shop_name character varying, p_customer_address text, p_customer_tier character varying, p_discount_amount numeric, p_exchange_fee numeric, p_notes text, p_items jsonb, p_customer_id uuid DEFAULT NULL::uuid, p_request_id uuid DEFAULT NULL::uuid, p_payments jsonb DEFAULT NULL::jsonb, p_bottles jsonb DEFAULT NULL::jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  t uuid:=app_private.require_permission('pos:sell'); actor uuid:=auth.uid();
  tier text:=coalesce(p_customer_tier,'retail'); payload jsonb; saved public.sales;
  customer public.customers; sale uuid; x jsonb; stock record; qty integer; price numeric;
  expected numeric; subtotal numeric:=0; discount numeric; fee numeric; total numeric;
  refills bigint:=0; empties bigint:=0; filled_delta integer; empty_delta integer;
  category text;wallet uuid; result jsonb; payments jsonb; paid numeric; bottles jsonb;
begin
  if p_request_id is null then raise exception 'Checkout request ID is required. Refresh the application.'; end if;
  payload:=jsonb_build_object('actor',actor,'customer_id',p_customer_id,'phone',trim(p_customer_phone),
    'name',p_customer_name,'shop',p_customer_shop_name,'address',p_customer_address,'tier',tier,
    'discount',coalesce(p_discount_amount,0),'fee',coalesce(p_exchange_fee,0),'notes',p_notes,'items',p_items,'payments',p_payments,'bottles',p_bottles);
  perform pg_advisory_xact_lock(hashtextextended(t::text||':pos:'||p_request_id::text,0));
  select * into saved from public.sales where tenant_id=t and checkout_request_id=p_request_id;
  if found then
    if saved.checkout_payload is distinct from payload then
      raise exception 'Checkout request ID was already used with different sale details';
    end if;
    return saved.checkout_result;
  end if;
  if tier not in ('retail','wholesale') then raise exception 'Invalid sale tier'; end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then
    raise exception 'Cart must be a nonempty array';
  end if;
  select min(i.business_category) into category from jsonb_array_elements(p_items) l join public.items i on i.tenant_id=t and i.item_id=(l->>'item_id')::uuid;
  if category is null or exists(select 1 from jsonb_array_elements(p_items) l join public.items i on i.tenant_id=t and i.item_id=(l->>'item_id')::uuid where i.business_category<>category) then raise exception 'Use one business catalog per sale';end if;
  if category='stove' and (coalesce(p_exchange_fee,0)<>0 or exists(select 1 from jsonb_array_elements(p_items) l where l->>'type'<>'package') or p_bottles is not null) then raise exception 'Stove sales do not support LPG bottle settlement';end if;
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
    sum(case when category='lpg' and l.value->>'type'='package' then -(l.value->>'quantity')::numeric
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
    notes,created_by,checkout_request_id,checkout_payload,business_category)
    values(t,customer.customer_id,tier,'completed',subtotal,discount,fee,total,p_notes,actor,p_request_id,payload,category) returning sale_id into sale;
  insert into public.sale_items(tenant_id,sale_id,item_id,type,quantity,unit_price,line_total)
    select t,sale,(l->>'item_id')::uuid,(l->>'type')::public.sale_item_type,
      app_private.purchase_integer(l->'quantity'),(l->>'unit_price')::numeric,
      app_private.purchase_integer(l->'quantity')*(l->>'unit_price')::numeric
    from jsonb_array_elements(p_items) l;
  if category='lpg' then perform app_private.receive_sale_bottles(t,sale,bottles,'checkout',p_request_id);end if;
  for x in select value from jsonb_array_elements(p_items) loop
    qty:=app_private.purchase_integer(x->'quantity'); price:=(x->>'unit_price')::numeric;
    filled_delta:=0; empty_delta:=0;
    if x->>'type'='refill' then filled_delta:=-qty;
    elsif x->>'type'='package' then filled_delta:=-qty; empty_delta:=case when category='lpg' then -qty else 0 end;
    else empty_delta:=0; end if;
    if x->>'type'<>'empty_return' then
    insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,
      filled_quantity_change,empty_quantity_change,notes,created_by)
      values(t,(x->>'item_id')::uuid,'sale','sale',sale,filled_delta,empty_delta,'POS Sale #'||left(sale::text,8),actor);
    end if;
  end loop;
  insert into public.customer_transactions(tenant_id,customer_id,type,amount,reference_id,created_by)
    values(t,customer.customer_id,'invoice_charge',-total,sale,actor);
  select wallet_id into wallet from public.wallets where tenant_id=t and type='cash';
  payments:=coalesce(p_payments,case when total=0 then '[]'::jsonb else jsonb_build_array(jsonb_build_object('wallet_id',wallet,'amount',total)) end);
  paid:=app_private.receive_sale_payments(t,sale,payments,'checkout',p_request_id);
  update public.sales set paid_at_checkout=paid where tenant_id=t and sale_id=sale;
  result:=jsonb_build_object('sale_id',sale,'sale_tier',tier,'customer_id',customer.customer_id,'subtotal',subtotal,
    'total_amount',total,'paid_amount',paid,'due',total-paid,'customer_phone',customer.phone,'customer_name',coalesce(nullif(trim(customer.name),''),'Unknown'));
  update public.sales set checkout_result=result where tenant_id=t and sale_id=sale;
  return result;
end $$;

CREATE OR REPLACE FUNCTION app_private.save_purchase_lines(p_tenant uuid, p_purchase uuid, p_lines jsonb) RETURNS void
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
declare p public.purchases; x jsonb; i public.items; q integer; e integer; price numeric; line_id uuid;
begin
  select * into p from public.purchases where tenant_id=p_tenant and purchase_id=p_purchase;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' then raise exception 'Products must be an array'; end if;
  if p.business_category='stove' then
    if p.status<>'created' or p.paid_amount>0 then raise exception 'Received or paid purchase lines are immutable';end if;
    if jsonb_array_length(p_lines) not between 1 and 100 then raise exception 'Select 1 to 100 products';end if;
    delete from public.purchase_items where tenant_id=p_tenant and purchase_id=p_purchase;
    for x in select value from jsonb_array_elements(p_lines) loop
      q:=app_private.purchase_integer(x->'quantity');price:=app_private.purchase_money((x->>'unit_price')::numeric);
      if q<=0 or x->>'type' is distinct from 'package' or not exists(select 1 from public.items where tenant_id=p_tenant and item_id=(x->>'item_id')::uuid and business_category='stove') then raise exception 'Choose a stove product and positive quantity';end if;
      if exists(select 1 from public.purchase_items where tenant_id=p_tenant and purchase_id=p_purchase and item_id=(x->>'item_id')::uuid) then raise exception 'Duplicate product';end if;
      insert into public.purchase_items(tenant_id,purchase_id,item_id,type,quantity,empty_dispatched,billed_quantity,unit_price,line_total)
      values(p_tenant,p_purchase,(x->>'item_id')::uuid,'package',q,0,q,price,q*price);
    end loop;return;
  end if;
  if p.status='created' then
    perform app_private.check_purchase_empties(p_tenant,p_lines);
    delete from public.purchase_items where tenant_id=p_tenant and purchase_id=p_purchase;
    for x in select value from jsonb_array_elements(p_lines) loop
      if x->>'type' is null or x->>'type' not in ('refill','package') then raise exception 'Invalid purchase type'; end if;
      q := app_private.purchase_integer(x->'quantity');
      e := case when x->>'type'='refill' then q else 0 end;
      -- Retain the wire field for older clients, but reject contradictory plans.
      if x ? 'empty_dispatched' and app_private.purchase_integer(x->'empty_dispatched') <> e then
        raise exception 'Refills exchange one empty cylinder per refill; new cylinders send none. Refresh and save the purchase.';
      end if;
      price := app_private.purchase_money((x->>'unit_price')::numeric);
      if q=0 or (x->>'type'='package' and e<>0) then raise exception 'Expected quantity must be positive; new cylinders cannot dispatch empties'; end if;
      select * into i from public.items where tenant_id=p_tenant and item_id=(x->>'item_id')::uuid for share;
      if not found or i.brand_id is distinct from p.brand_id then raise exception 'Product must belong to the plant company'; end if;
      if exists(select 1 from public.purchase_items where tenant_id=p_tenant and purchase_id=p_purchase
        and item_id=i.item_id and type=(x->>'type')::public.purchase_type) then raise exception 'Duplicate product and purchase type'; end if;
      insert into public.purchase_items(tenant_id,purchase_id,item_id,type,quantity,empty_dispatched,billed_quantity,unit_price,line_total)
        values(p_tenant,p_purchase,i.item_id,(x->>'type')::public.purchase_type,q,e,q,price,q*price);
    end loop;
  else
    -- After dispatch the exact saved line set is required. Only prices change.
    if jsonb_array_length(p_lines) <> (select count(*) from public.purchase_items where tenant_id=p_tenant and purchase_id=p_purchase)
      or (select count(distinct value->>'purchase_item_id') from jsonb_array_elements(p_lines)) <> jsonb_array_length(p_lines) then
      raise exception 'Dispatched products are locked';
    end if;
    for x in select value from jsonb_array_elements(p_lines) loop
      line_id := (x->>'purchase_item_id')::uuid;
      if not exists(select 1 from public.purchase_items pi where pi.tenant_id=p_tenant and pi.purchase_id=p_purchase
        and pi.purchase_item_id=line_id and pi.item_id=(x->>'item_id')::uuid
        and pi.type::text=x->>'type' and pi.quantity=app_private.purchase_integer(x->'quantity')
        and pi.empty_dispatched=app_private.purchase_integer(x->'empty_dispatched')) then
        raise exception 'Truck, products and dispatched quantities are locked';
      end if;
      price := app_private.purchase_money((x->>'unit_price')::numeric);
      update public.purchase_items set unit_price=price,line_total=billed_quantity*price
        where tenant_id=p_tenant and purchase_id=p_purchase and purchase_item_id=line_id;
    end loop;
  end if;
end $$;

CREATE OR REPLACE FUNCTION public.create_purchase(p_payload jsonb) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare t uuid := app_private.require_permission('purchases:manage'); id uuid; b uuid; request uuid; plant uuid; original jsonb;
begin
  request := (p_payload->>'request_id')::uuid;
  if request is null then raise exception 'Creation request ID is required'; end if;
  -- Transaction lock makes repeated creation requests return the same result.
  perform pg_advisory_xact_lock(hashtextextended(t::text || request::text,0));
  select purchase_id into id from public.purchases where tenant_id=t and request_id=request;
  if found then
    select request_payload into original from public.purchases where tenant_id=t and purchase_id=id;
    if original is not null and original is distinct from (p_payload-'request_id') then
      raise exception 'Purchase request ID was already used with different purchase details';
    end if;
    return jsonb_build_object('purchase_id',id);
  end if;
  if coalesce(p_payload->>'business_category','lpg') not in ('lpg','stove') then raise exception 'Invalid business category';end if;
  if p_payload->>'business_category'='stove' then
    insert into public.purchases(tenant_id,business_category,supplier_name,status,transport_cost,labour_cost,commission,notes,created_by,request_id,request_payload)
    values(t,'stove',trim(p_payload->>'supplier_name'),'created',0,0,0,p_payload->>'notes',auth.uid(),request,p_payload-'request_id') returning purchase_id into id;
    perform app_private.save_purchase_lines(t,id,p_payload->'items');perform app_private.recalculate_purchase(t,id);
    insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details) values(t,id,'created',auth.uid(),jsonb_build_object('business_category','stove','supplier_name',p_payload->>'supplier_name'));
    return jsonb_build_object('purchase_id',id);
  end if;
  plant := (p_payload->>'plant_id')::uuid;
  select gp.brand_id into b from public.gas_plants gp join public.lpg_brands lb
    on lb.tenant_id=gp.tenant_id and lb.brand_id=gp.brand_id
    where gp.tenant_id=t and gp.plant_id=plant and gp.is_active and lb.is_active for share of gp,lb;
  if b is null then raise exception 'Select an active plant with an active company'; end if;
  if p_payload->>'vehicle_id' is not null and not exists(select 1 from public.vehicles where tenant_id=t and vehicle_id=(p_payload->>'vehicle_id')::uuid) then
    raise exception 'Vehicle not found'; end if;
  insert into public.purchases(tenant_id,plant_id,brand_id,vehicle_id,status,transport_cost,labour_cost,commission,notes,created_by,request_id,request_payload)
  values(t,plant,b,(p_payload->>'vehicle_id')::uuid,'created',
    app_private.purchase_money(coalesce((p_payload->>'transport_cost')::numeric,0)),
    app_private.purchase_money(coalesce((p_payload->>'labour_cost')::numeric,0)),
    app_private.purchase_money(coalesce((p_payload->>'commission')::numeric,0)),p_payload->>'notes',auth.uid(),request,p_payload-'request_id')
  returning purchase_id into id;
  perform app_private.save_purchase_lines(t,id,coalesce(p_payload->'items','[]'::jsonb));
  perform app_private.recalculate_purchase(t,id);
  insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details)
    values(t,id,'created',auth.uid(),jsonb_build_object('plant_id',plant,'company_id',b));
  return jsonb_build_object('purchase_id',id);
end $$;

CREATE OR REPLACE FUNCTION public.receive_purchase(p_purchase_id uuid, p_revision integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare t uuid:=app_private.require_permission('purchases:manage'); p public.purchases; r record;
begin
  select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id for update;
  if not found then raise exception 'Purchase not found'; end if;
  if p.status='received' then return jsonb_build_object('already_received',true); end if;
  if p.business_category='stove' then
    if p.status<>'created' or p_revision is distinct from p.revision then raise exception 'Purchase changed or cannot be received';end if;
    -- Establish the supplier obligation before the receipt clears it.
    update public.purchases set status='in_transit' where tenant_id=t and purchase_id=p_purchase_id;
    for r in select * from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id order by item_id loop
      perform 1 from public.items where tenant_id=t and item_id=r.item_id for update;
      insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,filled_quantity_change,notes,created_by)
      values(t,r.item_id,'purchase','stove_purchase_receipt',p_purchase_id,r.quantity,'Stove purchase received',auth.uid());
    end loop;
    update public.purchase_items set received_quantity=quantity where tenant_id=t and purchase_id=p_purchase_id;
    update public.purchases set status='received',received_at=clock_timestamp(),revision=revision+1,updated_at=clock_timestamp() where tenant_id=t and purchase_id=p_purchase_id;
    insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details) values(t,p_purchase_id,'received',auth.uid(),jsonb_build_object('direct_receipt',true));
    return jsonb_build_object('purchase_id',p_purchase_id);
  end if;
  if p.status<>'in_transit' then raise exception 'Only an In Transit purchase can be received'; end if;
  if p_revision is distinct from p.revision then raise exception 'Purchase changed. Reload before receipt.' using errcode='P0001'; end if;
  perform 1 from public.vehicles where tenant_id=t and vehicle_id=p.vehicle_id for update;
  perform 1 from public.transits where tenant_id=t and purchase_id=p_purchase_id order by transit_id for update;
  update public.purchase_items set received_quantity=quantity where tenant_id=t and purchase_id=p_purchase_id;
  for r in select item_id,type,sum(quantity) qty from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id
    group by item_id,type order by item_id,type loop
    perform 1 from public.items where tenant_id=t and item_id=r.item_id for update;
    insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,filled_quantity_change,notes,created_by)
      values(t,r.item_id,case when r.type='package' then 'purchase' else 'refill' end,
      case when r.type='package' then 'purchase_receipt_new' else 'purchase_receipt_refill' end,
      p_purchase_id,r.qty,'Expected shipment received',auth.uid());
  end loop;
  update public.transits set status='returned',revision=revision+1,updated_at=now()
    where tenant_id=t and purchase_id=p_purchase_id and status='active';
  update public.purchases set status='received',received_at=now(),updated_at=now(),revision=revision+1
    where tenant_id=t and purchase_id=p_purchase_id;
  if not exists(select 1 from public.transits where tenant_id=t and vehicle_id=p.vehicle_id and status='active')
    and not exists(select 1 from public.purchases where tenant_id=t and vehicle_id=p.vehicle_id and status='in_transit') then
    update public.vehicles set status='idle',updated_at=now() where tenant_id=t and vehicle_id=p.vehicle_id;
  end if;
  insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details)
    values(t,p_purchase_id,'received',auth.uid(),jsonb_build_object('notes','Expected quantities received; transit costs remain open'));
  return jsonb_build_object('purchase_id',p_purchase_id);
end $$;

CREATE OR REPLACE FUNCTION public.dispatch_purchase(p_purchase_id uuid, p_revision integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare t uuid := app_private.require_permission('purchases:manage'); p public.purchases; tr public.vehicles; x record;
begin
  select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id for update;
  if not found then raise exception 'Purchase not found'; end if;
  if p.business_category='stove' then raise exception 'Stove purchases are received directly';end if;
  if p.status='in_transit' or p.status='received' then return jsonb_build_object('purchase_id',p_purchase_id,'already_dispatched',true); end if;
  if p.status<>'created' then raise exception 'Only a Created purchase can be dispatched'; end if;
  if p_revision is distinct from p.revision then raise exception 'Purchase changed. Reload before dispatch.' using errcode='P0001'; end if;
  select * into tr from public.vehicles where tenant_id=t and vehicle_id=p.vehicle_id for update;
  if not found or tr.status<>'idle' then raise exception 'Select an idle truck before dispatch'; end if;
  if exists(select 1 from public.transits where tenant_id=t and vehicle_id=p.vehicle_id and status='active')
    or exists(select 1 from public.purchases where tenant_id=t and vehicle_id=p.vehicle_id and status='in_transit') then
    raise exception 'Vehicle already has an active shipment'; end if;
  if not exists(select 1 from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id) then raise exception 'Add at least one product before dispatch'; end if;
  -- Existing Created plans need an explicit save before dispatch if they used
  -- independent empties. Do not silently rewrite a saved plan or its revision.
  if exists(select 1 from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id
    and empty_dispatched <> case when type='refill' then quantity else 0 end) then
    raise exception 'Refills exchange one empty cylinder per refill. Refresh and save the purchase before dispatch.';
  end if;
  perform 1 from public.gas_plants gp join public.lpg_brands b on b.tenant_id=gp.tenant_id and b.brand_id=gp.brand_id
    where gp.tenant_id=t and gp.plant_id=p.plant_id and gp.brand_id=p.brand_id and gp.is_active and b.is_active for share of gp,b;
  if not found then raise exception 'Plant company is unavailable'; end if;
  perform app_private.check_purchase_empties(t,(select jsonb_agg(to_jsonb(pi)) from public.purchase_items pi where tenant_id=t and purchase_id=p_purchase_id));
  -- Acquire stock locks in SKU order. Movement inserts apply the stock once.
  for x in select i.item_id,i.empty_quantity,i.brand_id,sum(pi.empty_dispatched) outgoing
    from public.purchase_items pi join public.items i on i.tenant_id=pi.tenant_id and i.item_id=pi.item_id
    where pi.tenant_id=t and pi.purchase_id=p_purchase_id group by i.tenant_id,i.item_id order by i.item_id loop
    perform 1 from public.items where tenant_id=t and item_id=x.item_id for update;
    if x.brand_id is distinct from p.brand_id then raise exception 'All products must belong to the plant company'; end if;
    if (select empty_quantity from public.items where tenant_id=t and item_id=x.item_id) < x.outgoing then
      raise exception 'Insufficient empty cylinder stock'; end if;
    if x.outgoing>0 then
      insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,empty_quantity_change,notes,created_by)
      values(t,x.item_id,'purchase','purchase_dispatch',p_purchase_id,-x.outgoing,'Empty cylinders dispatched to plant',auth.uid());
    end if;
  end loop;
  insert into public.transits(tenant_id,vehicle_id,purchase_id,status,transport_fee)
    values(t,p.vehicle_id,p_purchase_id,'active',p.transport_cost);
  update public.vehicles set status='going',updated_at=now() where tenant_id=t and vehicle_id=p.vehicle_id;
  update public.purchases set status='in_transit',dispatched_at=now(),payment_status=case when paid_amount>=payable_amount then 'paid' when paid_amount>0 then 'partial' else 'unpaid' end,paid_at=case when paid_amount>=payable_amount then now() end,updated_at=now(),revision=revision+1
    where tenant_id=t and purchase_id=p_purchase_id;
  insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details)
    values(t,p_purchase_id,'dispatched',auth.uid(),jsonb_build_object('empty_cylinders',
      (select sum(empty_dispatched) from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id)));
  return jsonb_build_object('purchase_id',p_purchase_id);
end $$;

CREATE OR REPLACE FUNCTION public.update_purchase(p_purchase_id uuid, p_payload jsonb, p_revision integer) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare t uuid := app_private.require_permission('purchases:manage'); p public.purchases; truck uuid; before_items jsonb;
begin
  select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id for update;
  if not found then raise exception 'Purchase not found'; end if;
  if p_revision is distinct from p.revision then raise exception 'Purchase changed. Reload it before saving.' using errcode='P0001'; end if;
  if p.status='received' and p_payload ?| array['items','commission','transport_cost','labour_cost'] then raise exception 'Received purchase costs and quantities are immutable';end if;
  if p.status='cancelled' or (p.status='received' and p.payment_status='paid') then raise exception 'Purchase is completed and locked'; end if;
  if p_payload ? 'plant_id' and (p_payload->>'plant_id')::uuid is distinct from p.plant_id
    or p_payload ? 'brand_id' and (p_payload->>'brand_id')::uuid is distinct from p.brand_id then
    raise exception 'Plant and company cannot change'; end if;
  select jsonb_agg(to_jsonb(pi)) into before_items from public.purchase_items pi where tenant_id=t and purchase_id=p_purchase_id;
  truck := case when p_payload ? 'vehicle_id' then (p_payload->>'vehicle_id')::uuid else p.vehicle_id end;
  if p.status<>'created' and truck is distinct from p.vehicle_id then raise exception 'Vehicle is locked after dispatch'; end if;
  if truck is not null and not exists(select 1 from public.vehicles where tenant_id=t and vehicle_id=truck) then raise exception 'Vehicle not found'; end if;
  if p.paid_amount>0 or p.payment_status='paid' or exists(select 1 from public.wallet_transactions where tenant_id=t and reference_id=p_purchase_id and amount<0 and type in ('purchase_expense','purchase_company_payment','purchase_logistics_payment','purchase_payment_company','purchase_payment_labour','purchase_payment_transport','purchase_payment')) then
    if p_payload ? 'items' or p_payload ? 'commission' or p_payload ? 'transport_cost' or p_payload ? 'labour_cost' then
      raise exception 'Financial values lock after the first payment'; end if;
  else
    update public.purchases set vehicle_id=truck where tenant_id=t and purchase_id=p_purchase_id;
    if p_payload ?| array['items','commission','transport_cost','labour_cost'] then
    if p.status<>'created' then
      perform 1 from public.vehicles where tenant_id=t and vehicle_id=p.vehicle_id for update;
      perform 1 from public.transits where tenant_id=t and purchase_id=p_purchase_id order by transit_id for update;
    end if;
    if p_payload ? 'items' then perform app_private.save_purchase_lines(t,p_purchase_id,p_payload->'items'); end if;
    update public.purchases set vehicle_id=truck,
      transport_cost=app_private.purchase_money(coalesce((p_payload->>'transport_cost')::numeric,transport_cost,0)),
      labour_cost=app_private.purchase_money(coalesce((p_payload->>'labour_cost')::numeric,labour_cost,0)),
      commission=app_private.purchase_money(coalesce((p_payload->>'commission')::numeric,commission))
      where tenant_id=t and purchase_id=p_purchase_id;
    perform app_private.recalculate_purchase(t,p_purchase_id);
    if exists(select 1 from public.transits where tenant_id=t and purchase_id=p_purchase_id and closed_at is not null)
      and (select transport_cost from public.purchases where tenant_id=t and purchase_id=p_purchase_id) is distinct from p.transport_cost then
      raise exception 'Transport fee is locked because the transit is closed'; end if;
    update public.transits set transport_fee=(select transport_cost from public.purchases where tenant_id=t and purchase_id=p_purchase_id)
      where tenant_id=t and purchase_id=p_purchase_id;

    end if;
  end if;
  update public.purchases set payment_status=case when status='created' then payment_status when paid_amount>=payable_amount then 'paid' when paid_amount>0 then 'partial' else 'unpaid' end,
    paid_at=case when status<>'created' and paid_amount>=payable_amount then coalesce(paid_at,now()) else paid_at end,notes=case when p_payload ? 'notes' then p_payload->>'notes' else notes end,
    updated_at=now(),revision=revision+1 where tenant_id=t and purchase_id=p_purchase_id;
  insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details)
    values(t,p_purchase_id,'updated',auth.uid(),jsonb_build_object('before',to_jsonb(p),'before_items',before_items,
      'after',(select to_jsonb(h) from public.purchases h where h.tenant_id=t and h.purchase_id=p_purchase_id),
      'items',(select jsonb_agg(to_jsonb(pi)) from public.purchase_items pi where pi.tenant_id=t and pi.purchase_id=p_purchase_id)));
  return jsonb_build_object('purchase_id',p_purchase_id);
end $$;

CREATE OR REPLACE FUNCTION public.record_purchase_payment(p_purchase_id uuid, p_payments jsonb, p_request_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare t uuid:=app_private.require_permission('purchases:manage'); p public.purchases; payload jsonb; prior public.finance_requests; result jsonb;
 x jsonb; w public.wallets; a numeric; part numeric; remaining numeric; company_left numeric; labour_left numeric; component text; id uuid; paid numeric:=0; detail jsonb:='[]';
begin
 if p_request_id is null then raise exception 'Payment request ID is required'; end if;
 payload:=jsonb_build_object('action','purchase_payment','purchase',p_purchase_id,'payments',p_payments,'actor',auth.uid());
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from payload then raise exception 'Request ID already used with different details'; end if; return prior.result; end if;
 select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id for update;
 if not found then raise exception 'Purchase not found'; end if;
 if p.status not in ('in_transit','received') and not (p.business_category='stove' and p.status='created') then raise exception 'Payments require a dispatched, non-cancelled purchase'; end if;
 if p.payment_status='paid' or p.payable_amount<=p.paid_amount then raise exception 'Purchase is already fully paid'; end if;
 if p_payments is null or jsonb_typeof(p_payments)<>'array' or jsonb_array_length(p_payments) not between 1 and 20 then raise exception 'Add between 1 and 20 payment entries'; end if;
 perform 1 from public.wallets where tenant_id=t and wallet_id in(select (value->>'wallet_id')::uuid from jsonb_array_elements(p_payments)) order by wallet_id for update;
 for x in select value from jsonb_array_elements(p_payments) loop
  if jsonb_typeof(x)<>'object' or jsonb_typeof(x->'amount') is distinct from 'number' then raise exception 'Payment amounts must be numbers'; end if;
  a:=app_private.purchase_money((x->>'amount')::numeric);
  if a<=0 or a<>(x->>'amount')::numeric then raise exception 'Enter a positive amount with at most two decimals'; end if;
  select * into w from public.wallets where tenant_id=t and wallet_id=(x->>'wallet_id')::uuid and is_active ;
  if not found then raise exception 'Select an active payment wallet belonging to this business'; end if;
  if length(coalesce(x->>'reference',''))>200 then raise exception 'Payment reference is too long'; end if;
  paid:=paid+a; if p.paid_amount+paid>p.payable_amount then raise exception 'Payments exceed the remaining purchase balance'; end if;
  insert into public.purchase_payments(tenant_id,purchase_id,wallet_id,wallet_name,method,amount,kind,component,operation_id,reference,created_by)
   values(t,p_purchase_id,w.wallet_id,w.name,w.kind,a,'payment','purchase',p_request_id,coalesce(x->>'reference',''),auth.uid()) returning payment_id into id;
  insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description,operation_id,purchase_payment_id)
   values(t,w.wallet_id,-a,'purchase_payment',p_purchase_id,'Purchase payment · '||w.name||' · '||coalesce(x->>'reference',''),p_request_id,id);
  detail:=detail||jsonb_build_array(jsonb_build_object('payment_id',id,'wallet_id',w.wallet_id,'wallet_name',w.name,'method',w.kind,'amount',a,'component','purchase'));
 end loop;
 update public.purchases set paid_amount=paid_amount+paid,payment_status=case when paid_amount+paid>=payable_amount then 'paid' else 'partial' end,
 paid_at=case when paid_amount+paid>=payable_amount then now() else null end,revision=revision+1,updated_at=now() where tenant_id=t and purchase_id=p_purchase_id;
 result:=jsonb_build_object('purchase_id',p_purchase_id,'paid',paid,'paid_amount',p.paid_amount+paid,'due',p.payable_amount-p.paid_amount-paid);
 insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details) values(t,p_purchase_id,'payment_recorded',auth.uid(),result||jsonb_build_object('payments',detail,'operation_id',p_request_id));
 insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,payload,result,auth.uid());
 return result;
end $$;

CREATE OR REPLACE FUNCTION public.initiate_purchase_cancellation(p_purchase_id uuid, p_revision integer, p_confirmation text, p_request_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare t uuid:=app_private.require_permission('purchases:manage'); p public.purchases; prior public.finance_requests; payload jsonb; result jsonb;
 r record; obligation_total numeric:=0; sources jsonb;
begin
 if not public.can_cancel_purchases() then raise exception 'Only the OWNER can cancel purchases' using errcode='42501'; end if;
 if p_confirmation is distinct from 'CANCEL' then raise exception 'Type exactly CANCEL to confirm cancellation'; end if;
 if p_request_id is null then raise exception 'Cancellation request ID is required'; end if;
 payload:=jsonb_build_object('action','purchase_cancel','purchase',p_purchase_id,'revision',p_revision,'confirmation',p_confirmation,'actor',auth.uid());
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from payload then raise exception 'Request ID already used with different details'; end if; return prior.result; end if;
 select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id for update;
 if not found then raise exception 'Purchase not found'; end if;
 if p.status='received' and p.business_category='lpg' then raise exception 'Received purchases can never be cancelled'; end if;
 if p.status='cancelled' then raise exception 'Purchase is already cancelled'; end if;
 if p_revision is distinct from p.revision then raise exception 'Purchase changed. Reload before cancellation.' using errcode='P0001'; end if;
 perform 1 from public.vehicles where tenant_id=t and vehicle_id=p.vehicle_id for update;
 perform 1 from public.transits where tenant_id=t and purchase_id=p_purchase_id order by transit_id for update;
 insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details) values(t,p_purchase_id,'cancellation_confirmed',auth.uid(),jsonb_build_object('previous_status',p.status,'confirmation','CANCEL','operation_id',p_request_id,'before',to_jsonb(p)));
 if p.business_category='stove' and p.status='received' then
  for r in select pi.item_id,sum(pi.quantity) qty from public.purchase_items pi where pi.tenant_id=t and pi.purchase_id=p_purchase_id group by pi.item_id order by pi.item_id loop
   perform 1 from public.items where tenant_id=t and item_id=r.item_id for update;
   if (select filled_quantity from public.items where tenant_id=t and item_id=r.item_id)<r.qty then raise exception 'Purchased stock has been consumed; return stock before cancellation';end if;
   insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,filled_quantity_change,notes,created_by)
   values(t,r.item_id,'purchase_adjustment','stove_purchase_cancellation',p_purchase_id,-r.qty,'Stove purchase cancelled',auth.uid());
  end loop;

 end if;
 -- LPG retains its pre-receipt cancellation boundary.
 for r in select m.item_id,sum(m.empty_quantity_change) empties from public.inventory_movements m where m.tenant_id=t and
 m.reference_id=p_purchase_id and m.reference_type='purchase_dispatch' group by m.item_id order by m.item_id loop
  perform 1 from public.items where tenant_id=t and item_id=r.item_id for update;
  if r.empties<>0 then insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,empty_quantity_change,notes,created_by)
   values(t,r.item_id,'purchase_adjustment','purchase_cancellation',p_purchase_id,-r.empties,'Cancelled purchase: dispatched empties returned',auth.uid()); end if;
 end loop;
 -- Refund only evidence of actual purchasing-business debits. Historical settled
 -- headers with no ledger attribution never create fictional money to refund.
 for r in select component,greatest(0,-sum(amount)) amount,jsonb_agg(evidence order by created_at,transaction_id) sources from (
  select x.amount,x.created_at,x.transaction_id,'purchase' component,
   jsonb_build_object('transaction_id',x.transaction_id,'payment_id',x.purchase_payment_id,'wallet_id',x.wallet_id,'wallet_name',x.wallet_name_snapshot,'method',x.wallet_method_snapshot,'amount',x.amount,'description',x.description,'created_at',x.created_at) evidence
  from public.wallet_transactions x join public.wallets w using(tenant_id,wallet_id) where x.tenant_id=t and x.reference_id=p_purchase_id 
   and x.type in ('purchase_expense','purchase_company_payment','purchase_logistics_payment','purchase_payment_company','purchase_payment_labour','purchase_payment_transport','purchase_payment')
 ) q group by component loop
  if r.amount>0 then
   insert into public.purchase_refund_obligations(tenant_id,purchase_id,component,amount,sources,created_by)
    values(t,p_purchase_id,r.component,r.amount,r.sources,auth.uid());
   obligation_total:=obligation_total+r.amount;

  end if;
 end loop;
 update public.transits set status='cancelled',revision=revision+1,updated_at=now() where tenant_id=t and purchase_id=p_purchase_id;
 update public.purchases set status='cancelled',cancelled_at=now(),refund_due=obligation_total,financial_closed_at=case when obligation_total=0 then now() end,
  updated_at=now(),revision=revision+1 where tenant_id=t and purchase_id=p_purchase_id;
 if not exists(select 1 from public.transits where tenant_id=t and vehicle_id=p.vehicle_id and status='active')
  and not exists(select 1 from public.purchases where tenant_id=t and vehicle_id=p.vehicle_id and status='in_transit') then
  update public.vehicles set status='idle',updated_at=now() where tenant_id=t and vehicle_id=p.vehicle_id;
 end if;
 result:=jsonb_build_object('purchase_id',p_purchase_id,'refund_due',obligation_total,'financially_closed',obligation_total=0);
 insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details) values(t,p_purchase_id,'cancellation_initiated',auth.uid(),result||jsonb_build_object('notes','Dispatched empties returned; truck released; transit cancelled. Incurred operating costs preserved. Refunds require separate settlement.'));
 if obligation_total=0 then insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details) values(t,p_purchase_id,'financially_closed',auth.uid(),result); end if;
 insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,payload,result,auth.uid());
 return result;
end $$;

CREATE OR REPLACE FUNCTION app_private.purchase_rows(t uuid, ids uuid[]) RETURNS SETOF jsonb
    LANGUAGE sql STABLE
    SET search_path TO ''
    AS $$
select to_jsonb(p) || jsonb_build_object(
    'vehicle_name',tr.name,'plant_name',coalesce(gp.plant_name,p.supplier_name),'company_name',b.brand_name,
    'operating_cost',(select coalesce(sum(total_cost),0) from public.transits where tenant_id=t and purchase_id=p.purchase_id),
    'items',coalesce((select jsonb_agg(to_jsonb(pi)||jsonb_build_object('product_name',i.product_name,'brand_name',lb.brand_name,
      'size_kg',i.size_kg,'mouth_size',i.mouth_size) order by pi.created_at,pi.purchase_item_id)
      from public.purchase_items pi join public.items i on i.tenant_id=pi.tenant_id and i.item_id=pi.item_id
      left join public.lpg_brands lb on lb.tenant_id=i.tenant_id and lb.brand_id=i.brand_id
      where pi.tenant_id=t and pi.purchase_id=p.purchase_id),'[]'::jsonb))
    from public.purchases p left join public.vehicles tr on tr.tenant_id=p.tenant_id and tr.vehicle_id=p.vehicle_id
    left join public.gas_plants gp on gp.tenant_id=p.tenant_id and gp.plant_id=p.plant_id
    left join public.lpg_brands b on b.tenant_id=p.tenant_id and b.brand_id=p.brand_id
    where p.tenant_id=t and p.purchase_id=any(ids) order by p.created_at desc,p.purchase_id;

$$;

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
    or ordering not in ('date_desc','date_asc','amount_desc','amount_asc') then raise exception 'Invalid purchase filters'; end if;
  if p_offset is null or p_limit is null or p_offset<0 or p_offset>1000000 or p_limit not between 1 and 100 then raise exception 'Invalid purchase page'; end if;
  searching:=exists(select 1 from regexp_split_to_table(coalesce(p_filters->>'search',''),'\s*,\s*') g where btrim(g)<>'');
  with matching as materialized (
    select p.purchase_id,p.created_at,p.total_cost from public.purchases p
    left join public.vehicles tr on tr.tenant_id=t and tr.vehicle_id=p.vehicle_id
    left join public.gas_plants gp on gp.tenant_id=t and gp.plant_id=p.plant_id
    left join public.lpg_brands b on b.tenant_id=t and b.brand_id=p.brand_id
    where p.tenant_id=t and (nullif(p_filters->>'business_category','') is null or p.business_category=p_filters->>'business_category')
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

CREATE OR REPLACE FUNCTION public.get_sale_receipt(p_sale_id uuid) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare t uuid:=app_private.require_permission('receipts:print'); result jsonb;
begin
 select jsonb_build_object(
  'shop_name',business.business_name,
  'sale',jsonb_build_object('sale_id',s.sale_id,'created_at',s.created_at,'sale_tier',s.sale_tier,'business_category',s.business_category,
   'subtotal',s.subtotal,'discount_amount',s.discount_amount,'exchange_fee',s.exchange_fee,'total_amount',s.total_amount,'notes',s.notes,
   'customers',jsonb_build_object('name',c.name,'phone',c.phone),
   'sale_items',coalesce((select jsonb_agg(jsonb_build_object('item_id',si.item_id,'type',si.type,'quantity',si.quantity,
    'unit_price',si.unit_price,'line_total',si.line_total,'items',jsonb_build_object('item_id',i.item_id,'brand_id',i.brand_id,
    'product_name',i.product_name,'business_category',i.business_category,'size_kg',i.size_kg,'mouth_size',i.mouth_size,'lpg_brands',jsonb_build_object('brand_name',b.brand_name))) order by si.sale_item_id)
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


revoke all on function public.get_stove_product_types(),public.save_stove_product_type(text,uuid,boolean),public.save_stove_product(jsonb,uuid) from public,anon;
grant execute on function public.get_stove_product_types(),public.save_stove_product_type(text,uuid,boolean),public.save_stove_product(jsonb,uuid) to authenticated;

