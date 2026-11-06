-- For LPG the existing filled quantity is the Gas count. For Stove it is the unit count.
-- Empty quantities are generated read projections, with a single stock writer.
alter table public.items drop constraint item_business_shape;
alter table public.items rename column empty_quantity to bottle_quantity;
alter table public.items disable trigger user;
update public.items set bottle_quantity=bottle_quantity+filled_quantity where business_category='lpg';
alter table public.items enable trigger user;
alter table public.items add column empty_quantity integer generated always as
  (case when business_category='lpg' then bottle_quantity-filled_quantity else 0 end) stored not null;
alter table public.items add constraint item_business_shape check (
  (business_category='lpg' and brand_id is not null and size_kg>0 and product_name is null and product_type_id is null
    and bottle_quantity>=filled_quantity and filled_quantity>=0)
  or (business_category='stove' and brand_id is null and size_kg is null and mouth_size is null
    and length(trim(product_name)) between 1 and 150 and product_type_id is not null
    and bottle_quantity=0 and filled_quantity>=0)
);

-- Movement identity, original date, and valuation evidence survive normalization.
-- A null Bottle delta distinguishes Stove movements from LPG movements.
alter table public.inventory_movements rename column empty_quantity_change to bottle_quantity_change;
alter table public.inventory_movements alter column bottle_quantity_change drop default,
  alter column bottle_quantity_change drop not null;
alter table public.inventory_movements disable trigger user;
update public.inventory_movements m
set bottle_quantity_change=case when i.business_category='lpg' then m.bottle_quantity_change+m.filled_quantity_change end
from public.items i where i.tenant_id=m.tenant_id and i.item_id=m.item_id;
alter table public.inventory_movements enable trigger user;
alter table public.inventory_movements add column empty_quantity_change integer generated always as
  (coalesce(bottle_quantity_change-filled_quantity_change,0)) stored not null;
comment on column public.items.filled_quantity is 'Canonical LPG Gas quantity, or the number of Stove units.';
comment on column public.items.bottle_quantity is 'Canonical on-hand LPG Bottle quantity, including shells in filled stock.';
comment on column public.inventory_movements.filled_quantity_change is 'Canonical LPG Gas or Stove unit delta.';
comment on column public.inventory_movements.bottle_quantity_change is 'Canonical LPG Bottle delta. Null for Stove.';

CREATE OR REPLACE FUNCTION app_private.action_adjust_inventory(p_payload jsonb, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_permission('inventory:adjust');body jsonb:=jsonb_build_object('action','inventory_adjustment','actor',auth.uid(),'body',p_payload);prior public.finance_requests;
 id uuid:=(p_payload->>'item_id')::uuid;f integer:=(p_payload->>'filled_quantity')::integer;e integer:=coalesce((p_payload->>'empty_quantity')::integer,0);kind text:=p_payload->>'kind';counter text;mid uuid;result jsonb;begin perform app_private.require_permission('inventory:adjust');
 if p_payload->>'date' is not null and (not isfinite((p_payload->>'date')::date) or (p_payload->>'date')::date>(now() at time zone 'Asia/Dhaka')::date) then raise exception 'Invalid stock accounting date';end if; if p_request_id is null then raise exception 'Request ID is required';end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from body then raise exception 'Request ID already used with different details';end if;return prior.result;end if;
 if f is null or f=0 and e=0 or abs(f)>1000000 or abs(e)>1000000 or kind is null or kind not in ('capital','gain','lost','stolen','damaged','other_loss')
 or nullif(trim(p_payload->>'reason'),'') is null or length(p_payload->>'reason')>1000 then raise exception 'Enter quantities, adjustment type and a reason';end if;
 if kind in ('capital','gain') and (f<0 or e<0) or kind in ('lost','stolen','damaged','other_loss') and (f>0 or e>0) then raise exception 'Adjustment quantities do not match its type';end if;
 if (p_payload->>'date')::date<(now() at time zone 'Asia/Dhaka')::date then perform 1 from public.items where tenant_id=t order by item_id for update;end if;perform 1 from public.items where tenant_id=t and item_id=id for update;if not found then raise exception 'Product not found';end if;
 counter:=case kind when 'capital' then 'capital' when 'gain' then 'other_income' else 'inventory_loss' end;
 if f>0 and (p_payload->>'filled_unit_cost') is null or e>0 and (p_payload->>'empty_unit_cost') is null then raise exception 'Unit costs are required for added inventory';end if;
 insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,filled_quantity_change,bottle_quantity_change,notes,created_by,valuation,created_at)
 values(t,id,case when f+e>0 then 'adjust_gain' else 'adjust_loss' end,'valued_adjustment',p_request_id,f,case when e<>0 or exists(select 1 from public.items where tenant_id=t and item_id=id and business_category='lpg') then f+e end,kind||': '||trim(p_payload->>'reason'),auth.uid(),
 jsonb_build_object('counter_account',counter,'filled_unit_cost',p_payload->'filled_unit_cost','filled_shell_unit_cost',p_payload->'filled_shell_unit_cost','empty_unit_cost',p_payload->'empty_unit_cost'),case when p_payload->>'date' is null or (p_payload->>'date')::date=(now() at time zone 'Asia/Dhaka')::date then clock_timestamp() else ((p_payload->>'date')::date+time '12:00') at time zone 'Asia/Dhaka' end) returning movement_id into mid;
 result:=jsonb_build_object('movement_id',mid);insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,result,auth.uid());return result;end $function$;

CREATE OR REPLACE FUNCTION app_private.action_create_pos_sale(p_customer_phone character varying, p_customer_name character varying, p_customer_shop_name character varying, p_customer_address text, p_customer_tier character varying, p_discount_amount numeric, p_exchange_fee numeric, p_notes text, p_items jsonb, p_customer_id uuid DEFAULT NULL::uuid, p_request_id uuid DEFAULT NULL::uuid, p_payments jsonb DEFAULT NULL::jsonb, p_bottles jsonb DEFAULT NULL::jsonb, p_sold_on date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  t uuid:=app_private.require_permission('pos:sell'); actor uuid:=auth.uid();
  tier text:=coalesce(p_customer_tier,'retail'); payload jsonb; saved public.sales;
  customer public.customers; sale uuid; x jsonb; stock record; qty integer; price numeric;
  expected numeric; subtotal numeric:=0; discount numeric; fee numeric; total numeric;
  refills bigint:=0; empties bigint:=0; filled_delta integer; empty_delta integer;
  category text;wallet uuid;sold_time timestamptz:=case when p_sold_on is null then clock_timestamp() else (p_sold_on+time '15:00') at time zone 'Asia/Dhaka' end; result jsonb; payments jsonb; paid numeric; bottles jsonb;
begin
  if p_sold_on is not null then if not isfinite(p_sold_on) or p_sold_on>(now() at time zone 'Asia/Dhaka')::date then raise exception 'Invalid sale business date';end if;if p_sold_on<>(now() at time zone 'Asia/Dhaka')::date then perform app_private.require_permission('sales:backdate');end if;end if; if p_request_id is null then raise exception 'Checkout request ID is required. Refresh the application.'; end if;
  payload:=jsonb_build_object('actor',actor,'customer_id',p_customer_id,'phone',trim(p_customer_phone),
    'name',p_customer_name,'shop',p_customer_shop_name,'address',p_customer_address,'tier',tier,
    'discount',coalesce(p_discount_amount,0),'fee',coalesce(p_exchange_fee,0),'notes',p_notes,'items',p_items,'payments',p_payments,'bottles',p_bottles);
  if p_sold_on is not null then payload:=payload||jsonb_build_object('sold_on',p_sold_on);end if; perform pg_advisory_xact_lock(hashtextextended(t::text||':pos:'||p_request_id::text,0));
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
  discount:=app_private.purchase_money(coalesce(p_discount_amount,0));if discount>0 then perform app_private.require_permission('sales:discount');end if;
  fee:=app_private.purchase_money(coalesce(p_exchange_fee,0));
  if nullif(trim(p_customer_phone),'') is null then raise exception 'Customer phone number is required to complete a sale'; end if;

  if p_bottles is not null and (jsonb_typeof(p_bottles)<>'object' or jsonb_typeof(p_bottles->'lines') is distinct from 'array') then raise exception 'Invalid received bottles'; end if;
  bottles:=coalesce(p_bottles,jsonb_build_object('lines',(select coalesce(jsonb_agg(jsonb_build_object('received_item_id',e.value->>'item_id','quantity',e.value->'quantity')),'[]') from jsonb_array_elements(p_items) e where e.value->>'type'='empty_return')));
  if p_sold_on<(now() at time zone 'Asia/Dhaka')::date then perform 1 from public.items where tenant_id=t order by item_id for update;end if;
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
    0::numeric + coalesce((select sum((r->>'quantity')::numeric) from jsonb_array_elements(bottles->'lines') r where (r->>'received_item_id')::uuid=i.item_id),0) empty
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
  if p_sold_on is null or p_sold_on=(now() at time zone 'Asia/Dhaka')::date then sold_time:=clock_timestamp();end if;
 insert into public.sales(tenant_id,customer_id,sale_tier,status,subtotal,discount_amount,exchange_fee,total_amount,
    notes,created_by,checkout_request_id,checkout_payload,business_category,created_at)
    values(t,customer.customer_id,tier,'completed',subtotal,discount,fee,total,p_notes,actor,p_request_id,payload,category,sold_time) returning sale_id into sale;
  insert into public.sale_items(tenant_id,sale_id,item_id,type,quantity,unit_price,line_total)
    select t,sale,(l->>'item_id')::uuid,(l->>'type')::public.sale_item_type,
      app_private.purchase_integer(l->'quantity'),(l->>'unit_price')::numeric,
      app_private.purchase_integer(l->'quantity')*(l->>'unit_price')::numeric
    from jsonb_array_elements(p_items) l;

  for x in select value from jsonb_array_elements(p_items) loop
    qty:=app_private.purchase_integer(x->'quantity'); price:=(x->>'unit_price')::numeric;
    filled_delta:=0; empty_delta:=0;
    if x->>'type'='refill' then filled_delta:=-qty;
    elsif x->>'type'='package' then filled_delta:=-qty; empty_delta:=0;
    else empty_delta:=0; end if;
    if x->>'type'<>'empty_return' then
    insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,
      filled_quantity_change,bottle_quantity_change,notes,created_by,valuation,created_at)
      values(t,(x->>'item_id')::uuid,'sale','sale',sale,filled_delta,case when category='lpg' then filled_delta+empty_delta end,'POS Sale #'||left(sale::text,8),actor,jsonb_build_object('sale_type',x->>'type'),sold_time);
    end if;
  end loop;
  if category='lpg' then perform app_private.receive_sale_bottles(t,sale,bottles,'checkout',p_request_id);end if;
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
end $function$;

CREATE OR REPLACE FUNCTION app_private.action_dispatch_purchase(p_purchase_id uuid, p_revision integer, p_dispatched_on date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid := app_private.require_permission('purchases:manage'); p public.purchases; tr public.vehicles; x record; dispatch_time timestamptz:=case when p_dispatched_on is null then clock_timestamp() else (p_dispatched_on+time '09:00') at time zone 'Asia/Dhaka' end;
begin perform app_private.require_permission('purchases:dispatch');
  select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id for update;
  if not found then raise exception 'Purchase not found'; end if; if p_dispatched_on is not null and (not isfinite(p_dispatched_on) or p_dispatched_on>(now() at time zone 'Asia/Dhaka')::date) then raise exception 'Invalid dispatch date';end if;
  if p.business_category='stove' and p.transport_cost=0 then raise exception 'Stove orders without internal transport are received directly';end if;
  if p.status='in_transit' or p.status='received' then return jsonb_build_object('purchase_id',p_purchase_id,'already_dispatched',true); end if;
  if p.status<>'created' then raise exception 'Only a Created purchase can be dispatched'; end if;
  if p_revision is distinct from p.revision then raise exception 'Purchase changed. Reload before dispatch.' using errcode='P0001'; end if;
  select * into tr from public.vehicles where tenant_id=t and vehicle_id=p.vehicle_id for update;
  if not found or tr.status<>'idle' then raise exception 'Select an idle truck before dispatch'; end if;
  if exists(select 1 from public.transits where tenant_id=t and vehicle_id=p.vehicle_id and status='active')
    or exists(select 1 from public.purchases where tenant_id=t and vehicle_id=p.vehicle_id and status='in_transit') then
    raise exception 'Vehicle already has an active shipment'; end if;
  if not exists(select 1 from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id) then raise exception 'Add at least one product before dispatch'; end if;
  perform 1 from public.employees where tenant_id=t and employee_id in(select employee_id from public.vehicle_assignments where tenant_id=t and vehicle_id=p.vehicle_id and ended_at is null) order by employee_id for update;
  if p.business_category='lpg' then perform 1 from public.gas_plants gp join public.lpg_brands b on b.tenant_id=gp.tenant_id and b.brand_id=gp.brand_id
    where gp.tenant_id=t and gp.plant_id=p.plant_id and gp.brand_id=p.brand_id and gp.is_active and b.is_active for share of gp,b;
  if not found then raise exception 'Plant company is unavailable'; end if;
  perform app_private.check_purchase_empties(t,(select jsonb_agg(to_jsonb(pi)) from public.purchase_items pi where tenant_id=t and purchase_id=p_purchase_id));end if;
  if p_dispatched_on<(now() at time zone 'Asia/Dhaka')::date then perform 1 from public.items where tenant_id=t order by item_id for update;end if;
 perform 1 from public.items where tenant_id=t and item_id in(select item_id from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id) order by item_id for update;
 if p_dispatched_on is null or p_dispatched_on=(now() at time zone 'Asia/Dhaka')::date then dispatch_time:=clock_timestamp();end if;
  -- Acquire stock locks in SKU order. Movement inserts apply the stock once.
  update public.purchase_items set empty_dispatched=case when p.business_category='lpg' then quantity-bottle_quantity else 0 end where tenant_id=t and purchase_id=p_purchase_id;
  for x in select i.item_id,i.empty_quantity,i.brand_id,sum(pi.empty_dispatched) outgoing
    from public.purchase_items pi join public.items i on i.tenant_id=pi.tenant_id and i.item_id=pi.item_id
    where pi.tenant_id=t and pi.purchase_id=p_purchase_id group by i.tenant_id,i.item_id order by i.item_id loop
    perform 1 from public.items where tenant_id=t and item_id=x.item_id for update;
    if p.business_category='lpg' and x.brand_id is distinct from p.brand_id then raise exception 'All products must belong to the plant company'; end if;
    if (select empty_quantity from public.items where tenant_id=t and item_id=x.item_id) < x.outgoing then
      raise exception 'Insufficient empty cylinder stock'; end if;
    if x.outgoing>0 then
      insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,bottle_quantity_change,notes,created_by,created_at)
      values(t,x.item_id,'purchase','purchase_dispatch',p_purchase_id,-x.outgoing,'Empty cylinders dispatched to plant',auth.uid(),dispatch_time);
    end if;
  end loop;
  insert into public.transits(tenant_id,vehicle_id,purchase_id,status,transport_fee,created_at,client_name,destination)
    values(t,p.vehicle_id,p_purchase_id,'active',p.transport_cost,dispatch_time,case when p.business_category='stove' then p.supplier_name end,case when p.business_category='stove' then 'Stove supplier collection' end);
  update public.vehicles set status='going',updated_at=now() where tenant_id=t and vehicle_id=p.vehicle_id;
  update public.purchases set status='in_transit',dispatched_at=dispatch_time,payment_status=case when paid_amount>=payable_amount then 'paid' when paid_amount>0 then 'partial' else 'unpaid' end,paid_at=case when paid_amount>=payable_amount then now() end,updated_at=now(),revision=revision+1
    where tenant_id=t and purchase_id=p_purchase_id;
  perform app_private.settle_internal_transport(t,p_purchase_id,(dispatch_time at time zone 'Asia/Dhaka')::date); insert into public.purchase_activity(tenant_id,purchase_id,created_by,message)
    values(t,p_purchase_id,auth.uid(),case when p.business_category='lpg' then
      format('Vehicle dispatched. %s empty cylinders sent.', (select coalesce(sum(empty_dispatched),0) from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id))
      else 'Vehicle dispatched.' end);
  return jsonb_build_object('purchase_id',p_purchase_id);
end $function$;

CREATE OR REPLACE FUNCTION app_private.action_initiate_purchase_cancellation(p_purchase_id uuid, p_revision integer, p_confirmation text, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_permission('purchases:manage'); p public.purchases; prior public.finance_requests; payload jsonb; result jsonb;
 r record; obligation_total numeric:=0; sources jsonb;
begin perform app_private.require_permission('purchases:cancel');
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
  if r.empties<>0 then insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,bottle_quantity_change,notes,created_by)
   values(t,r.item_id,'purchase_adjustment','purchase_cancellation',p_purchase_id,-r.empties,'Cancelled purchase: dispatched empties returned',auth.uid()); end if;
 end loop;
 -- Refund only evidence of actual purchasing-business debits. Historical settled
 -- headers with no ledger attribution never create fictional money to refund.
 for r in select component,greatest(0,-sum(amount)) amount,jsonb_agg(evidence order by created_at,transaction_id) sources from (
  select x.amount,x.created_at,x.transaction_id,'purchase' component,
   jsonb_build_object('transaction_id',x.transaction_id,'payment_id',x.purchase_payment_id,'wallet_id',x.wallet_id,'wallet_name',x.wallet_name_snapshot,'method',x.wallet_method_snapshot,'amount',x.amount,'description',x.description,'created_at',x.created_at) evidence
  from public.wallet_transactions x join public.wallets w using(tenant_id,wallet_id) where x.tenant_id=t and x.reference_id=p_purchase_id
   and x.type='purchase_payment'
 ) q group by component loop
  if r.amount>0 then
   insert into public.purchase_refund_obligations(tenant_id,purchase_id,component,amount,sources,created_by)
    values(t,p_purchase_id,r.component,r.amount,r.sources,auth.uid());
   obligation_total:=obligation_total+r.amount;

  end if;
 end loop;
 if p.status<>'received' then perform app_private.settle_internal_transport(t,p_purchase_id,(now() at time zone 'Asia/Dhaka')::date,true);end if; if p.status<>'received' then update public.transits set status='cancelled',revision=revision+1,updated_at=now() where tenant_id=t and purchase_id=p_purchase_id;end if;
 update public.purchases set status='cancelled',cancelled_at=now(),refund_due=obligation_total,financial_closed_at=case when obligation_total=0 then now() end,
  updated_at=now(),revision=revision+1 where tenant_id=t and purchase_id=p_purchase_id;
 if not exists(select 1 from public.transits where tenant_id=t and vehicle_id=p.vehicle_id and status='active')
  and not exists(select 1 from public.purchases where tenant_id=t and vehicle_id=p.vehicle_id and status='in_transit') then
  update public.vehicles set status='idle',updated_at=now() where tenant_id=t and vehicle_id=p.vehicle_id;
 end if;
 result:=jsonb_build_object('purchase_id',p_purchase_id,'refund_due',obligation_total,'financially_closed',obligation_total=0);
 insert into public.purchase_activity(tenant_id,purchase_id,created_by,message)
    values(t,p_purchase_id,auth.uid(),'Purchase cancelled.');
 insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,payload,result,auth.uid());
 return result;
end $function$;

CREATE OR REPLACE FUNCTION app_private.action_receive_purchase(p_purchase_id uuid, p_revision integer, p_received_on date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_permission('purchases:manage'); p public.purchases; r record; received_time timestamptz:=case when p_received_on is null then clock_timestamp() else (p_received_on+time '12:00') at time zone 'Asia/Dhaka' end;
begin perform app_private.require_permission('purchases:receive');
  select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id for update;
  if not found then raise exception 'Purchase not found'; end if;
  if p_received_on is not null and (not isfinite(p_received_on) or p_received_on>(now() at time zone 'Asia/Dhaka')::date or p.dispatched_at is not null and p_received_on<(p.dispatched_at at time zone 'Asia/Dhaka')::date) then raise exception 'Receipt date must be finite, not future, and on or after dispatch';end if;
 if p.status='received' then if p_received_on is not null and p_received_on<>(p.received_at at time zone 'Asia/Dhaka')::date then raise exception 'Shipment already received with different dates';end if;return jsonb_build_object('already_received',true); end if;
 perform 1 from public.vehicles where tenant_id=t and vehicle_id=p.vehicle_id for update;perform 1 from public.transits where tenant_id=t and purchase_id=p_purchase_id order by transit_id for update; if p_received_on<(now() at time zone 'Asia/Dhaka')::date then perform 1 from public.items where tenant_id=t order by item_id for update;else perform 1 from public.items where tenant_id=t and brand_id=p.brand_id order by item_id for update;end if; perform 1 from public.items where tenant_id=t and item_id in(select item_id from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id) order by item_id for update;
 if p_received_on is null or p_received_on=(now() at time zone 'Asia/Dhaka')::date then received_time:=clock_timestamp();end if;
  if p.business_category='stove' then
    if p.status not in ('created','in_transit') or p.status='created' and p.transport_cost>0 or p_revision is distinct from p.revision then raise exception 'Purchase changed or cannot be received';end if;
    -- Establish the supplier obligation before the receipt clears it.
    update public.purchases set status='in_transit',dispatched_at=coalesce(dispatched_at,received_time) where tenant_id=t and purchase_id=p_purchase_id;
    for r in select * from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id order by item_id loop
      perform 1 from public.items where tenant_id=t and item_id=r.item_id for update;
      insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,filled_quantity_change,notes,created_by,created_at)
      values(t,r.item_id,'purchase','stove_purchase_receipt',p_purchase_id,r.quantity,'Stove purchase received',auth.uid(),received_time);
    end loop;
    update public.purchases set status='received',received_at=received_time,revision=revision+1,updated_at=clock_timestamp() where tenant_id=t and purchase_id=p_purchase_id;
    update public.transits set status='returned',revision=revision+1,updated_at=clock_timestamp() where tenant_id=t and purchase_id=p_purchase_id and status='active';
 if p.vehicle_id is not null and not exists(select 1 from public.transits where tenant_id=t and vehicle_id=p.vehicle_id and status='active') and not exists(select 1 from public.purchases where tenant_id=t and vehicle_id=p.vehicle_id and status='in_transit') then update public.vehicles set status='idle',updated_at=clock_timestamp() where tenant_id=t and vehicle_id=p.vehicle_id;end if;
 insert into public.purchase_activity(tenant_id,purchase_id,created_by,message)
    values(t,p_purchase_id,auth.uid(),'Shipment received into inventory.');
    return jsonb_build_object('purchase_id',p_purchase_id);
  end if;
  if p.status<>'in_transit' then raise exception 'Only an In Transit purchase can be received'; end if;
  if p_revision is distinct from p.revision then raise exception 'Purchase changed. Reload before receipt.' using errcode='P0001'; end if;
  perform 1 from public.vehicles where tenant_id=t and vehicle_id=p.vehicle_id for update;
  perform 1 from public.transits where tenant_id=t and purchase_id=p_purchase_id order by transit_id for update;
  for r in select item_id,sum(quantity) qty from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id
    group by item_id order by item_id loop
    perform 1 from public.items where tenant_id=t and item_id=r.item_id for update;
    insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,filled_quantity_change,bottle_quantity_change,notes,created_by,created_at)
      values(t,r.item_id,'purchase','purchase_receipt',
      p_purchase_id,r.qty,r.qty,'Expected shipment received',auth.uid(),received_time);
  end loop;
  update public.transits set status='returned',revision=revision+1,updated_at=now()
    where tenant_id=t and purchase_id=p_purchase_id and status='active';
  update public.purchases set status='received',received_at=received_time,updated_at=now(),revision=revision+1
    where tenant_id=t and purchase_id=p_purchase_id;
  if not exists(select 1 from public.transits where tenant_id=t and vehicle_id=p.vehicle_id and status='active')
    and not exists(select 1 from public.purchases where tenant_id=t and vehicle_id=p.vehicle_id and status='in_transit') then
    update public.vehicles set status='idle',updated_at=now() where tenant_id=t and vehicle_id=p.vehicle_id;
  end if;
  insert into public.purchase_activity(tenant_id,purchase_id,created_by,message)
    values(t,p_purchase_id,auth.uid(),'Shipment received into inventory.');
  return jsonb_build_object('purchase_id',p_purchase_id);
end $function$;

CREATE OR REPLACE FUNCTION app_private.action_reverse_sale(p_sale_id uuid, p_reason text, p_confirmation text, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_permission('sales:cancel');s public.sales;prior public.finance_requests;body jsonb:=jsonb_build_object('action','sale_reversal','actor',auth.uid(),'sale',p_sale_id,'reason',p_reason,'confirmation',p_confirmation);r record;result jsonb;begin perform app_private.require_permission('sales:cancel');
 if p_request_id is null or p_confirmation is distinct from 'CANCEL' or nullif(trim(p_reason),'') is null or length(p_reason)>1000 then raise exception 'Reason, request ID and CANCEL confirmation are required';end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from body then raise exception 'Request ID already used';end if;return prior.result;end if;
 select * into s from public.sales where tenant_id=t and sale_id=p_sale_id for update;
 if not found or s.status<>'completed' then raise exception 'Completed sale not found';end if;
 if not exists(select 1 from public.inventory_cost_entries e join public.inventory_movements m using(tenant_id,movement_id) where e.tenant_id=t and m.reference_id=p_sale_id and m.reference_type='sale' and e.filled_change<0) or exists(select 1 from public.inventory_movements m where m.tenant_id=t and m.reference_id=p_sale_id and m.reference_type='sale' and not exists(select 1 from public.inventory_cost_entries e where e.tenant_id=t and e.movement_id=m.movement_id)) then raise exception 'Sale has no recorded carrying costs; reconcile its stock evidence before cancellation';end if;
 perform 1 from public.items where tenant_id=t and item_id in (select item_id from public.inventory_movements where tenant_id=t and reference_id=p_sale_id and reference_type='sale') order by item_id for update; for r in select item_id,-sum(filled_quantity_change) filled,-sum(empty_quantity_change) empties from public.inventory_movements where tenant_id=t and reference_id=p_sale_id and reference_type='sale' group by item_id order by item_id loop
  perform 1 from public.items where tenant_id=t and item_id=r.item_id for update;
  insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,filled_quantity_change,bottle_quantity_change,notes,created_by)
  values(t,r.item_id,'adjust_gain','sale_reversal',p_sale_id,r.filled,case when s.business_category='lpg' then r.filled+r.empties end,'Sale cancellation: '||trim(p_reason),auth.uid());
 end loop;
 perform app_private.sync_sale_bottle_reversal(t,p_sale_id,(now() at time zone 'Asia/Dhaka')::date);
 insert into public.customer_transactions(tenant_id,customer_id,type,amount,reference_id,created_by) values(t,s.customer_id,'invoice_charge',s.total_amount+s.additional_charges,p_sale_id,auth.uid());
 insert into public.sale_reversals(tenant_id,sale_id,reason,created_by) values(t,p_sale_id,trim(p_reason),auth.uid());
 update public.sales set status='voided',updated_at=clock_timestamp() where tenant_id=t and sale_id=p_sale_id;
 result:=jsonb_build_object('sale_id',p_sale_id,'refund_due',s.paid_amount);insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,result,auth.uid());return result;end $function$;

CREATE OR REPLACE FUNCTION app_private.receive_sale_bottles(t uuid, sid uuid, body jsonb, phase text, op uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare s public.sales; x jsonb; rid uuid; qty integer; expected bigint; received bigint; incoming bigint:=0;
 original bigint; previous bigint; note text:=btrim(coalesce(body->>'note',''));
begin
 select * into s from public.sales where tenant_id=t and sale_id=sid for update;
 if not found or s.status<>'completed' then raise exception 'Sale does not support bottle collection'; end if;
 if body is null or jsonb_typeof(body)<>'object' or jsonb_typeof(body->'lines') is distinct from 'array' or jsonb_array_length(body->'lines')>200 then raise exception 'Use up to 200 received products'; end if;
 if length(note)>1000 then raise exception 'Bottle note is too long'; end if;
 if body - array['lines','note','fee'] <> '{}'::jsonb or exists(select 1 from jsonb_array_elements(body->'lines') l where jsonb_typeof(l)<>'object' or l - array['received_item_id','quantity','acknowledged'] <> '{}'::jsonb) then raise exception 'Unsupported bottle fields'; end if;
 if phase='checkout' and coalesce((body->>'fee')::numeric,0)<>0 then raise exception 'Use the checkout exchange cost field'; end if;
 if exists(select 1 from jsonb_array_elements(body->'lines') l group by l->>'received_item_id' having count(*)>1) then raise exception 'Use one quantity per received product'; end if;
 select coalesce(sum(quantity),0) into expected from public.sale_items where type='empty_return' and tenant_id=t and sale_id=sid;
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
  select coalesce(sum(quantity),0) into original from public.sale_items where type='empty_return' and tenant_id=t and sale_id=sid and item_id=(x->>'received_item_id')::uuid;
  select coalesce(sum(quantity),0) into previous from public.sale_bottle_receipt_lines where tenant_id=t and sale_id=sid and received_item_id=(x->>'received_item_id')::uuid;
  if (original=0 or previous+(x->>'quantity')::integer>original) and coalesce((x->>'acknowledged')::boolean,false) is not true then raise exception 'Acknowledge unexpected products or receipts exceeding the original product quantity'; end if;
 end loop;
 insert into public.sale_bottle_receipts(tenant_id,sale_id,phase,operation_id,note,created_by,fee,created_at)
 values(t,sid,phase,op,note,auth.uid(),coalesce((body->>'fee')::numeric,0),case when phase='checkout' then s.created_at else clock_timestamp() end) returning receipt_id into rid;
 for x in select value from jsonb_array_elements(body->'lines') loop
  qty:=app_private.purchase_integer(x->'quantity');
  insert into public.sale_bottle_receipt_lines(tenant_id,receipt_id,sale_id,received_item_id,quantity,acknowledged)
  values(t,rid,sid,(x->>'received_item_id')::uuid,qty,coalesce((x->>'acknowledged')::boolean,false));
  insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,filled_quantity_change,bottle_quantity_change,notes,created_by,created_at)
  values(t,(x->>'received_item_id')::uuid,'sale','sale',sid,0,qty,'Bottle '||phase||' #'||rid::text||case when note='' then '' else ': '||note end,auth.uid(),case when phase='checkout' then s.created_at else clock_timestamp() end);
 end loop;
 return rid;
end $function$;

CREATE OR REPLACE FUNCTION app_private.snapshot_inventory_components()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare price numeric; category text;
begin
 select business_category into category from public.items where tenant_id=new.tenant_id and item_id=new.item_id;
 if (category='lpg') is distinct from (new.bottle_quantity_change is not null) then
  raise exception 'Stock movement requires LPG Gas and Bottle deltas or a Stove unit delta';
 end if;
 if new.reference_type='sale' and new.bottle_quantity_change-new.filled_quantity_change>0 then
  select new_price into price from public.product_buying_price_history where tenant_id=new.tenant_id and item_id=new.item_id and price_type='bottle' and effective_at<=new.created_at order by effective_at desc,entry_no desc limit 1;
  if price is null then raise exception 'Set this received brand''s Bottle buying price before accepting its empty cylinders';end if;
  new.valuation:=coalesce(new.valuation,'{}'::jsonb)||jsonb_build_object('bottle_unit_cost',price);
 end if;
 if new.valuation->>'counter_account' is not null and new.filled_quantity_change>0 and category='lpg' then
  if new.valuation->>'filled_shell_unit_cost' is null then raise exception 'A valued filled-stock contribution requires its Gas and Bottle acquisition split';end if;
 end if;
 return new;
end$function$;

CREATE OR REPLACE FUNCTION app_private.update_item_inventory()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
BEGIN
    UPDATE public.items
    SET
        filled_quantity = filled_quantity + NEW.filled_quantity_change,
        bottle_quantity = bottle_quantity + coalesce(NEW.bottle_quantity_change,0),
        updated_at = NOW()
    WHERE tenant_id = NEW.tenant_id AND item_id = NEW.item_id;

    RETURN NEW;
END;
$function$;
