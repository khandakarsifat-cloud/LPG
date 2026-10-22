-- Future transactions only: historical sales, stock and balances stay untouched.
alter table public.sales add column checkout_request_id uuid,
  add column checkout_payload jsonb, add column checkout_result jsonb;
create unique index sales_checkout_request_once on public.sales(tenant_id,checkout_request_id)
  where checkout_request_id is not null;
create unique index pos_sale_income_once on public.wallet_transactions(tenant_id,reference_id,type)
  where type='pos_sale_income';
alter table public.purchases add column request_payload jsonb;

-- Replacing the signature prevents an older client bypassing the request contract.
drop function public.create_pos_sale(varchar,varchar,varchar,text,varchar,numeric,numeric,text,jsonb,uuid);
create function public.create_pos_sale(
  p_customer_phone varchar,p_customer_name varchar,p_customer_shop_name varchar,p_customer_address text,
  p_customer_tier varchar,p_discount_amount numeric,p_exchange_fee numeric,p_notes text,p_items jsonb,
  p_customer_id uuid default null,p_request_id uuid default null
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  t uuid:=app_private.require_permission('pos:sell'); actor uuid:=auth.uid();
  tier text:=coalesce(p_customer_tier,'retail'); payload jsonb; saved public.sales;
  customer public.customers; sale uuid; x jsonb; stock record; qty integer; price numeric;
  expected numeric; subtotal numeric:=0; discount numeric; fee numeric; total numeric;
  refills bigint:=0; empties bigint:=0; filled_delta integer; empty_delta integer;
  wallet uuid; result jsonb;
begin
  if p_request_id is null then raise exception 'Checkout request ID is required. Refresh the application.'; end if;
  payload:=jsonb_build_object('actor',actor,'customer_id',p_customer_id,'phone',trim(p_customer_phone),
    'name',p_customer_name,'shop',p_customer_shop_name,'address',p_customer_address,'tier',tier,
    'discount',coalesce(p_discount_amount,0),'fee',coalesce(p_exchange_fee,0),'notes',p_notes,'items',p_items);
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
  discount:=app_private.purchase_money(coalesce(p_discount_amount,0));
  fee:=app_private.purchase_money(coalesce(p_exchange_fee,0));
  if nullif(trim(p_customer_phone),'') is null then raise exception 'Customer phone number is required to complete a sale'; end if;

  -- Every participating item is locked before any stock write, in the same order
  -- as purchases and inventory price saves. Price saves also lock the item first.
  for stock in select i.item_id from public.items i where i.tenant_id=t and i.item_id in
    (select (value->>'item_id')::uuid from jsonb_array_elements(p_items)) order by i.item_id for update
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
      when l.value->>'type'='empty_return' then (l.value->>'quantity')::numeric else 0 end) empty
    from jsonb_array_elements(p_items) l join public.items i on i.tenant_id=t and i.item_id=(l.value->>'item_id')::uuid
    group by i.tenant_id,i.item_id order by i.item_id loop
    if stock.filled_quantity+stock.filled<0 or stock.empty_quantity+stock.empty<0 then raise exception 'Insufficient stock'; end if;
  end loop;
  if p_customer_id is not null then
    select * into customer from public.customers where tenant_id=t and customer_id=p_customer_id;
    if not found then raise exception 'Selected customer was not found'; end if;
  else
    if exists(select 1 from public.customers where tenant_id=t and phone=trim(p_customer_phone)) then
      raise exception 'This phone number belongs to a saved customer. Select the saved customer before completing the sale.';
    end if;
    insert into public.customers(tenant_id,name,phone,shop_name,address,tier)
      values(t,coalesce(nullif(trim(p_customer_name),''),'Unknown'),trim(p_customer_phone),
        nullif(trim(p_customer_shop_name),''),nullif(trim(p_customer_address),''),tier) returning * into customer;
  end if;
  insert into public.sales(tenant_id,customer_id,sale_tier,status,subtotal,discount_amount,exchange_fee,total_amount,
    notes,created_by,checkout_request_id,checkout_payload)
    values(t,customer.customer_id,tier,'completed',subtotal,discount,fee,total,p_notes,actor,p_request_id,payload) returning sale_id into sale;
  for x in select value from jsonb_array_elements(p_items) loop
    qty:=app_private.purchase_integer(x->'quantity'); price:=(x->>'unit_price')::numeric;
    filled_delta:=0; empty_delta:=0;
    if x->>'type'='refill' then filled_delta:=-qty;
    elsif x->>'type'='package' then filled_delta:=-qty; empty_delta:=-qty;
    else empty_delta:=qty; end if;
    insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,
      filled_quantity_change,empty_quantity_change,notes,created_by)
      values(t,(x->>'item_id')::uuid,'sale','sale',sale,filled_delta,empty_delta,'POS Sale #'||left(sale::text,8),actor);
    insert into public.sale_items(tenant_id,sale_id,item_id,type,quantity,unit_price,line_total)
      values(t,sale,(x->>'item_id')::uuid,(x->>'type')::public.sale_item_type,qty,price,qty*price);
  end loop;
  insert into public.customer_transactions(tenant_id,customer_id,type,amount,reference_id,created_by) values
    (t,customer.customer_id,'invoice_charge',-total,sale,actor),(t,customer.customer_id,'payment_receipt',total,sale,actor);
  perform app_private.ensure_tenant_wallets(t);
  perform 1 from public.wallets where tenant_id=t order by wallet_id for update;
  select wallet_id into wallet from public.wallets where tenant_id=t and type='dealership';
  insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description)
    values(t,wallet,total,'pos_sale_income',sale,'Completed POS sale');
  update public.wallets set balance=balance+total,updated_at=now() where tenant_id=t and wallet_id=wallet;
  result:=jsonb_build_object('sale_id',sale,'sale_tier',tier,'customer_id',customer.customer_id,'subtotal',subtotal,
    'total_amount',total,'customer_phone',customer.phone,'customer_name',coalesce(nullif(trim(customer.name),''),'Unknown'));
  update public.sales set checkout_result=result where tenant_id=t and sale_id=sale;
  return result;
end $$;
alter function public.create_pos_sale(varchar,varchar,varchar,text,varchar,numeric,numeric,text,jsonb,uuid,uuid) owner to postgres;
revoke all on function public.create_pos_sale(varchar,varchar,varchar,text,varchar,numeric,numeric,text,jsonb,uuid,uuid) from public,anon;
grant execute on function public.create_pos_sale(varchar,varchar,varchar,text,varchar,numeric,numeric,text,jsonb,uuid,uuid) to authenticated;

-- Creation replays cannot silently acknowledge a changed purchase.
create or replace function public.create_purchase(p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
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
  plant := (p_payload->>'plant_id')::uuid;
  select gp.brand_id into b from public.gas_plants gp join public.lpg_brands lb
    on lb.tenant_id=gp.tenant_id and lb.brand_id=gp.brand_id
    where gp.tenant_id=t and gp.plant_id=plant and gp.is_active and lb.is_active for share of gp,lb;
  if b is null then raise exception 'Select an active plant with an active company'; end if;
  if p_payload->>'truck_id' is not null and not exists(select 1 from public.trucks where tenant_id=t and truck_id=(p_payload->>'truck_id')::uuid) then
    raise exception 'Truck not found'; end if;
  insert into public.purchases(tenant_id,plant_id,brand_id,truck_id,status,transport_cost,labour_cost,commission,notes,created_by,request_id,request_payload)
  values(t,plant,b,(p_payload->>'truck_id')::uuid,'created',
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

-- Lock package-only SKUs too, before line saves take any other item locks.
create or replace function app_private.check_purchase_empties(t uuid, lines jsonb) returns void
language plpgsql set search_path='' as $$
declare x record; shortages jsonb := '[]';
begin
  for x in select i.item_id from public.items i where i.tenant_id=t and i.item_id in
    (select (value->>'item_id')::uuid from jsonb_array_elements(lines))
    order by i.item_id for update loop null; end loop;
  select coalesce(jsonb_agg(jsonb_build_object('item_id',s.item_id,'product',s.product,
    'required',s.required,'available',s.available,'missing',s.required-s.available)),'[]') into shortages
  from (select i.item_id,concat(coalesce(b.brand_name,i.brand),' ',i.size_kg,' kg ',i.mouth_size) product,
    sum(app_private.purchase_integer(l.value->'quantity')) required,i.empty_quantity available
    from jsonb_array_elements(lines) l join public.items i on i.tenant_id=t and i.item_id=(l.value->>'item_id')::uuid
    left join public.lpg_brands b on b.tenant_id=i.tenant_id and b.brand_id=i.brand_id
    where l.value->>'type'='refill' group by i.item_id,i.brand,b.brand_name,i.size_kg,i.mouth_size,i.empty_quantity
    having sum(app_private.purchase_integer(l.value->'quantity'))>i.empty_quantity) s;
  if jsonb_array_length(shortages)>0 then
    raise exception 'Not enough empty cylinders' using detail=shortages::text;
  end if;
end $$;

notify pgrst,'reload schema';
