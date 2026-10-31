-- Checkout adjusts expected products only; later bottle settlement is unchanged.
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
  if category='lpg' and jsonb_typeof(p_bottles->'lines')='array' and exists(
    select 1 from jsonb_array_elements(p_bottles->'lines') received_line where not exists(
      select 1 from jsonb_array_elements(p_items) expected_line where expected_line->>'type'='empty_return' and expected_line->>'item_id'=received_line->>'received_item_id')) then
    raise exception 'Checkout accepts only expected empty-cylinder products. Use Bottle Settlement in Sales for different or additional products.';
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
