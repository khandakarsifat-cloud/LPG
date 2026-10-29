-- Active-development normalization. This is a forward migration; applied history stays intact.
-- Only representation changes: do not replay stock movements or wallet/customer postings.
set lock_timeout = '10s';

create temp table canonical_preservation as select
 (select md5(coalesce(jsonb_agg(jsonb_build_array(tenant_id,item_id,filled_quantity,empty_quantity) order by tenant_id,item_id)::text,'')) from public.items) stock,
 (select md5(coalesce(jsonb_agg(to_jsonb(x) order by tenant_id,wallet_id)::text,'')) from public.wallets x) wallets,
 (select md5(coalesce(jsonb_agg(to_jsonb(x) order by tenant_id,transaction_id)::text,'')) from public.wallet_transactions x) wallet_ledger,
 (select md5(coalesce(jsonb_agg(to_jsonb(x) order by tenant_id,transaction_id)::text,'')) from public.customer_transactions x) customer_ledger,
 (select md5(coalesce(jsonb_agg(to_jsonb(x)-'payment_tracking'-'bottle_tracking'-'checkout_payments'-'checkout_payload' order by tenant_id,sale_id)::text,'')) from public.sales x) sales;

do $validate$ begin
 if exists(select 1 from public.sale_bottle_obligations o full join
  (select tenant_id,sale_id,item_id,sum(quantity) expected_quantity from public.sale_items where type='empty_return' group by tenant_id,sale_id,item_id) si
  using(tenant_id,sale_id,item_id) join public.sales s on s.tenant_id=coalesce(o.tenant_id,si.tenant_id) and s.sale_id=coalesce(o.sale_id,si.sale_id)
  where s.bottle_tracking and o.expected_quantity is distinct from si.expected_quantity)
 then raise exception 'Bottle expectations differ from original sale lines'; end if;
 if exists(select 1 from public.items where cylinder_weight is not null and replace(cylinder_weight::text,'kg','')::numeric<>size_kg)
 then raise exception 'Cylinder weight differs from canonical size'; end if;
 if exists(select 1 from public.sales s where not bottle_tracking and exists(select 1 from public.sale_bottle_receipts r where r.tenant_id=s.tenant_id and r.sale_id=s.sale_id))
 then raise exception 'Untracked sale already has bottle receipts'; end if;
end $validate$;

-- Old empty returns were physically received at checkout. Save those facts only;
-- the inventory ledger already contains their stock credit. Empty receipts are unnecessary.
insert into public.sale_bottle_receipts(tenant_id,sale_id,phase,operation_id,note,created_by,created_at)
 select s.tenant_id,s.sale_id,'checkout',gen_random_uuid(),'Receipt normalized from recorded checkout returns',s.created_by,s.created_at
 from public.sales s where not s.bottle_tracking and exists(select 1 from public.sale_items si where si.tenant_id=s.tenant_id and si.sale_id=s.sale_id and si.type='empty_return');
insert into public.sale_bottle_receipt_lines(tenant_id,receipt_id,sale_id,received_item_id,quantity)
 select s.tenant_id,r.receipt_id,s.sale_id,si.item_id,sum(si.quantity)
 from public.sales s join public.sale_bottle_receipts r using(tenant_id,sale_id)
 join public.sale_items si using(tenant_id,sale_id) where not s.bottle_tracking and si.type='empty_return'
 group by s.tenant_id,r.receipt_id,s.sale_id,si.item_id;

-- Acknowledgement replaces the abandoned expected-to-actual allocation model.
alter table public.sale_bottle_receipt_lines disable trigger immutable_bottle_line;
update public.sale_bottle_receipt_lines set acknowledged=true
 where not acknowledged and (allow_incompatible or expected_item_id is distinct from received_item_id and expected_item_id is not null);
alter table public.sale_bottle_receipt_lines enable trigger immutable_bottle_line;

-- Materialize missing per-type values once, retaining actors, rates, IDs and dates.
alter table public.product_commission_rates disable trigger product_commission_immutable;
update public.product_commission_rates set package_commission_per_unit=commission_per_unit where package_commission_per_unit is null;
alter table public.product_commission_rates enable trigger product_commission_immutable;
alter table public.product_commission_rates alter column package_commission_per_unit set not null;
alter table public.product_commission_rates rename column commission_per_unit to refill_commission_per_unit;

-- Normalize the payload shape once; completed requests still return their saved result.
update public.sales set checkout_payload=checkout_payload||jsonb_build_object('payments',checkout_payload->'payments','bottles',checkout_payload->'bottles') where checkout_payload is not null;

-- Resolve product relationships before dropping duplicated display/weight fields.
insert into public.lpg_brands(tenant_id,brand_name)
 select distinct tenant_id,coalesce(nullif(btrim(brand),''),'Unassigned') from public.items where brand_id is null
 on conflict(tenant_id,brand_name) do nothing;
update public.items i set brand_id=b.brand_id from public.lpg_brands b
 where i.brand_id is null and b.tenant_id=i.tenant_id and b.brand_name=coalesce(nullif(btrim(i.brand),''),'Unassigned');
alter table public.items alter column brand_id set not null;
alter table public.items drop constraint fk_items_brand_id;
alter table public.items add constraint fk_items_brand_id foreign key(tenant_id,brand_id) references public.lpg_brands(tenant_id,brand_id);

-- Exact old purchase notes can be linked once using the existing tenant-qualified parent.
-- Do not guess relationships from arbitrary UUIDs or short notes.
do $references$ begin
update public.inventory_movements m set reference_id=p.purchase_id,
 reference_type=case when m.notes='Empty bottles sent for refill (Purchase '||p.purchase_id||')' then 'purchase_dispatch' else 'purchase_history' end
 from public.purchases p where p.tenant_id=m.tenant_id and m.reference_id is null and m.notes in
 ('Empty bottles sent for refill (Purchase '||p.purchase_id||')','Received goods from Purchase '||p.purchase_id,'Quantity adjustment for Purchase '||p.purchase_id);
end $references$;
-- Operational status is stored, never synthesized by list readers. No costs are posted here.
update public.transits tr set status='completed' from public.purchases p
 where p.tenant_id=tr.tenant_id and p.purchase_id=tr.purchase_id and p.status='received' and tr.status='active';
update public.purchase_items pi set received_quantity=pi.quantity from public.purchases p
 where p.tenant_id=pi.tenant_id and p.purchase_id=pi.purchase_id and p.status='received' and pi.received_quantity is null;


CREATE OR REPLACE FUNCTION app_private.check_purchase_empties(t uuid, lines jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare x record; shortages jsonb := '[]';
begin
  for x in select i.item_id from public.items i where i.tenant_id=t and i.item_id in
    (select (value->>'item_id')::uuid from jsonb_array_elements(lines))
    order by i.item_id for update loop null; end loop;
  select coalesce(jsonb_agg(jsonb_build_object('item_id',s.item_id,'product',s.product,
    'required',s.required,'available',s.available,'missing',s.required-s.available)),'[]') into shortages
  from (select i.item_id,concat(b.brand_name,' ',i.size_kg,' kg ',i.mouth_size) product,
    sum(app_private.purchase_integer(l.value->'quantity')) required,i.empty_quantity available
    from jsonb_array_elements(lines) l join public.items i on i.tenant_id=t and i.item_id=(l.value->>'item_id')::uuid
    left join public.lpg_brands b on b.tenant_id=i.tenant_id and b.brand_id=i.brand_id
    where l.value->>'type'='refill' group by i.item_id,b.brand_name,i.size_kg,i.mouth_size,i.empty_quantity
    having sum(app_private.purchase_integer(l.value->'quantity'))>i.empty_quantity) s;
  if jsonb_array_length(shortages)>0 then
    raise exception 'Not enough empty cylinders' using detail=shortages::text;
  end if;
end $function$;

CREATE OR REPLACE FUNCTION app_private.guard_purchase_company()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  if new.brand_id is distinct from old.brand_id then
    if tg_table_name='gas_plants' then
      if exists(select 1 from public.purchases where tenant_id=old.tenant_id and plant_id=old.plant_id) then
        raise exception 'A purchased plant cannot change company'; end if;
    else
      if exists(select 1 from public.purchase_items pi join public.purchases p on p.tenant_id=pi.tenant_id and p.purchase_id=pi.purchase_id
        where pi.tenant_id=old.tenant_id and pi.item_id=old.item_id) then
        raise exception 'A purchased product cannot change company'; end if;
    end if;
  end if;
  return new;
end $function$;

CREATE OR REPLACE FUNCTION app_private.purchase_rows(t uuid, ids uuid[])
 RETURNS SETOF jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
select to_jsonb(p) || jsonb_build_object(
    'truck_name',tr.name,'plant_name',gp.plant_name,'company_name',b.brand_name,
    'operating_cost',(select coalesce(sum(total_cost),0) from public.transits where tenant_id=t and purchase_id=p.purchase_id),
    'items',coalesce((select jsonb_agg(to_jsonb(pi)||jsonb_build_object('brand_name',lb.brand_name,
      'size_kg',i.size_kg,'mouth_size',i.mouth_size) order by pi.created_at,pi.purchase_item_id)
      from public.purchase_items pi join public.items i on i.tenant_id=pi.tenant_id and i.item_id=pi.item_id
      left join public.lpg_brands lb on lb.tenant_id=i.tenant_id and lb.brand_id=i.brand_id
      where pi.tenant_id=t and pi.purchase_id=p.purchase_id),'[]'::jsonb))
    from public.purchases p left join public.trucks tr on tr.tenant_id=p.tenant_id and tr.truck_id=p.truck_id
    left join public.gas_plants gp on gp.tenant_id=p.tenant_id and gp.plant_id=p.plant_id
    left join public.lpg_brands b on b.tenant_id=p.tenant_id and b.brand_id=p.brand_id
    where p.tenant_id=t and p.purchase_id=any(ids) order by p.created_at desc,p.purchase_id;

$function$;

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
end $function$;

CREATE OR REPLACE FUNCTION app_private.receive_sale_payments(t uuid, sid uuid, entries jsonb, phase text, op uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare s public.sales; x jsonb; w public.wallets; paid numeric:=0; amount numeric; pid uuid;
begin
 select * into s from public.sales where tenant_id=t and sale_id=sid for update;
 if not found or s.status<>'completed' then raise exception 'Sale does not support payment collection'; end if;
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
end $function$;

CREATE OR REPLACE FUNCTION public.collect_sale_bottles(p_sale_id uuid, p_payload jsonb, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_permission('sales:collect_bottles'); prior public.finance_requests;
 payload jsonb; s public.sales; rid uuid; cost numeric; result jsonb;
begin
 if p_request_id is null then raise exception 'Bottle request ID is required'; end if;
 payload:=jsonb_build_object('action','bottles','sale',p_sale_id,'body',p_payload,'actor',auth.uid());
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 -- Completed operations retain their original payload and result.
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
 if not found then raise exception 'Sale does not support bottle collection'; end if;
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
end $function$;

CREATE OR REPLACE FUNCTION public.create_pos_sale(p_customer_phone character varying, p_customer_name character varying, p_customer_shop_name character varying, p_customer_address text, p_customer_tier character varying, p_discount_amount numeric, p_exchange_fee numeric, p_notes text, p_items jsonb, p_customer_id uuid DEFAULT NULL::uuid, p_request_id uuid DEFAULT NULL::uuid, p_payments jsonb DEFAULT NULL::jsonb, p_bottles jsonb DEFAULT NULL::jsonb)
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
  wallet uuid; result jsonb; payments jsonb; paid numeric; bottles jsonb;
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
    notes,created_by,checkout_request_id,checkout_payload)
    values(t,customer.customer_id,tier,'completed',subtotal,discount,fee,total,p_notes,actor,p_request_id,payload) returning sale_id into sale;
  insert into public.sale_items(tenant_id,sale_id,item_id,type,quantity,unit_price,line_total)
    select t,sale,(l->>'item_id')::uuid,(l->>'type')::public.sale_item_type,
      app_private.purchase_integer(l->'quantity'),(l->>'unit_price')::numeric,
      app_private.purchase_integer(l->'quantity')*(l->>'unit_price')::numeric
    from jsonb_array_elements(p_items) l;
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
end $function$;

CREATE OR REPLACE FUNCTION public.get_customer_bottle_balance(p_customer_id uuid)
 RETURNS bigint
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_any_permission(array['customers:view','customers:manage','finance:view','finance:manage']); result bigint;
begin
 if not exists(select 1 from public.customers where tenant_id=t and customer_id=p_customer_id) then raise exception 'Customer not found'; end if;
 select coalesce(sum(greatest(0,
 (select coalesce(sum(quantity),0) from public.sale_items where type='empty_return' and tenant_id=t and sale_id=s.sale_id)-
 (select coalesce(sum(quantity),0) from public.sale_bottle_receipt_lines where tenant_id=t and sale_id=s.sale_id))),0) into result
 from public.sales s where s.tenant_id=t and s.customer_id=p_customer_id and s.status='completed';
 return result;
end $function$;

CREATE OR REPLACE FUNCTION public.get_customer_directory(p_filters jsonb DEFAULT '{}'::jsonb, p_offset integer DEFAULT 0, p_limit integer DEFAULT 12, p_customer_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
 SET plan_cache_mode TO 'force_custom_plan'
AS $function$
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
      greatest(0,s.total_amount+s.additional_charges-s.paid_amount) due
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
end $function$;

CREATE OR REPLACE FUNCTION public.get_customer_filter_products()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_any_permission(array['customers:view','customers:manage']);
begin
  return jsonb_build_object('items',coalesce((select jsonb_agg(jsonb_build_object('item_id',i.item_id,'brand_id',i.brand_id,'size_kg',i.size_kg,'mouth_size',i.mouth_size,'lpg_brands',case when b.brand_id is null then null else jsonb_build_object('brand_id',b.brand_id,'brand_name',b.brand_name) end)) from public.items i left join public.lpg_brands b on b.tenant_id=i.tenant_id and b.brand_id=i.brand_id where i.tenant_id=t),'[]'::jsonb),
    'brands',coalesce((select jsonb_agg(jsonb_build_object('brand_id',b.brand_id,'brand_name',b.brand_name) order by b.display_order,b.brand_name,b.brand_id) from public.lpg_brands b where b.tenant_id=t),'[]'::jsonb));
end $function$;

CREATE OR REPLACE FUNCTION public.get_customer_transactions(p_customer_id uuid, p_filters jsonb DEFAULT '{}'::jsonb, p_offset integer DEFAULT 0, p_limit integer DEFAULT 4)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
        where si.tenant_id=t and si.sale_id=s.sale_id and concat_ws(' ',b.brand_name,i.size_kg,i.mouth_size) ilike '%'||(p_filters->>'search')||'%'))
  ), page as materialized (
    select * from matching order by created_at desc,sale_id desc limit p_limit offset p_offset
  ), enriched as (
    select p.*,q.refill,q.package,q.products from page p cross join lateral (
      select coalesce(sum(si.quantity) filter(where si.type='refill' and (ids is null or si.item_id=any(ids))),0) refill,
        coalesce(sum(si.quantity) filter(where si.type='package' and (ids is null or si.item_id=any(ids))),0) package,
        coalesce(string_agg(distinct concat_ws(' ',b.brand_name,i.size_kg||' kg',i.mouth_size),', '),'') products
      from public.sale_items si join public.items i on i.tenant_id=si.tenant_id and i.item_id=si.item_id
      left join public.lpg_brands b on b.tenant_id=i.tenant_id and b.brand_id=i.brand_id
      where si.tenant_id=t and si.sale_id=p.sale_id and si.type in ('refill','package')
    ) q
  ) select jsonb_build_object('total',(select count(*) from matching),'entries',coalesce((select jsonb_agg(to_jsonb(e) order by created_at desc,sale_id desc) from enriched e),'[]'::jsonb)) into result;
  return result;
end $function$;

CREATE OR REPLACE FUNCTION public.get_finance_dues(p_search text DEFAULT ''::text, p_customer_id uuid DEFAULT NULL::uuid, p_offset integer DEFAULT 0, p_limit integer DEFAULT 25)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_any_permission(array['finance:view','finance:manage']); result jsonb;
begin
 if p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100 or length(coalesce(p_search,''))>500 then raise exception 'Invalid due page'; end if;
 with matching as materialized (
  select s.sale_id,s.customer_id,s.created_at,(s.total_amount+s.additional_charges) total_amount,s.paid_amount,(s.total_amount+s.additional_charges)-s.paid_amount due,c.name,c.phone,c.shop_name
  from public.sales s join public.customers c on c.tenant_id=t and c.customer_id=s.customer_id
  where s.tenant_id=t and s.status='completed' and s.paid_amount<(s.total_amount+s.additional_charges)
   and (p_customer_id is null or s.customer_id=p_customer_id)
   and app_private.finance_search(concat_ws(' ',s.sale_id,c.name,c.phone,c.shop_name),p_search)
 ), page as (select * from matching order by created_at desc,sale_id limit p_limit offset p_offset)
 select jsonb_build_object('total',(select count(*) from matching),'due',(select coalesce(sum(due),0) from matching),
  'entries',coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at desc,p.sale_id) from page p),'[]')) into result;
 return result;
end $function$;

CREATE OR REPLACE FUNCTION public.get_product_inventory(p_item_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    select coalesce(c.refill_commission_per_unit,0) refill_rate,
      coalesce(c.package_commission_per_unit,0) package_rate,c.rate_id version
    from (select 1) singleton left join lateral (
      select refill_commission_per_unit,package_commission_per_unit,rate_id
      from public.product_commission_rates where tenant_id=t and item_id=p_item_id
      order by created_at desc,rate_id desc limit 1
    ) c on true
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
      and pi.received_quantity>0
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
      select sum(pi.line_total) amount,sum(pi.received_quantity) units
      from public.purchase_items pi where pi.tenant_id=t and pi.purchase_id=r.purchase_id
        and pi.item_id=p_item_id and pi.type=r.type
    ) lines
    cross join lateral (
      select sum(pi.received_quantity) units
      from public.purchase_items pi where pi.tenant_id=t and pi.purchase_id=r.purchase_id
    ) shipment
  ), weeks as (
    select (saturday - n*7) start_date,(saturday - n*7 + 7) end_date
    from generate_series(0,7) n
  ), history as (
    select w.start_date,w.end_date-1 end_date,
      coalesce(s.sold_refill,0) sold_refill,coalesce(s.sold_package,0) sold_package,
      coalesce((select sum(l.quantity) from public.sale_bottle_receipt_lines l join public.sale_bottle_receipts r on r.tenant_id=t and r.receipt_id=l.receipt_id where l.tenant_id=t and l.received_item_id=p_item_id and r.created_at >= (w.start_date::timestamp at time zone 'Asia/Dhaka') and r.created_at < (w.end_date::timestamp at time zone 'Asia/Dhaka')),0) empty_return,
      coalesce(p.bought_package,0) bought_package,coalesce(p.bought_refill,0) bought_refill
    from weeks w
    cross join lateral (
      select sum(si.quantity) filter(where si.type='refill') sold_refill,
        sum(si.quantity) filter(where si.type='package') sold_package
      from public.sale_items si join public.sales s using(tenant_id,sale_id)
      where si.tenant_id=t and si.item_id=p_item_id and s.status='completed'
        and s.created_at >= (w.start_date::timestamp at time zone 'Asia/Dhaka')
        and s.created_at < (w.end_date::timestamp at time zone 'Asia/Dhaka')
    ) s
    cross join lateral (
      select sum(pi.received_quantity) filter(where pi.type='package') bought_package,
        sum(pi.received_quantity) filter(where pi.type='refill') bought_refill
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
end $function$;

CREATE OR REPLACE FUNCTION public.get_purchase_directory(p_filters jsonb DEFAULT '{}'::jsonb, p_offset integer DEFAULT 0, p_limit integer DEFAULT 6)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    left join public.trucks tr on tr.tenant_id=t and tr.truck_id=p.truck_id
    left join public.gas_plants gp on gp.tenant_id=t and gp.plant_id=p.plant_id
    left join public.lpg_brands b on b.tenant_id=t and b.brand_id=p.brand_id
    where p.tenant_id=t
      and (coalesce(p_filters->>'status','all')='all' or p.status::text=p_filters->>'status' or p_filters->>'status'='pending_refund' and p.status='cancelled' and p.financial_closed_at is null or p_filters->>'status'='closed' and p.status='cancelled' and p.financial_closed_at is not null)
      and (coalesce(p_filters->>'payment','all')='all' or p.payment_status=p_filters->>'payment')
      and (nullif(p_filters->>'from','') is null or p.created_at >= (nullif(p_filters->>'from','')::date::timestamp at time zone 'Asia/Dhaka'))
      and (nullif(p_filters->>'to','') is null or p.created_at < ((nullif(p_filters->>'to','')::date+1)::timestamp at time zone 'Asia/Dhaka'))
      and (not searching or exists(
        select 1 from (select lower(concat_ws(' ',p.purchase_id,b.brand_name,gp.plant_name,tr.name,p.notes,p.receipt_notes,p.status,p.payment_status,
          (select string_agg(concat_ws(' ',lb.brand_name,trim_scale(i.size_kg)||'kg',trim_scale(i.size_kg)||' kg',i.mouth_size,
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
end $function$;

CREATE OR REPLACE FUNCTION public.get_purchase_settlement(p_purchase_id uuid, p_offset integer DEFAULT 0, p_limit integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_any_permission(array['purchases:view','purchases:manage']); p public.purchases; result jsonb;
begin
 if p_offset is null or p_limit is null or p_offset<0 or p_limit not between 1 and 100 then raise exception 'Invalid payment page'; end if;
 select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id;
 if not found then raise exception 'Purchase not found'; end if;
 select jsonb_build_object('total',p.total_cost,'paid',p.paid_amount,'due',case when p.status='cancelled' then 0 else greatest(0,p.total_cost-p.paid_amount) end,
 'refund_due',p.refund_due,'refunded',p.refunded_amount,'financial_closed_at',p.financial_closed_at,'can_cancel',public.can_cancel_purchases(),
 'internal_wallet',(select jsonb_build_object('wallet_id',wallet_id,'name',name,'kind',kind,'type',type) from public.wallets where tenant_id=t and type='logistics'),
 'financial_locked',p.payment_status='paid' or exists(select 1 from public.wallet_transactions where tenant_id=t and reference_id=p_purchase_id and amount<0 and type in ('purchase_expense','purchase_company_payment','purchase_logistics_payment','purchase_payment_company','purchase_payment_labour','purchase_payment_transport')),
 'obligations',coalesce((select jsonb_agg(to_jsonb(o)||jsonb_build_object('refunded',coalesce(q.amount,0),'remaining',o.amount-coalesce(q.amount,0)) order by o.component)
 from public.purchase_refund_obligations o left join lateral(select sum(amount) amount from public.purchase_payments where tenant_id=t and obligation_id=o.obligation_id) q on true where o.tenant_id=t and o.purchase_id=p_purchase_id),'[]'),
 'payment_count',(select count(*) from public.wallet_transactions where tenant_id=t and reference_id=p_purchase_id),
 'payments',coalesce((select jsonb_agg(to_jsonb(e) order by e.entry_no) from (select x.transaction_id,x.purchase_payment_id,x.wallet_name_snapshot wallet_name,x.wallet_method_snapshot method,x.amount,x.type,x.created_at,x.entry_no,x.operation_id,x.description,x.counterparty_wallet_id,pp.reference,pp.component,pp.obligation_id,up.full_name actor
  from public.wallet_transactions x left join public.purchase_payments pp on pp.tenant_id=t and pp.payment_id=x.purchase_payment_id
  left join public.user_profiles up on up.tenant_id=t and up.user_id=x.created_by
  where x.tenant_id=t and x.reference_id=p_purchase_id order by x.entry_no limit p_limit offset p_offset) e),'[]')) into result;
 return result;
end $function$;

CREATE OR REPLACE FUNCTION public.get_sale_bottles(p_sale_id uuid, p_offset integer DEFAULT 0, p_limit integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_any_permission(array['sales:view','receipts:print','dashboard:view','sales:collect_bottles']); s public.sales; result jsonb;
begin
 if p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid bottle history page'; end if;
 select * into s from public.sales where tenant_id=t and sale_id=p_sale_id;
 if not found then raise exception 'Sale not found'; end if;
 with obligations as materialized (
  select o.item_id,concat_ws(' ',b.brand_name,i.size_kg||'kg',i.mouth_size) name,i.size_kg,i.mouth_size,o.expected_quantity expected,
    coalesce(sum(l.quantity),0) received,o.expected_quantity-coalesce(sum(l.quantity),0) difference
  from (select tenant_id,sale_id,item_id,sum(quantity) expected_quantity from public.sale_items where type='empty_return' and tenant_id=t and sale_id=p_sale_id group by tenant_id,sale_id,item_id) o join public.items i on i.tenant_id=t and i.item_id=o.item_id
  left join public.lpg_brands b on b.tenant_id=t and b.brand_id=i.brand_id
  left join public.sale_bottle_receipt_lines l on l.tenant_id=t and l.sale_id=o.sale_id and l.received_item_id=o.item_id
  where o.tenant_id=t and o.sale_id=p_sale_id group by o.item_id,o.expected_quantity,i.size_kg,i.mouth_size,b.brand_name
 ), actual as materialized (
  select r.phase,l.received_item_id item_id,concat_ws(' ',b.brand_name,i.size_kg||'kg',i.mouth_size) name,sum(l.quantity) quantity
  from public.sale_bottle_receipts r join public.sale_bottle_receipt_lines l on l.tenant_id=t and l.receipt_id=r.receipt_id
  join public.items i on i.tenant_id=t and i.item_id=l.received_item_id left join public.lpg_brands b on b.tenant_id=t and b.brand_id=i.brand_id
  where r.tenant_id=t and r.sale_id=p_sale_id group by r.phase,l.received_item_id,b.brand_name,i.size_kg,i.mouth_size
 ), events as materialized (
  select r.receipt_id id,r.created_at,'bottles' kind,r.phase,r.note,r.fee amount,r.expense,r.expense_wallet_name,coalesce(u.full_name,u.email,'Operator') actor,
   coalesce((select jsonb_agg(jsonb_build_object('received_item_id',l.received_item_id,'quantity',l.quantity,'acknowledged',l.acknowledged,
     'received_name',concat_ws(' ',rb.brand_name,ri.size_kg||'kg',ri.mouth_size)) order by l.line_id)
    from public.sale_bottle_receipt_lines l
    join public.items ri on ri.tenant_id=t and ri.item_id=l.received_item_id
    left join public.lpg_brands rb on rb.tenant_id=t and rb.brand_id=ri.brand_id
    where l.tenant_id=t and l.receipt_id=r.receipt_id),'[]') lines
  from public.sale_bottle_receipts r left join public.user_profiles u on u.tenant_id=t and u.user_id=r.created_by where r.tenant_id=t and r.sale_id=p_sale_id
  union all
  select s.sale_id,s.created_at,'sale','checkout',coalesce(s.notes,''),s.total_amount,0::numeric,null::text,coalesce(u.full_name,u.email,'Operator'),'[]'::jsonb
  from public.user_profiles u where u.tenant_id=t and u.user_id=s.created_by
  union all
  select p.payment_id,p.created_at,'payment',p.phase,concat_ws(' · ',p.wallet_name,nullif(p.reference,'')),p.amount,0::numeric,null::text,coalesce(u.full_name,u.email,'Operator'),'[]'::jsonb
  from public.sale_payments p left join public.user_profiles u on u.tenant_id=t and u.user_id=p.created_by where p.tenant_id=t and p.sale_id=p_sale_id
 ), page as (select * from events order by created_at desc,id desc limit p_limit offset p_offset)
 select jsonb_build_object('expected',coalesce((select sum(expected) from obligations),0),
  'received',coalesce((select sum(quantity) from actual),0),'outstanding',greatest(0,coalesce((select sum(expected) from obligations),0)-coalesce((select sum(quantity) from actual),0)),
  'obligations',coalesce((select jsonb_agg(to_jsonb(o) order by name,item_id) from obligations o),'[]'),
  'actual',coalesce((select jsonb_agg(to_jsonb(a) order by phase,name,item_id) from actual a),'[]'),
  'event_count',(select count(*) from events),'events',coalesce((select jsonb_agg(to_jsonb(p) order by created_at desc,id desc) from page p),'[]')) into result;
 return result;
end $function$;

CREATE OR REPLACE FUNCTION public.get_sale_receipt(p_sale_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_permission('receipts:print'); result jsonb;
begin
 select jsonb_build_object(
  'shop_name',business.business_name,
  'sale',jsonb_build_object('sale_id',s.sale_id,'created_at',s.created_at,'sale_tier',s.sale_tier,
   'subtotal',s.subtotal,'discount_amount',s.discount_amount,'exchange_fee',s.exchange_fee,'total_amount',s.total_amount,'notes',s.notes,
   'customers',jsonb_build_object('name',c.name,'phone',c.phone),
   'sale_items',coalesce((select jsonb_agg(jsonb_build_object('item_id',si.item_id,'type',si.type,'quantity',si.quantity,
    'unit_price',si.unit_price,'line_total',si.line_total,'items',jsonb_build_object('item_id',i.item_id,'brand_id',i.brand_id,
    'size_kg',i.size_kg,'mouth_size',i.mouth_size,'lpg_brands',jsonb_build_object('brand_name',b.brand_name))) order by si.sale_item_id)
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
end $function$;

CREATE OR REPLACE FUNCTION public.get_sale_settlement(p_sale_id uuid, p_offset integer DEFAULT 0, p_limit integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_any_permission(array['finance:view','finance:manage','sales:view','receipts:print','dashboard:view']); s public.sales; result jsonb;
begin
 if p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid payment page'; end if;
 select * into s from public.sales where tenant_id=t and sale_id=p_sale_id;
 if not found then raise exception 'Sale not found'; end if;
 select jsonb_build_object('sale_id',s.sale_id,'original_total',s.total_amount,'additional_charges',s.additional_charges,'total',(s.total_amount+s.additional_charges),'paid',s.paid_amount,'due',(s.total_amount+s.additional_charges)-s.paid_amount,
  'paid_at_checkout',s.paid_at_checkout,'checkout_payments',coalesce((select jsonb_agg(jsonb_build_object('wallet_id',wallet_id,'wallet_name',wallet_name,'method',method,'amount',amount,'reference',reference) order by created_at,payment_id) from public.sale_payments where tenant_id=t and sale_id=p_sale_id and phase='checkout'),'[]'),
  'unattributed_paid',s.paid_amount-(select coalesce(sum(amount),0) from public.sale_payments where tenant_id=t and sale_id=p_sale_id),
  'payment_count',(select count(*) from public.sale_payments where tenant_id=t and sale_id=p_sale_id),
  'payments',coalesce((select jsonb_agg(to_jsonb(p) order by created_at desc,payment_id) from
   (select * from public.sale_payments where tenant_id=t and sale_id=p_sale_id order by created_at desc,payment_id limit p_limit offset p_offset) p),'[]'),
  'receipt_payments',coalesce((select jsonb_agg(to_jsonb(p) order by phase,wallet_name,method) from
   (select wallet_name,method,phase,sum(amount) amount from public.sale_payments where tenant_id=t and sale_id=p_sale_id group by wallet_name,method,phase) p),'[]')) into result;
 return result;
end $function$;

CREATE OR REPLACE FUNCTION public.get_sales_directory(p_filters jsonb DEFAULT '{}'::jsonb, p_offset integer DEFAULT 0, p_limit integer DEFAULT 25)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
 SET plan_cache_mode TO 'force_custom_plan'
AS $function$
declare t uuid:=app_private.require_permission('sales:view'); result jsonb; ordering text:=coalesce(p_filters->>'sort','date_desc');
 payment text:=coalesce(p_filters->>'payment','all'); bottles text:=coalesce(p_filters->>'bottles','all');
 from_day date:=nullif(p_filters->>'from','')::date; to_day date:=nullif(p_filters->>'to','')::date;
begin
 if p_filters is null or jsonb_typeof(p_filters)<>'object' or length(coalesce(p_filters->>'search',''))>500 or p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid sales page'; end if;
 if ordering not in ('date_desc','date_asc','amount_desc','amount_asc','due_desc','bottles_desc') or payment not in ('all','unpaid','partial','paid','outstanding') or bottles not in ('all','outstanding','partial','none_received','received') or coalesce(p_filters->>'tier','all') not in ('all','retail','wholesale') or from_day>to_day then raise exception 'Invalid sales filter'; end if;
 with headers as materialized (
  select s.sale_id,s.created_at,s.customer_id,s.sale_tier,s.total_amount original_total,s.additional_charges,s.total_amount+s.additional_charges total_amount,s.paid_amount,s.total_amount+s.additional_charges-s.paid_amount due,
   c.name,c.phone,c.shop_name,
   coalesce(q.expected,0) expected,greatest(0,coalesce(q.expected,0)-coalesce(q.received,0)) outstanding_bottles,coalesce(q.received,0) received_bottles
  from public.sales s join public.customers c on c.tenant_id=t and c.customer_id=s.customer_id
  left join lateral (select
   (select coalesce(sum(quantity),0) from public.sale_items where type='empty_return' and tenant_id=t and sale_id=s.sale_id) expected,
   (select coalesce(sum(quantity),0) from public.sale_bottle_receipt_lines where tenant_id=t and sale_id=s.sale_id) received) q on true
  where s.tenant_id=t and s.status='completed'
   and (from_day is null or s.created_at>=from_day::timestamp at time zone 'Asia/Dhaka') and (to_day is null or s.created_at<(to_day+1)::timestamp at time zone 'Asia/Dhaka')
   and (coalesce(p_filters->>'tier','all')='all' or s.sale_tier=p_filters->>'tier')
   and app_private.finance_search(concat_ws(' ',s.sale_id,c.name,c.phone,c.shop_name,s.sale_tier,s.notes,
    (select string_agg(concat_ws(' ',b.brand_name,i.size_kg||'kg',i.mouth_size,si.type),' ') from public.sale_items si join public.items i on i.tenant_id=t and i.item_id=si.item_id left join public.lpg_brands b on b.tenant_id=t and b.brand_id=i.brand_id where si.tenant_id=t and si.sale_id=s.sale_id)),coalesce(p_filters->>'search',''))
 ), matching as materialized (
  select * from headers where (payment='all' or payment='unpaid' and paid_amount=0 and due>0 or payment='partial' and paid_amount>0 and due>0 or payment='paid' and due=0 or payment='outstanding' and due>0)
   and (bottles='all' or bottles='outstanding' and outstanding_bottles>0 or bottles='partial' and received_bottles>0 and outstanding_bottles>0 or bottles='none_received' and received_bottles=0 and outstanding_bottles>0 or bottles='received' and outstanding_bottles=0)
 ), page as (
  select * from matching order by case when ordering='date_desc' then created_at end desc,case when ordering='date_asc' then created_at end asc,
   case when ordering='amount_desc' then total_amount end desc,case when ordering='amount_asc' then total_amount end asc,
   case when ordering='due_desc' then due end desc,case when ordering='bottles_desc' then outstanding_bottles end desc,sale_id desc limit p_limit offset p_offset
 ), details as (
  select p.*,coalesce((select jsonb_agg(jsonb_build_object('item_id',si.item_id,'type',si.type,'quantity',si.quantity,'name',concat_ws(' ',b.brand_name,i.size_kg||'kg',i.mouth_size)) order by si.type,si.item_id)
   from public.sale_items si join public.items i on i.tenant_id=t and i.item_id=si.item_id left join public.lpg_brands b on b.tenant_id=t and b.brand_id=i.brand_id where si.tenant_id=t and si.sale_id=p.sale_id),'[]') items
  from page p
 ) select jsonb_build_object('total',(select count(*) from matching),'entries',coalesce((select jsonb_agg(to_jsonb(d) order by
  case when ordering='date_desc' then created_at end desc,case when ordering='date_asc' then created_at end asc,
  case when ordering='amount_desc' then total_amount end desc,case when ordering='amount_asc' then total_amount end asc,
  case when ordering='due_desc' then due end desc,case when ordering='bottles_desc' then outstanding_bottles end desc,sale_id desc) from details d),'[]')) into result;
 return result;
end $function$;

CREATE OR REPLACE FUNCTION public.get_sales_overview()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_permission('sales:view'); result jsonb;
begin
 select jsonb_build_object('total',count(*),'amount',coalesce(sum(total_amount+additional_charges),0),'due',coalesce(sum(total_amount+additional_charges-paid_amount),0),
 'bottles',coalesce((select sum(greatest(0,
   (select coalesce(sum(quantity),0) from public.sale_items where type='empty_return' and tenant_id=t and sale_id=s.sale_id)-
   (select coalesce(sum(quantity),0) from public.sale_bottle_receipt_lines where tenant_id=t and sale_id=s.sale_id)))
   from public.sales s where tenant_id=t and status='completed'),0)) into result from public.sales where tenant_id=t and status='completed';
 return result;
end $function$;

CREATE OR REPLACE FUNCTION public.initiate_purchase_cancellation(p_purchase_id uuid, p_revision integer, p_confirmation text, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_permission('purchases:manage'); p public.purchases; prior public.finance_requests; payload jsonb; result jsonb;
 r record; transport_paid numeric:=0; logistics_income numeric:=0; obligation_total numeric:=0; sources jsonb;
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
 if p.status='received' then raise exception 'Received purchases can never be cancelled'; end if;
 if p.status='cancelled' then raise exception 'Purchase is already cancelled'; end if;
 if p_revision is distinct from p.revision then raise exception 'Purchase changed. Reload before cancellation.' using errcode='P0001'; end if;
 perform 1 from public.trucks where tenant_id=t and truck_id=p.truck_id for update;
 perform 1 from public.transits where tenant_id=t and purchase_id=p_purchase_id order by transit_id for update;
 insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details) values(t,p_purchase_id,'cancellation_confirmed',auth.uid(),jsonb_build_object('previous_status',p.status,'confirmation','CANCEL','operation_id',p_request_id,'before',to_jsonb(p)));
 -- Only dispatch is reversible: receiving is a permanent cancellation boundary.
 for r in select m.item_id,sum(m.empty_quantity_change) empties from public.inventory_movements m where m.tenant_id=t and
 m.reference_id=p_purchase_id and m.reference_type='purchase_dispatch' group by m.item_id order by m.item_id loop
  perform 1 from public.items where tenant_id=t and item_id=r.item_id for update;
  if r.empties<>0 then insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,empty_quantity_change,notes,created_by)
   values(t,r.item_id,'purchase_adjustment','purchase_cancellation',p_purchase_id,-r.empties,'Cancelled purchase: dispatched empties returned',auth.uid()); end if;
 end loop;
 select greatest(0,coalesce(sum(x.amount),0)) into logistics_income from public.wallet_transactions x join public.wallets w using(tenant_id,wallet_id)
  where x.tenant_id=t and x.reference_id=p_purchase_id and w.type='logistics' and x.type in ('transport_income','transport_income_adj','purchase_transport_settlement','purchase_transport_funding');
 -- Refund only evidence of actual purchasing-business debits. Historical settled
 -- headers with no ledger attribution never create fictional money to refund.
 for r in select component,greatest(0,-sum(amount)) amount,jsonb_agg(evidence order by created_at,transaction_id) sources from (
  select x.amount,x.created_at,x.transaction_id,case when x.type in ('purchase_company_payment','purchase_payment_company') then 'company'
   when x.type in ('purchase_logistics_payment','purchase_payment_labour') then 'labour'
   when x.type in ('purchase_transport_funding','purchase_payment_transport') then 'transport' else 'legacy' end component,
   jsonb_build_object('transaction_id',x.transaction_id,'payment_id',x.purchase_payment_id,'wallet_id',x.wallet_id,'wallet_name',x.wallet_name_snapshot,'method',x.wallet_method_snapshot,'amount',x.amount,'description',x.description,'created_at',x.created_at) evidence
  from public.wallet_transactions x join public.wallets w using(tenant_id,wallet_id) where x.tenant_id=t and x.reference_id=p_purchase_id and w.type<>'logistics'
   and x.type in ('purchase_expense','purchase_company_payment','purchase_logistics_payment','purchase_transport_funding','purchase_payment_company','purchase_payment_labour','purchase_payment_transport')
 ) q group by component loop
  if r.amount>0 then
   insert into public.purchase_refund_obligations(tenant_id,purchase_id,component,amount,logistics_amount,sources,created_by)
    values(t,p_purchase_id,r.component,r.amount,case when r.component='transport' then least(r.amount,logistics_income) else 0 end,r.sources,auth.uid());
   obligation_total:=obligation_total+r.amount;
   if r.component='transport' then transport_paid:=r.amount; end if;
  end if;
 end loop;
 if logistics_income>transport_paid then
  select coalesce(jsonb_agg(jsonb_build_object('transaction_id',x.transaction_id,'wallet_name',x.wallet_name_snapshot,'amount',x.amount,'description',x.description)),'[]') into sources
   from public.wallet_transactions x join public.wallets w using(tenant_id,wallet_id) where x.tenant_id=t and x.reference_id=p_purchase_id and w.type='logistics'
    and x.type in ('transport_income','transport_income_adj','purchase_transport_settlement','purchase_transport_funding');
  insert into public.purchase_refund_obligations(tenant_id,purchase_id,component,amount,logistics_amount,credit_business,sources,created_by)
   values(t,p_purchase_id,'transport_income',logistics_income-transport_paid,logistics_income-transport_paid,false,sources,auth.uid());
  obligation_total:=obligation_total+logistics_income-transport_paid;
 end if;
 update public.transits set status='cancelled',revision=revision+1,updated_at=now() where tenant_id=t and purchase_id=p_purchase_id;
 update public.purchases set status='cancelled',cancelled_at=now(),refund_due=obligation_total,financial_closed_at=case when obligation_total=0 then now() end,
  updated_at=now(),revision=revision+1 where tenant_id=t and purchase_id=p_purchase_id;
 if not exists(select 1 from public.transits where tenant_id=t and truck_id=p.truck_id and status='active')
  and not exists(select 1 from public.purchases where tenant_id=t and truck_id=p.truck_id and status='in_transit') then
  update public.trucks set status='idle',updated_at=now() where tenant_id=t and truck_id=p.truck_id;
 end if;
 result:=jsonb_build_object('purchase_id',p_purchase_id,'refund_due',obligation_total,'financially_closed',obligation_total=0);
 insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details) values(t,p_purchase_id,'cancellation_initiated',auth.uid(),result||jsonb_build_object('notes','Dispatched empties returned; truck released; transit cancelled. Incurred operating costs preserved. Refunds require separate settlement.'));
 if obligation_total=0 then insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details) values(t,p_purchase_id,'financially_closed',auth.uid(),result); end if;
 insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,payload,result,auth.uid());
 return result;
end $function$;

CREATE OR REPLACE FUNCTION public.list_transits()
 RETURNS SETOF jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid := app_private.require_any_permission(array['logistics:view','logistics:manage']);
begin
  return query select to_jsonb(tr)||jsonb_build_object('truck_name',truck.name,'purchase_refund_due',p.refund_due,'purchase_financial_closed_at',p.financial_closed_at)
    from public.transits tr join public.trucks truck on truck.tenant_id=tr.tenant_id and truck.truck_id=tr.truck_id
    left join public.purchases p on p.tenant_id=tr.tenant_id and p.purchase_id=tr.purchase_id
    where tr.tenant_id=t order by tr.created_at desc;
end $function$;

CREATE OR REPLACE FUNCTION public.set_product_commissions(p_item_id uuid, p_refill_rate numeric, p_package_rate numeric, p_expected uuid DEFAULT NULL::uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_permission('inventory:manage'); current_version uuid;
begin
  if not app_private.can_manage_inventory_prices() then
    raise exception 'Only the owner can edit product prices or commission' using errcode='42501';
  end if;
  if p_refill_rate is null or p_package_rate is null
    or p_refill_rate::text in ('NaN','Infinity','-Infinity') or p_package_rate::text in ('NaN','Infinity','-Infinity')
    or p_refill_rate<0 or p_package_rate<0 or p_refill_rate>=10000000000 or p_package_rate>=10000000000
    or p_refill_rate<>round(p_refill_rate,2) or p_package_rate<>round(p_package_rate,2) then
    raise exception 'Commission rates must be nonnegative with at most two decimal places';
  end if;
  perform 1 from public.items where tenant_id=t and item_id=p_item_id for update;
  if not found then raise exception 'Product not found'; end if;
  select rate_id into current_version from public.product_commission_rates
    where tenant_id=t and item_id=p_item_id order by created_at desc,rate_id desc limit 1;
  if current_version is distinct from p_expected then
    raise exception 'Commission changed. Reload the saved rates before saving.' using errcode='P0001';
  end if;
  insert into public.product_commission_rates(tenant_id,item_id,refill_commission_per_unit,package_commission_per_unit,created_by)
    values(t,p_item_id,p_refill_rate,p_package_rate,auth.uid());
end $function$;

drop function public.cancel_purchase(p_purchase_id uuid, p_revision integer);

drop function public.complete_purchase(p_purchase_id uuid);

drop function public.create_custom_transit(p_truck_id uuid, p_fee numeric, p_notes text);

drop function public.create_purchase(p_truck_id uuid, p_plant_id uuid, p_transport_cost numeric, p_labour_cost numeric, p_notes text, p_items jsonb);

drop function public.list_purchases();

drop function public.pay_purchase(p_purchase_id uuid, p_revision integer);

drop function public.receive_purchase(p_purchase_id uuid, p_items jsonb, p_receipt_notes text, p_revision integer);

drop function public.set_product_commission(p_item_id uuid, p_rate numeric, p_expected uuid);

drop function public.update_purchase(p_purchase_id uuid, p_transport_cost numeric, p_labour_cost numeric, p_notes text, p_items jsonb);

drop function public.update_transit_costs(p_transit_id uuid, p_driver_cost numeric, p_helper_cost numeric, p_oil_cost numeric, p_additional_costs jsonb, p_status transit_status);


alter table public.sale_bottle_receipt_lines drop column expected_item_id, drop column allow_incompatible;
drop table public.sale_bottle_obligations;
-- Original sale lines now own the immutable bottle agreement as well as billing.
create trigger immutable_sale_line before update or delete on public.sale_items
 for each row execute function app_private.immutable_finance_record();
alter table public.sales drop column payment_tracking, drop column bottle_tracking, drop column checkout_payments;
alter table public.purchases drop column legacy_record;
alter table public.items drop column brand, drop column cylinder_weight;
drop type public.cylinder_weight;

-- The former indexes are fully covered by existing leading keys. Keep unique
-- idempotency indexes and the immutable ledger search/amount indexes.
drop index public.idx_items_tenant;
drop index public.idx_items_brand_id;
drop index public.idx_price_books_tenant_item_tier;
drop index public.idx_wallet_transactions_wallet;
drop index public.idx_wallets_tenant;
create index sales_outstanding on public.sales(tenant_id,customer_id,created_at desc)
 where paid_amount<total_amount+additional_charges;

do $verify$ begin
 if exists(select 1 from canonical_preservation p where
 p.stock is distinct from (select md5(coalesce(jsonb_agg(jsonb_build_array(tenant_id,item_id,filled_quantity,empty_quantity) order by tenant_id,item_id)::text,'')) from public.items)
 or p.wallets is distinct from (select md5(coalesce(jsonb_agg(to_jsonb(x) order by tenant_id,wallet_id)::text,'')) from public.wallets x)
 or p.wallet_ledger is distinct from (select md5(coalesce(jsonb_agg(to_jsonb(x) order by tenant_id,transaction_id)::text,'')) from public.wallet_transactions x)
 or p.customer_ledger is distinct from (select md5(coalesce(jsonb_agg(to_jsonb(x) order by tenant_id,transaction_id)::text,'')) from public.customer_transactions x)
 or p.sales is distinct from (select md5(coalesce(jsonb_agg(to_jsonb(x)-'checkout_payload' order by tenant_id,sale_id)::text,'')) from public.sales x))
 then raise exception 'Canonical migration changed stock, money, or sale financial evidence'; end if;
end $verify$;
drop table canonical_preservation;
notify pgrst,'reload schema';
