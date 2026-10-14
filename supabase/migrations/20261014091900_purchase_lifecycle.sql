-- Purchase operations remain capability-gated RPCs. No historical stock or
-- wallet transactions are replayed or rewritten by this migration.
alter table public.purchases
  alter column truck_id drop not null,
  alter column status set default 'created',
  add column brand_id uuid,
  add column payment_status text not null default 'unpaid' check (payment_status in ('unpaid','paid')),
  add column commission numeric(12,2) not null default 0,
  add column subtotal numeric(12,2) not null default 0,
  add column company_payable numeric(12,2) not null default 0,
  add column dispatched_at timestamptz,
  add column received_at timestamptz,
  add column paid_at timestamptz,
  add column receipt_notes text,
  add column revision integer not null default 1,
  add column legacy_record boolean not null default false,
  add column request_id uuid,
  add constraint purchases_company_fk foreign key (tenant_id,brand_id)
    references public.lpg_brands(tenant_id,brand_id);

alter table public.purchase_items
  add column empty_dispatched integer not null default 0 check (empty_dispatched >= 0),
  add column received_quantity integer check (received_quantity >= 0),
  add column billed_quantity integer not null default 0 check (billed_quantity >= 0);

-- Old completion already debited the dealership; old dispatch already sent
-- empties and credited logistics. Dates reflect the available header evidence.
-- Keep backfill CASE expressions inside a DO body for the deployment runner's
-- conservative top-level transaction-control scanner.
do $legacy$ begin
update public.purchases p set
  brand_id = gp.brand_id,
  legacy_record = true,
  subtotal = p.total_cost - coalesce(p.transport_cost,0) - coalesce(p.labour_cost,0),
  company_payable = p.total_cost - coalesce(p.transport_cost,0) - coalesce(p.labour_cost,0),
  payment_status = case when p.status = 'received' then 'paid' else 'unpaid' end,
  dispatched_at = p.created_at,
  received_at = case when p.status = 'received' then p.updated_at end,
  paid_at = case when p.status = 'received' then p.updated_at end
from public.gas_plants gp where gp.tenant_id=p.tenant_id and gp.plant_id=p.plant_id;

update public.purchase_items pi set
  empty_dispatched = case when pi.type = 'refill' then pi.quantity else 0 end,
  billed_quantity = pi.quantity,
  received_quantity = case when p.status = 'received' then pi.quantity end
from public.purchases p where p.tenant_id=pi.tenant_id and p.purchase_id=pi.purchase_id;
end $legacy$;

create unique index purchases_request_once on public.purchases(tenant_id,request_id)
  where request_id is not null;
-- New movements have an explicit phase and purchase reference. Legacy unlinked
-- movements stay intact. Group receipt by SKU and kind to retain refill/new history.
create unique index purchase_movements_once
  on public.inventory_movements(tenant_id,reference_id,item_id,reference_type)
  where reference_type in ('purchase_dispatch','purchase_receipt_refill','purchase_receipt_new');
create unique index purchase_payment_once
  on public.wallet_transactions(tenant_id,reference_id,type)
  where type in ('purchase_company_payment','purchase_logistics_payment','purchase_transport_settlement');

create table public.purchase_activity (
  tenant_id uuid not null,
  activity_id uuid not null default gen_random_uuid(),
  purchase_id uuid not null,
  action text not null,
  details jsonb not null default '{}',
  created_by uuid,
  created_at timestamptz not null default now(),
  primary key (tenant_id,activity_id),
  foreign key (tenant_id,purchase_id) references public.purchases(tenant_id,purchase_id),
  foreign key (tenant_id,created_by) references public.user_profiles(tenant_id,user_id)
);
create index purchase_activity_history on public.purchase_activity(tenant_id,purchase_id,created_at);
alter table public.purchase_activity enable row level security;
revoke all on public.purchase_activity from public, anon, authenticated;
grant select on public.purchase_activity to authenticated;
create policy purchase_activity_read on public.purchase_activity for select to authenticated
  using (tenant_id=(select app_private.current_tenant_id()) and
    (select app_private.has_any_permission(array['purchases:view','purchases:manage'])));
insert into public.purchase_activity(tenant_id,purchase_id,action,details,created_by,created_at)
select tenant_id,purchase_id,'legacy_import',
  jsonb_build_object('status',status,'payment_status',payment_status,
    'message','Historical record retained; stock and accounting were not replayed. Dates and outgoing quantities are inferred from the old workflow.'),
  created_by,now() from public.purchases;

create function app_private.purchase_activity_immutable() returns trigger
language plpgsql set search_path = '' as $$
begin raise exception 'Purchase activity is immutable'; end $$;
create trigger purchase_activity_immutable before update or delete on public.purchase_activity
  for each row execute function app_private.purchase_activity_immutable();

-- Used for all monetary inputs, including NaN/Infinity which otherwise pass
-- ordinary positive-number comparisons in PostgreSQL.
create function app_private.purchase_money(p_value numeric) returns numeric
language plpgsql immutable set search_path = '' as $$
begin
  if p_value is null or p_value::text in ('NaN','Infinity','-Infinity')
    or p_value < 0 or p_value > 9999999999.99 or p_value <> round(p_value,2) then
    raise exception 'Amounts must be nonnegative, finite and have at most two decimal places';
  end if;
  return p_value;
end $$;

create function app_private.purchase_integer(p_value jsonb) returns integer
language plpgsql immutable set search_path = '' as $$
declare n numeric;
begin
  if jsonb_typeof(p_value) <> 'number' or p_value is null then
    raise exception 'Cylinder quantities must be whole nonnegative numbers';
  end if;
  n := p_value::text::numeric;
  if n < 0 or n > 2147483647 or n <> trunc(n) then
    raise exception 'Cylinder quantities must be whole nonnegative numbers';
  end if;
  return n::integer;
end $$;

create function app_private.recalculate_purchase(p_tenant uuid,p_purchase uuid) returns void
language plpgsql set search_path = '' as $$
declare s numeric; c numeric;
begin
  select coalesce(sum(line_total),0) into s from public.purchase_items
    where tenant_id=p_tenant and purchase_id=p_purchase;
  select commission into c from public.purchases where tenant_id=p_tenant and purchase_id=p_purchase;
  if c > s then raise exception 'Commission cannot exceed the product subtotal'; end if;
  update public.purchases set subtotal=s, company_payable=s-c,
    total_cost=s-c+transport_cost+labour_cost where tenant_id=p_tenant and purchase_id=p_purchase;
end $$;

create function app_private.save_purchase_lines(p_tenant uuid,p_purchase uuid,p_lines jsonb) returns void
language plpgsql set search_path = '' as $$
declare p public.purchases; x jsonb; i public.items; q integer; e integer; price numeric; line_id uuid;
begin
  select * into p from public.purchases where tenant_id=p_tenant and purchase_id=p_purchase;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' then raise exception 'Products must be an array'; end if;
  if p.status='created' then
    delete from public.purchase_items where tenant_id=p_tenant and purchase_id=p_purchase;
    for x in select value from jsonb_array_elements(p_lines) loop
      if x->>'type' is null or x->>'type' not in ('refill','package') then raise exception 'Invalid purchase type'; end if;
      q := app_private.purchase_integer(x->'quantity');
      e := app_private.purchase_integer(coalesce(x->'empty_dispatched','0'::jsonb));
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

create function public.create_purchase(p_payload jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t uuid := app_private.require_permission('purchases:manage'); id uuid; b uuid; request uuid; plant uuid;
begin
  request := (p_payload->>'request_id')::uuid;
  if request is null then raise exception 'Creation request ID is required'; end if;
  -- Transaction lock makes repeated creation requests return the same result.
  perform pg_advisory_xact_lock(hashtextextended(t::text || request::text,0));
  select purchase_id into id from public.purchases where tenant_id=t and request_id=request;
  if found then return jsonb_build_object('purchase_id',id); end if;
  plant := (p_payload->>'plant_id')::uuid;
  select gp.brand_id into b from public.gas_plants gp join public.lpg_brands lb
    on lb.tenant_id=gp.tenant_id and lb.brand_id=gp.brand_id
    where gp.tenant_id=t and gp.plant_id=plant and gp.is_active and lb.is_active for share of gp,lb;
  if b is null then raise exception 'Select an active plant with an active company'; end if;
  if p_payload->>'truck_id' is not null and not exists(select 1 from public.trucks where tenant_id=t and truck_id=(p_payload->>'truck_id')::uuid) then
    raise exception 'Truck not found'; end if;
  insert into public.purchases(tenant_id,plant_id,brand_id,truck_id,status,transport_cost,labour_cost,commission,notes,created_by,request_id)
  values(t,plant,b,(p_payload->>'truck_id')::uuid,'created',
    app_private.purchase_money(coalesce((p_payload->>'transport_cost')::numeric,0)),
    app_private.purchase_money(coalesce((p_payload->>'labour_cost')::numeric,0)),
    app_private.purchase_money(coalesce((p_payload->>'commission')::numeric,0)),p_payload->>'notes',auth.uid(),request)
  returning purchase_id into id;
  perform app_private.save_purchase_lines(t,id,coalesce(p_payload->'items','[]'::jsonb));
  perform app_private.recalculate_purchase(t,id);
  insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details)
    values(t,id,'created',auth.uid(),jsonb_build_object('plant_id',plant,'company_id',b));
  return jsonb_build_object('purchase_id',id);
end $$;

create function public.update_purchase(p_purchase_id uuid,p_payload jsonb,p_revision integer) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t uuid := app_private.require_permission('purchases:manage'); p public.purchases; truck uuid; difference numeric; wid uuid;
begin
  select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id for update;
  if not found then raise exception 'Purchase not found'; end if;
  if p_revision is distinct from p.revision then raise exception 'Purchase changed. Reload it before saving.' using errcode='40001'; end if;
  if p.status='cancelled' or (p.status='received' and p.payment_status='paid') then raise exception 'Purchase is completed and locked'; end if;
  if p_payload ? 'plant_id' and (p_payload->>'plant_id')::uuid is distinct from p.plant_id
    or p_payload ? 'brand_id' and (p_payload->>'brand_id')::uuid is distinct from p.brand_id then
    raise exception 'Plant and company cannot change'; end if;
  truck := case when p_payload ? 'truck_id' then (p_payload->>'truck_id')::uuid else p.truck_id end;
  if p.status<>'created' and truck is distinct from p.truck_id then raise exception 'Truck is locked after dispatch'; end if;
  if truck is not null and not exists(select 1 from public.trucks where tenant_id=t and truck_id=truck) then raise exception 'Truck not found'; end if;
  if p.payment_status='paid' then
    if p_payload ? 'items' or p_payload ? 'commission' or p_payload ? 'transport_cost' or p_payload ? 'labour_cost' then
      raise exception 'Paid financial values are locked'; end if;
  else
    update public.purchases set truck_id=truck where tenant_id=t and purchase_id=p_purchase_id;
    if p_payload ?| array['items','commission','transport_cost','labour_cost'] then
    if p.status<>'created' then
      perform 1 from public.trucks where tenant_id=t and truck_id=p.truck_id for update;
      perform 1 from public.transits where tenant_id=t and purchase_id=p_purchase_id order by transit_id for update;
    end if;
    if p_payload ? 'items' then perform app_private.save_purchase_lines(t,p_purchase_id,p_payload->'items'); end if;
    update public.purchases set truck_id=truck,
      transport_cost=app_private.purchase_money(coalesce((p_payload->>'transport_cost')::numeric,transport_cost,0)),
      labour_cost=app_private.purchase_money(coalesce((p_payload->>'labour_cost')::numeric,labour_cost,0)),
      commission=app_private.purchase_money(coalesce((p_payload->>'commission')::numeric,commission))
      where tenant_id=t and purchase_id=p_purchase_id;
    perform app_private.recalculate_purchase(t,p_purchase_id);
    update public.transits set transport_fee=(select transport_cost from public.purchases where tenant_id=t and purchase_id=p_purchase_id)
      where tenant_id=t and purchase_id=p_purchase_id;
    if p.legacy_record then
      difference := (select transport_cost from public.purchases where tenant_id=t and purchase_id=p_purchase_id)-coalesce(p.transport_cost,0);
      if difference<>0 then
        perform app_private.ensure_tenant_wallets(t);
        select wallet_id into wid from public.wallets where tenant_id=t and type='logistics' for update;
        insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description)
          values(t,wid,difference,'transport_income_adj',p_purchase_id,'Historical purchase transport adjustment');
        update public.wallets set balance=balance+difference,updated_at=now() where tenant_id=t and wallet_id=wid;
      end if;
    end if;
    end if;
  end if;
  update public.purchases set notes=case when p_payload ? 'notes' then p_payload->>'notes' else notes end,
    updated_at=now(),revision=revision+1 where tenant_id=t and purchase_id=p_purchase_id;
  insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details)
    values(t,p_purchase_id,'updated',auth.uid(),jsonb_build_object('before',to_jsonb(p),
      'after',(select to_jsonb(h) from public.purchases h where h.tenant_id=t and h.purchase_id=p_purchase_id),
      'items',(select jsonb_agg(to_jsonb(pi)) from public.purchase_items pi where pi.tenant_id=t and pi.purchase_id=p_purchase_id)));
  return jsonb_build_object('purchase_id',p_purchase_id);
end $$;

create function public.dispatch_purchase(p_purchase_id uuid,p_revision integer) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t uuid := app_private.require_permission('purchases:manage'); p public.purchases; tr public.trucks; x record;
begin
  select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id for update;
  if not found then raise exception 'Purchase not found'; end if;
  if p.status='in_transit' or p.status='received' then return jsonb_build_object('purchase_id',p_purchase_id,'already_dispatched',true); end if;
  if p.status<>'created' then raise exception 'Only a Created purchase can be dispatched'; end if;
  if p_revision is distinct from p.revision then raise exception 'Purchase changed. Reload before dispatch.' using errcode='40001'; end if;
  select * into tr from public.trucks where tenant_id=t and truck_id=p.truck_id for update;
  if not found or tr.status<>'idle' then raise exception 'Select an idle truck before dispatch'; end if;
  if exists(select 1 from public.transits where tenant_id=t and truck_id=p.truck_id and status='active')
    or exists(select 1 from public.purchases where tenant_id=t and truck_id=p.truck_id and status='in_transit') then
    raise exception 'Truck already has an active shipment'; end if;
  if not exists(select 1 from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id) then raise exception 'Add at least one product before dispatch'; end if;
  perform 1 from public.gas_plants gp join public.lpg_brands b on b.tenant_id=gp.tenant_id and b.brand_id=gp.brand_id
    where gp.tenant_id=t and gp.plant_id=p.plant_id and gp.brand_id=p.brand_id and gp.is_active and b.is_active for share of gp,b;
  if not found then raise exception 'Plant company is unavailable'; end if;
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
  insert into public.transits(tenant_id,truck_id,purchase_id,status,transport_fee)
    values(t,p.truck_id,p_purchase_id,'active',p.transport_cost);
  update public.trucks set status='going',updated_at=now() where tenant_id=t and truck_id=p.truck_id;
  update public.purchases set status='in_transit',dispatched_at=now(),updated_at=now(),revision=revision+1
    where tenant_id=t and purchase_id=p_purchase_id;
  insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details)
    values(t,p_purchase_id,'dispatched',auth.uid(),jsonb_build_object('empty_cylinders',
      (select sum(empty_dispatched) from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id)));
  return jsonb_build_object('purchase_id',p_purchase_id);
end $$;

create function public.receive_purchase(p_purchase_id uuid,p_items jsonb,p_receipt_notes text,p_revision integer) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t uuid := app_private.require_permission('purchases:manage'); p public.purchases; x jsonb; r record; q integer; wid uuid;
begin
  select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id for update;
  if not found then raise exception 'Purchase not found'; end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' then raise exception 'Enter actual quantities for every product'; end if;
  if jsonb_array_length(p_items)<>(select count(*) from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id)
    or (select count(distinct value->>'purchase_item_id') from jsonb_array_elements(p_items))<>jsonb_array_length(p_items) then
    raise exception 'Enter actual quantities for every product exactly once'; end if;
  -- Identical receipt retry succeeds; a conflicting second receipt fails.
  if p.status='received' then
    for x in select value from jsonb_array_elements(p_items) loop
      if not exists(select 1 from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id
        and purchase_item_id=(x->>'purchase_item_id')::uuid and received_quantity=app_private.purchase_integer(x->'received_quantity')) then
        raise exception 'Receipt is already finalized with different quantities'; end if;
    end loop;
    return jsonb_build_object('purchase_id',p_purchase_id,'already_received',true);
  end if;
  if p.status<>'in_transit' then raise exception 'Only an In Transit purchase can be received'; end if;
  if p_revision is distinct from p.revision then raise exception 'Purchase changed. Reload before receipt.' using errcode='40001'; end if;
  -- Purchase -> truck -> transit -> inventory -> wallets is the common lock order.
  perform 1 from public.trucks where tenant_id=t and truck_id=p.truck_id for update;
  perform 1 from public.transits where tenant_id=t and purchase_id=p_purchase_id order by transit_id for update;
  for x in select value from jsonb_array_elements(p_items) loop
    q := app_private.purchase_integer(x->'received_quantity');
    select * into r from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id and purchase_item_id=(x->>'purchase_item_id')::uuid;
    if not found then raise exception 'Receipt product not found'; end if;
    if q<>r.quantity and nullif(trim(p_receipt_notes),'') is null then raise exception 'Explain the quantity discrepancy in receipt notes'; end if;
    update public.purchase_items set received_quantity=q,
      billed_quantity=case when p.payment_status='paid' then billed_quantity else q end,
      line_total=case when p.payment_status='paid' then line_total else q*unit_price end
      where tenant_id=t and purchase_item_id=r.purchase_item_id;
  end loop;
  if p.payment_status='unpaid' then perform app_private.recalculate_purchase(t,p_purchase_id); end if;
  for r in select item_id,type,sum(received_quantity) qty from public.purchase_items
    where tenant_id=t and purchase_id=p_purchase_id group by item_id,type order by item_id,type loop
    perform 1 from public.items where tenant_id=t and item_id=r.item_id for update;
    if r.qty>0 then
      insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,filled_quantity_change,notes,created_by)
      values(t,r.item_id,case when r.type='package' then 'purchase' else 'refill' end,
        case when r.type='package' then 'purchase_receipt_new' else 'purchase_receipt_refill' end,
        p_purchase_id,r.qty,case when r.type='package' then 'New filled cylinders received' else 'Refilled cylinders received' end,auth.uid());
    end if;
  end loop;
  -- Finalize saved operating expenses and the linked shipment on truck return.
  -- Completed legacy transits have already posted costs and are never re-posted.
  perform app_private.ensure_tenant_wallets(t);
  select wallet_id into wid from public.wallets where tenant_id=t and type='logistics' for update;
  for r in select * from public.transits where tenant_id=t and purchase_id=p_purchase_id and status='active' loop
    if r.total_cost>0 then
      insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description)
        values(t,wid,-r.total_cost,'transit_cost',r.transit_id,'Operating costs finalized on purchase receipt');
      update public.wallets set balance=balance-r.total_cost,updated_at=now() where tenant_id=t and wallet_id=wid;
    end if;
    update public.transits set status='completed',transport_fee=p.transport_cost,updated_at=now() where tenant_id=t and transit_id=r.transit_id;
  end loop;
  update public.purchases set status='received',received_at=now(),receipt_notes=p_receipt_notes,updated_at=now(),revision=revision+1
    where tenant_id=t and purchase_id=p_purchase_id;
  if not exists(select 1 from public.transits where tenant_id=t and truck_id=p.truck_id and status='active')
    and not exists(select 1 from public.purchases where tenant_id=t and truck_id=p.truck_id and status='in_transit') then
    update public.trucks set status='idle',updated_at=now() where tenant_id=t and truck_id=p.truck_id;
  end if;
  insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details)
    values(t,p_purchase_id,'received',auth.uid(),jsonb_build_object('quantities',p_items,'notes',p_receipt_notes,
      'billing',case when p.payment_status='paid' then 'Prepaid quantities retained' else 'Actual quantities billed' end));
  return jsonb_build_object('purchase_id',p_purchase_id);
end $$;

create function public.pay_purchase(p_purchase_id uuid,p_revision integer) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t uuid := app_private.require_permission('purchases:manage'); p public.purchases; dealership uuid; logistics uuid;
begin
  select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id for update;
  if not found then raise exception 'Purchase not found'; end if;
  if p.status not in ('in_transit','received') then raise exception 'Payment is allowed only after dispatch'; end if;
  if p.payment_status='paid' then return jsonb_build_object('purchase_id',p_purchase_id,'already_paid',true); end if;
  if p_revision is distinct from p.revision then raise exception 'Purchase changed. Reload before payment.' using errcode='40001'; end if;
  if p.total_cost<0 or p.company_payable<0 then raise exception 'Resolve historical financial amounts before payment'; end if;
  perform app_private.ensure_tenant_wallets(t);
  perform 1 from public.wallets where tenant_id=t order by wallet_id for update;
  select wallet_id into dealership from public.wallets where tenant_id=t and type='dealership';
  select wallet_id into logistics from public.wallets where tenant_id=t and type='logistics';
  -- Full payment, split company and logistics expenses in the dealership ledger.
  insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description) values
    (t,dealership,-p.company_payable,'purchase_company_payment',p_purchase_id,'Company payment after commission'),
    (t,dealership,-(coalesce(p.transport_cost,0)+coalesce(p.labour_cost,0)),'purchase_logistics_payment',p_purchase_id,'Purchase transport and labour expenses');
  update public.wallets set balance=balance-p.total_cost,updated_at=now() where tenant_id=t and wallet_id=dealership;
  -- Legacy logistics fees were credited by creation/editing already.
  if not p.legacy_record and p.transport_cost>0 then
    insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description)
      values(t,logistics,p.transport_cost,'purchase_transport_settlement',p_purchase_id,'Settled transport fee from purchase');
    update public.wallets set balance=balance+p.transport_cost,updated_at=now() where tenant_id=t and wallet_id=logistics;
  end if;
  update public.purchases set payment_status='paid',paid_at=now(),updated_at=now(),revision=revision+1
    where tenant_id=t and purchase_id=p_purchase_id;
  insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details)
    values(t,p_purchase_id,'paid',auth.uid(),jsonb_build_object('company_payable',p.company_payable,
      'transport_cost',p.transport_cost,'labour_cost',p.labour_cost,'total_cost',p.total_cost));
  return jsonb_build_object('purchase_id',p_purchase_id);
end $$;

-- Old clients must refresh instead of bypassing the new explicit confirmation,
-- actual receipt quantities, revision checks and payment boundary.
create or replace function public.create_purchase(p_truck_id uuid,p_plant_id uuid,p_transport_cost numeric,p_labour_cost numeric,p_notes text,p_items jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
begin perform app_private.require_permission('purchases:manage'); raise exception 'Purchase lifecycle updated. Refresh the application to create a purchase.'; end $$;
create or replace function public.update_purchase(p_purchase_id uuid,p_transport_cost numeric,p_labour_cost numeric,p_notes text,p_items jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
begin perform app_private.require_permission('purchases:manage'); raise exception 'Purchase lifecycle updated. Refresh the application to edit a purchase.'; end $$;
create or replace function public.complete_purchase(p_purchase_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
begin perform app_private.require_permission('purchases:manage'); raise exception 'Receipt and payment are separate actions. Refresh the application.'; end $$;

drop function public.list_purchases();
create function public.list_purchases() returns setof jsonb
language plpgsql security definer set search_path='' as $$
declare t uuid := app_private.require_any_permission(array['purchases:view','purchases:manage']);
begin
  return query select to_jsonb(p) || jsonb_build_object(
    'truck_name',tr.name,'plant_name',gp.plant_name,'company_name',b.brand_name,
    'operating_cost',(select coalesce(sum(total_cost),0) from public.transits where tenant_id=t and purchase_id=p.purchase_id),
    'items',coalesce((select jsonb_agg(to_jsonb(pi)||jsonb_build_object('brand_name',coalesce(lb.brand_name,i.brand),
      'size_kg',i.size_kg,'mouth_size',i.mouth_size) order by pi.created_at,pi.purchase_item_id)
      from public.purchase_items pi join public.items i on i.tenant_id=pi.tenant_id and i.item_id=pi.item_id
      left join public.lpg_brands lb on lb.tenant_id=i.tenant_id and lb.brand_id=i.brand_id
      where pi.tenant_id=t and pi.purchase_id=p.purchase_id),'[]'::jsonb))
    from public.purchases p left join public.trucks tr on tr.tenant_id=p.tenant_id and tr.truck_id=p.truck_id
    left join public.gas_plants gp on gp.tenant_id=p.tenant_id and gp.plant_id=p.plant_id
    left join public.lpg_brands b on b.tenant_id=p.tenant_id and b.brand_id=p.brand_id
    where p.tenant_id=t order by p.created_at desc;
end $$;

create function public.get_purchase_activity(p_purchase_id uuid) returns setof jsonb
language plpgsql security definer set search_path='' as $$
declare t uuid := app_private.require_any_permission(array['purchases:view','purchases:manage']);
begin
  return query select to_jsonb(a)||jsonb_build_object('actor_name',coalesce(nullif(u.full_name,''),u.email,'Historical user'))
    from public.purchase_activity a left join public.user_profiles u on u.tenant_id=a.tenant_id and u.user_id=a.created_by
    where a.tenant_id=t and a.purchase_id=p_purchase_id order by a.created_at,a.activity_id;
end $$;

-- Existing logistics RPCs stay in place; guards close sibling-workflow bypasses.
create function app_private.guard_purchase_transit() returns trigger
language plpgsql set search_path='' as $$
declare p public.purchases;
begin
  -- Serialize all transit allocation on the truck, including custom transits.
  if tg_op='INSERT' then
    perform 1 from public.trucks where tenant_id=new.tenant_id and truck_id=new.truck_id for update;
    if exists(select 1 from public.transits where tenant_id=new.tenant_id and truck_id=new.truck_id and status='active') then
      raise exception 'Truck already has an active transit'; end if;
    if new.purchase_id is null and exists(select 1 from public.purchases where tenant_id=new.tenant_id and truck_id=new.truck_id and status='in_transit') then
      raise exception 'Truck is reserved by an In Transit purchase'; end if;
  end if;
  if new.purchase_id is not null then
    select * into p from public.purchases where tenant_id=new.tenant_id and purchase_id=new.purchase_id;
    if tg_op='UPDATE' then
      if new.truck_id is distinct from old.truck_id or new.purchase_id is distinct from old.purchase_id then raise exception 'Purchase shipment is locked'; end if;
      -- Receipt finalizes transit while the purchase is still In Transit.
      -- Public logistics completion is blocked in its RPC, below.
      if p.status='received' and not (p.legacy_record and old.status='active' and new.status='completed')
        and (new.driver_cost,new.helper_cost,new.oil_cost,new.additional_costs,new.total_cost,new.status)
        is distinct from (old.driver_cost,old.helper_cost,old.oil_cost,old.additional_costs,old.total_cost,old.status) then
        raise exception 'Received shipment costs are finalized'; end if;
    end if;
  end if;
  return new;
end $$;
create trigger guard_purchase_transit before insert or update on public.transits
  for each row execute function app_private.guard_purchase_transit();

create function app_private.guard_truck_idle() returns trigger
language plpgsql set search_path='' as $$
begin
  if new.status='idle' and old.status<>'idle' and exists(select 1 from public.purchases
    where tenant_id=new.tenant_id and truck_id=new.truck_id and status='in_transit') then
    raise exception 'Receive the active purchase before releasing its truck'; end if;
  return new;
end $$;
create trigger guard_truck_idle before update on public.trucks for each row execute function app_private.guard_truck_idle();

create function app_private.guard_purchase_company() returns trigger
language plpgsql set search_path='' as $$
begin
  if new.brand_id is distinct from old.brand_id then
    if tg_table_name='gas_plants' then
      if exists(select 1 from public.purchases where tenant_id=old.tenant_id and plant_id=old.plant_id and not legacy_record) then
        raise exception 'A purchased plant cannot change company'; end if;
    else
      if exists(select 1 from public.purchase_items pi join public.purchases p on p.tenant_id=pi.tenant_id and p.purchase_id=pi.purchase_id
        where pi.tenant_id=old.tenant_id and pi.item_id=old.item_id and not p.legacy_record) then
        raise exception 'A purchased product cannot change company'; end if;
    end if;
  end if;
  return new;
end $$;
create trigger guard_plant_company before update on public.gas_plants for each row execute function app_private.guard_purchase_company();
create trigger guard_item_company before update on public.items for each row execute function app_private.guard_purchase_company();

-- Lock the purchase before its truck/transit to match receipt and prevent races.
create or replace function public.update_transit_costs(p_transit_id uuid,p_driver_cost numeric,p_helper_cost numeric,p_oil_cost numeric,p_additional_costs jsonb,p_status public.transit_status)
returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid := app_private.require_permission('logistics:manage'); tr public.transits; pid uuid; total numeric; x jsonb; wid uuid; p public.purchases;
begin
  select purchase_id into pid from public.transits where tenant_id=t and transit_id=p_transit_id;
  if pid is not null then
    select * into p from public.purchases where tenant_id=t and purchase_id=pid for update;
    if p.status='received' and not (p.legacy_record and p_status='completed') then raise exception 'Received shipment costs are finalized'; end if;
    if p.status<>'received' and (p_status<>'active' or p_status is null) then raise exception 'Finalize purchase shipments by receiving the purchase after truck return'; end if;
  end if;
  select * into tr from public.transits where tenant_id=t and transit_id=p_transit_id;
  if not found then raise exception 'Transit not found'; end if;
  perform 1 from public.trucks where tenant_id=t and truck_id=tr.truck_id for update;
  select * into tr from public.transits where tenant_id=t and transit_id=p_transit_id for update;
  if tr.status<>'active' then raise exception 'Transit is finalized and locked'; end if;
  if p_status is null then raise exception 'Transit status is required'; end if;
  total := app_private.purchase_money(p_driver_cost)+app_private.purchase_money(p_helper_cost)+app_private.purchase_money(p_oil_cost);
  p_additional_costs := coalesce(p_additional_costs,'[]'::jsonb);
  if jsonb_typeof(p_additional_costs)<>'array' then raise exception 'Additional costs must be an array'; end if;
  for x in select value from jsonb_array_elements(p_additional_costs) loop
    if nullif(trim(x->>'name'),'') is null then raise exception 'Additional cost name is required'; end if;
    total := total+app_private.purchase_money((x->>'amount')::numeric);
  end loop;
  update public.transits set driver_cost=p_driver_cost,helper_cost=p_helper_cost,oil_cost=p_oil_cost,
    additional_costs=p_additional_costs,total_cost=total,status=p_status,updated_at=now()
    where tenant_id=t and transit_id=p_transit_id;
  if p_status='completed' then
    perform app_private.ensure_tenant_wallets(t);
    select wallet_id into wid from public.wallets where tenant_id=t and type='logistics' for update;
    if total>0 then
      insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description)
        values(t,wid,-total,'transit_cost',p_transit_id,'Transit operating costs');
      update public.wallets set balance=balance-total,updated_at=now() where tenant_id=t and wallet_id=wid;
    end if;
    update public.trucks set status='idle',updated_at=now() where tenant_id=t and truck_id=tr.truck_id;
  end if;
  if pid is not null then
    update public.purchases set revision=revision+1,updated_at=now() where tenant_id=t and purchase_id=pid;
    insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details)
      values(t,pid,'logistics_updated',auth.uid(),jsonb_build_object('operating_cost',total));
  end if;
  return jsonb_build_object('transit_id',p_transit_id,'total_cost',total);
end $$;

create function public.list_transits() returns setof jsonb
language plpgsql security definer set search_path='' as $$
declare t uuid := app_private.require_any_permission(array['logistics:view','logistics:manage']);
begin
  return query select to_jsonb(tr)||jsonb_build_object('truck_name',truck.name,
    'legacy_completion',coalesce(p.legacy_record and p.status='received' and tr.status='active',false))
    from public.transits tr join public.trucks truck on truck.tenant_id=tr.tenant_id and truck.truck_id=tr.truck_id
    left join public.purchases p on p.tenant_id=tr.tenant_id and p.purchase_id=tr.purchase_id
    where tr.tenant_id=t order by tr.created_at desc;
end $$;

revoke all on function app_private.purchase_activity_immutable(),app_private.purchase_money(numeric),
  app_private.purchase_integer(jsonb),app_private.recalculate_purchase(uuid,uuid),
  app_private.save_purchase_lines(uuid,uuid,jsonb),app_private.guard_purchase_transit(),
  app_private.guard_truck_idle(),app_private.guard_purchase_company() from public,anon,authenticated;
revoke all on function public.create_purchase(jsonb),public.update_purchase(uuid,jsonb,integer),
  public.dispatch_purchase(uuid,integer),public.receive_purchase(uuid,jsonb,text,integer),
  public.pay_purchase(uuid,integer),public.list_purchases(),public.get_purchase_activity(uuid),public.list_transits() from public,anon,authenticated;
grant execute on function public.create_purchase(jsonb),public.update_purchase(uuid,jsonb,integer),
  public.dispatch_purchase(uuid,integer),public.receive_purchase(uuid,jsonb,text,integer),
  public.pay_purchase(uuid,integer),public.list_purchases(),public.get_purchase_activity(uuid),public.list_transits() to authenticated;
notify pgrst,'reload schema';
