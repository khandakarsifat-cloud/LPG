-- Separate truck completion from expense closure. Preserve historical ledger/stock.
alter table public.transits
  add column client_name text,
  add column destination text,
  add column description text,
  add column others_cost numeric(12,2) not null default 0 check (others_cost>=0),
  add column revision integer not null default 1,
  add column closed_at timestamptz;
-- Earlier Completed transits already finalized expenses (including zero costs).
update public.transits set closed_at=coalesce(updated_at,created_at,now()) where status='completed';
update public.transits tr set client_name=coalesce(b.brand_name,gp.plant_name),
  destination=gp.plant_name,description=p.notes
from public.purchases p join public.gas_plants gp on gp.tenant_id=p.tenant_id and gp.plant_id=p.plant_id
left join public.lpg_brands b on b.tenant_id=p.tenant_id and b.brand_id=p.brand_id
where tr.tenant_id=p.tenant_id and tr.purchase_id=p.purchase_id;
alter table public.purchases add column transport_funded numeric(12,2) not null default 0,
  add column cancelled_at timestamptz;
update public.purchases p set transport_funded=coalesce((select sum(wt.amount)
  from public.wallet_transactions wt join public.wallets w on w.tenant_id=wt.tenant_id and w.wallet_id=wt.wallet_id
  where wt.tenant_id=p.tenant_id and wt.reference_id=p.purchase_id and w.type='logistics'
    and wt.type in ('transport_income','transport_income_adj','purchase_transport_settlement')),0);
create unique index transit_close_once on public.wallet_transactions(tenant_id,reference_id,type)
  where type in ('transit_close_cost','transit_client_refund','purchase_cancel_refund','purchase_transport_refund');

-- Lock all requested SKUs first and report every shortage, including concurrent changes.
create function app_private.check_purchase_empties(t uuid, lines jsonb) returns void
language plpgsql set search_path='' as $$
declare x record; shortages jsonb := '[]';
begin
  for x in select i.item_id from public.items i where i.tenant_id=t and i.item_id in
    (select (value->>'item_id')::uuid from jsonb_array_elements(lines) where value->>'type'='refill')
    order by i.item_id for update loop null; end loop;
  select coalesce(jsonb_agg(jsonb_build_object('item_id',s.item_id,'product',s.product,
    'required',s.required,'available',s.available,'missing',s.required-s.available)),'[]') into shortages
  from (select i.item_id,concat(coalesce(b.brand_name,i.brand),' ',i.size_kg,' kg ',i.mouth_size) product,
    sum((l.value->>'quantity')::integer) required,i.empty_quantity available
    from jsonb_array_elements(lines) l join public.items i on i.tenant_id=t and i.item_id=(l.value->>'item_id')::uuid
    left join public.lpg_brands b on b.tenant_id=i.tenant_id and b.brand_id=i.brand_id
    where l.value->>'type'='refill' group by i.item_id,i.brand,b.brand_name,i.size_kg,i.mouth_size,i.empty_quantity
    having sum((l.value->>'quantity')::integer)>i.empty_quantity) s;
  if jsonb_array_length(shortages)>0 then
    raise exception 'Not enough empty cylinders' using detail=shortages::text;
  end if;
end $$;

-- Caller holds purchase/truck/transit locks; lock wallets consistently before transfer.
create function app_private.fund_purchase_transport(t uuid, pid uuid) returns void
language plpgsql set search_path='' as $$
declare p public.purchases; delta numeric; dw uuid; lw uuid;
begin
  select * into p from public.purchases where tenant_id=t and purchase_id=pid;
  delta:=coalesce(p.transport_cost,0)-p.transport_funded;
  if delta=0 then return; end if;
  perform app_private.ensure_tenant_wallets(t);
  perform 1 from public.wallets where tenant_id=t order by wallet_id for update;
  select wallet_id into dw from public.wallets where tenant_id=t and type='dealership';
  select wallet_id into lw from public.wallets where tenant_id=t and type='logistics';
  insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description) values
    (t,dw,-delta,'purchase_transport_funding',pid,'Transport fee transferred to logistics'),
    (t,lw,delta,'purchase_transport_funding',pid,'Transport fee from dealership');
  update public.wallets set balance=balance-delta,updated_at=now() where tenant_id=t and wallet_id=dw;
  update public.wallets set balance=balance+delta,updated_at=now() where tenant_id=t and wallet_id=lw;
  update public.purchases set transport_funded=coalesce(transport_cost,0) where tenant_id=t and purchase_id=pid;
end $$;


create or replace function app_private.save_purchase_lines(p_tenant uuid,p_purchase uuid,p_lines jsonb) returns void
language plpgsql set search_path = '' as $$
declare p public.purchases; x jsonb; i public.items; q integer; e integer; price numeric; line_id uuid;
begin
  select * into p from public.purchases where tenant_id=p_tenant and purchase_id=p_purchase;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' then raise exception 'Products must be an array'; end if;
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

create or replace function public.dispatch_purchase(p_purchase_id uuid,p_revision integer) returns jsonb
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
  insert into public.transits(tenant_id,truck_id,purchase_id,status,transport_fee)
    values(t,p.truck_id,p_purchase_id,'active',p.transport_cost);
  perform app_private.fund_purchase_transport(t,p_purchase_id);
  update public.trucks set status='going',updated_at=now() where tenant_id=t and truck_id=p.truck_id;
  update public.purchases set status='in_transit',dispatched_at=now(),updated_at=now(),revision=revision+1
    where tenant_id=t and purchase_id=p_purchase_id;
  insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details)
    values(t,p_purchase_id,'dispatched',auth.uid(),jsonb_build_object('empty_cylinders',
      (select sum(empty_dispatched) from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id)));
  return jsonb_build_object('purchase_id',p_purchase_id);
end $$;

create or replace function public.update_purchase(p_purchase_id uuid,p_payload jsonb,p_revision integer) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t uuid := app_private.require_permission('purchases:manage'); p public.purchases; truck uuid;
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
    if exists(select 1 from public.transits where tenant_id=t and purchase_id=p_purchase_id and closed_at is not null)
      and (select transport_cost from public.purchases where tenant_id=t and purchase_id=p_purchase_id) is distinct from p.transport_cost then
      raise exception 'Transport fee is locked because the transit is closed'; end if;
    update public.transits set transport_fee=(select transport_cost from public.purchases where tenant_id=t and purchase_id=p_purchase_id)
      where tenant_id=t and purchase_id=p_purchase_id;
    if p.status<>'created' then perform app_private.fund_purchase_transport(t,p_purchase_id); end if;
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

-- New receipt accepts only a saved purchase and always receives expected quantities.
create function public.receive_purchase(p_purchase_id uuid,p_revision integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('purchases:manage'); p public.purchases; r record;
begin
  select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id for update;
  if not found then raise exception 'Purchase not found'; end if;
  if p.status='received' then return jsonb_build_object('already_received',true); end if;
  if p.status<>'in_transit' then raise exception 'Only an In Transit purchase can be received'; end if;
  if p_revision is distinct from p.revision then raise exception 'Purchase changed. Reload before receipt.' using errcode='40001'; end if;
  perform 1 from public.trucks where tenant_id=t and truck_id=p.truck_id for update;
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
  update public.transits set status='completed',revision=revision+1,updated_at=now()
    where tenant_id=t and purchase_id=p_purchase_id and status='active';
  update public.purchases set status='received',received_at=now(),updated_at=now(),revision=revision+1
    where tenant_id=t and purchase_id=p_purchase_id;
  if not exists(select 1 from public.transits where tenant_id=t and truck_id=p.truck_id and status='active')
    and not exists(select 1 from public.purchases where tenant_id=t and truck_id=p.truck_id and status='in_transit') then
    update public.trucks set status='idle',updated_at=now() where tenant_id=t and truck_id=p.truck_id;
  end if;
  insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details)
    values(t,p_purchase_id,'received',auth.uid(),jsonb_build_object('notes','Expected quantities received; transit costs remain open'));
  return jsonb_build_object('purchase_id',p_purchase_id);
end $$;
-- Cached clients cannot submit differing receipt quantities.
create or replace function public.receive_purchase(p_purchase_id uuid,p_items jsonb,p_receipt_notes text,p_revision integer) returns jsonb
language plpgsql security definer set search_path='' as $$
begin perform app_private.require_permission('purchases:manage'); raise exception 'Receipt updated. Refresh the application; expected quantities are always received.'; end $$;


create or replace function public.pay_purchase(p_purchase_id uuid,p_revision integer) returns jsonb
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
  perform app_private.fund_purchase_transport(t,p_purchase_id);
  p.transport_funded:=coalesce(p.transport_cost,0);
  -- Old credited transport with no dealership debit is charged at payment once.
  insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description) values
    (t,dealership,-p.company_payable,'purchase_company_payment',p_purchase_id,'Company payment after commission'),
    (t,dealership,-(coalesce(p.labour_cost,0)+p.transport_funded
      +coalesce((select sum(amount) from public.wallet_transactions where tenant_id=t and wallet_id=dealership
        and reference_id=p_purchase_id and type='purchase_transport_funding'),0)),
      'purchase_logistics_payment',p_purchase_id,'Labour and any historical transport balance');
  update public.wallets set balance=balance-p.company_payable-coalesce(p.labour_cost,0)-p.transport_funded
    -coalesce((select sum(amount) from public.wallet_transactions where tenant_id=t and wallet_id=dealership
      and reference_id=p_purchase_id and type='purchase_transport_funding'),0),updated_at=now()
    where tenant_id=t and wallet_id=dealership;
  update public.purchases set payment_status='paid',paid_at=now(),updated_at=now(),revision=revision+1
    where tenant_id=t and purchase_id=p_purchase_id;
  insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details)
    values(t,p_purchase_id,'paid',auth.uid(),jsonb_build_object('company_payable',p.company_payable,
      'transport_cost',p.transport_cost,'labour_cost',p.labour_cost,'total_cost',p.total_cost));
  return jsonb_build_object('purchase_id',p_purchase_id);
end $$;

create or replace function app_private.guard_purchase_transit() returns trigger
language plpgsql set search_path='' as $$
begin
  if tg_op='INSERT' then
    perform 1 from public.trucks where tenant_id=new.tenant_id and truck_id=new.truck_id for update;
    if exists(select 1 from public.transits where tenant_id=new.tenant_id and truck_id=new.truck_id and status='active') then
      raise exception 'Truck already has an active transit'; end if;
    if new.purchase_id is null and exists(select 1 from public.purchases where tenant_id=new.tenant_id and truck_id=new.truck_id and status='in_transit') then
      raise exception 'Truck is reserved by an In Transit purchase'; end if;
    if new.purchase_id is not null then
      select coalesce(b.brand_name,gp.plant_name),gp.plant_name,p.notes into new.client_name,new.destination,new.description
      from public.purchases p join public.gas_plants gp on gp.tenant_id=p.tenant_id and gp.plant_id=p.plant_id
      left join public.lpg_brands b on b.tenant_id=p.tenant_id and b.brand_id=p.brand_id
      where p.tenant_id=new.tenant_id and p.purchase_id=new.purchase_id;
    end if;
  else
    if (new.truck_id,new.purchase_id) is distinct from (old.truck_id,old.purchase_id) then raise exception 'Transit assignment is locked'; end if;
    if old.closed_at is not null and (new.driver_cost,new.helper_cost,new.oil_cost,new.others_cost,new.additional_costs,new.total_cost)
      is distinct from (old.driver_cost,old.helper_cost,old.oil_cost,old.others_cost,old.additional_costs,old.total_cost) then
      raise exception 'Closed transit costs are locked'; end if;
  end if;
  return new;
end $$;

create function public.save_transit_costs(p_transit_id uuid,p_costs jsonb,p_revision integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('logistics:manage'); tr public.transits; pid uuid; x jsonb; total numeric;
  driver numeric:=app_private.purchase_money((p_costs->>'driver_cost')::numeric);
  helper numeric:=app_private.purchase_money((p_costs->>'helper_cost')::numeric);
  oil numeric:=app_private.purchase_money((p_costs->>'oil_cost')::numeric);
  others numeric:=app_private.purchase_money((p_costs->>'others_cost')::numeric);
  extra jsonb:=coalesce(p_costs->'additional_costs','[]');
begin
  select purchase_id into pid from public.transits where tenant_id=t and transit_id=p_transit_id;
  if pid is not null then perform 1 from public.purchases where tenant_id=t and purchase_id=pid for update; end if;
  select * into tr from public.transits where tenant_id=t and transit_id=p_transit_id for update;
  if not found then raise exception 'Transit not found'; end if;
  if tr.closed_at is not null then raise exception 'Closed transit costs are locked'; end if;
  if p_revision is distinct from tr.revision then raise exception 'Transit changed. Reload before saving.' using errcode='40001'; end if;
  if jsonb_typeof(extra)<>'array' then raise exception 'Additional costs must be an array'; end if;
  total:=driver+helper+oil+others;
  for x in select value from jsonb_array_elements(extra) loop
    if nullif(trim(x->>'name'),'') is null then raise exception 'Additional cost name is required'; end if;
    total:=total+app_private.purchase_money((x->>'amount')::numeric);
  end loop;
  update public.transits set driver_cost=driver,helper_cost=helper,oil_cost=oil,others_cost=others,
    additional_costs=extra,total_cost=total,updated_at=now(),revision=revision+1 where tenant_id=t and transit_id=p_transit_id;
  if pid is not null then
    insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details)
      values(t,pid,'logistics_updated',auth.uid(),jsonb_build_object('operating_cost',total));
  end if;
  return jsonb_build_object('transit_id',p_transit_id);
end $$;
create or replace function public.update_transit_costs(p_transit_id uuid,p_driver_cost numeric,p_helper_cost numeric,p_oil_cost numeric,p_additional_costs jsonb,p_status public.transit_status)
returns jsonb language plpgsql security definer set search_path='' as $$
begin perform app_private.require_permission('logistics:manage'); raise exception 'Transit workflow updated. Refresh the application.'; end $$;

create function public.create_custom_transit(p_payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('logistics:manage'); truck public.trucks; id uuid; wid uuid;
  fee numeric:=app_private.purchase_money((p_payload->>'fee')::numeric);
begin
  select * into truck from public.trucks where tenant_id=t and truck_id=(p_payload->>'truck_id')::uuid for update;
  if not found or truck.status<>'idle' then raise exception 'Select an idle truck'; end if;
  if nullif(trim(p_payload->>'client_name'),'') is null then raise exception 'Client name is required'; end if;
  insert into public.transits(tenant_id,truck_id,status,transport_fee,client_name,destination,description)
    values(t,truck.truck_id,'active',fee,trim(p_payload->>'client_name'),p_payload->>'destination',p_payload->>'description') returning transit_id into id;
  update public.trucks set status='going',updated_at=now() where tenant_id=t and truck_id=truck.truck_id;
  perform app_private.ensure_tenant_wallets(t);
  select wallet_id into wid from public.wallets where tenant_id=t and type='logistics' for update;
  if fee>0 then
    insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description)
      values(t,wid,fee,'transport_income',id,'Custom transit client fee');
    update public.wallets set balance=balance+fee,updated_at=now() where tenant_id=t and wallet_id=wid;
  end if;
  return jsonb_build_object('transit_id',id);
end $$;
create or replace function public.create_custom_transit(p_truck_id uuid,p_fee numeric,p_notes text) returns jsonb
language plpgsql security definer set search_path='' as $$
begin perform app_private.require_permission('logistics:manage'); raise exception 'Client name is required. Refresh the application.'; end $$;

create function public.transition_transit(p_transit_id uuid,p_action text,p_revision integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('logistics:manage'); tr public.transits; pid uuid; wid uuid; refund numeric;
begin
  select purchase_id into pid from public.transits where tenant_id=t and transit_id=p_transit_id;
  if pid is not null then perform 1 from public.purchases where tenant_id=t and purchase_id=pid for update; end if;
  select * into tr from public.transits where tenant_id=t and transit_id=p_transit_id;
  if not found then raise exception 'Transit not found'; end if;
  perform 1 from public.trucks where tenant_id=t and truck_id=tr.truck_id for update;
  select * into tr from public.transits where tenant_id=t and transit_id=p_transit_id for update;
  if p_action not in ('complete','cancel','close') or p_action is null then raise exception 'Invalid transit action'; end if;
  if p_action='close' and tr.closed_at is not null or p_action='complete' and tr.status='completed'
    or p_action='cancel' and tr.status='cancelled' then return jsonb_build_object('already_applied',true); end if;
  if tr.closed_at is not null then raise exception 'Transit is closed'; end if;
  if p_revision is distinct from tr.revision then raise exception 'Transit changed. Reload before continuing.' using errcode='40001'; end if;
  if p_action in ('complete','cancel') and pid is not null then raise exception 'Purchase transits follow the purchase. Receive or cancel it in Purchases.'; end if;
  if p_action='complete' and tr.status<>'active' then raise exception 'Only an active transit can be completed'; end if;
  if p_action='close' and tr.status='active' then raise exception 'Complete the transit before closing its costs'; end if;
  perform app_private.ensure_tenant_wallets(t);
  select wallet_id into wid from public.wallets where tenant_id=t and type='logistics' for update;
  if p_action='cancel' then
    select coalesce(sum(amount),0) into refund from public.wallet_transactions where tenant_id=t and wallet_id=wid
      and reference_id=p_transit_id and type='transport_income';
    if refund>0 then
      insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description)
        values(t,wid,-refund,'transit_client_refund',p_transit_id,'Full transport fee refunded to client');
      update public.wallets set balance=balance-refund,updated_at=now() where tenant_id=t and wallet_id=wid;
    end if;
    update public.transits set status='cancelled',revision=revision+1,updated_at=now() where tenant_id=t and transit_id=p_transit_id;
  elsif p_action='complete' then
    update public.transits set status='completed',revision=revision+1,updated_at=now() where tenant_id=t and transit_id=p_transit_id;
  else
    if tr.total_cost>0 then
      insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description)
        values(t,wid,-tr.total_cost,'transit_close_cost',p_transit_id,'Transit operating costs on closure');
      update public.wallets set balance=balance-tr.total_cost,updated_at=now() where tenant_id=t and wallet_id=wid;
    end if;
    update public.transits set closed_at=now(),revision=revision+1,updated_at=now() where tenant_id=t and transit_id=p_transit_id;
  end if;
  if not exists(select 1 from public.transits where tenant_id=t and truck_id=tr.truck_id and status='active')
    and not exists(select 1 from public.purchases where tenant_id=t and truck_id=tr.truck_id and status='in_transit') then
    update public.trucks set status='idle',updated_at=now() where tenant_id=t and truck_id=tr.truck_id;
  end if;
  if pid is not null then insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details)
    values(t,pid,'transit_closed',auth.uid(),jsonb_build_object('operating_cost',tr.total_cost)); end if;
  return jsonb_build_object('transit_id',p_transit_id);
end $$;

create function public.cancel_purchase(p_purchase_id uuid,p_revision integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('purchases:manage'); p public.purchases; r record; dw uuid; lw uuid; refund numeric;
begin
  select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id for update;
  if not found then raise exception 'Purchase not found'; end if;
  if p.status='cancelled' then return jsonb_build_object('already_cancelled',true); end if;
  if p_revision is distinct from p.revision then raise exception 'Purchase changed. Reload before cancellation.' using errcode='40001'; end if;
  perform 1 from public.trucks where tenant_id=t and truck_id=p.truck_id for update;
  perform 1 from public.transits where tenant_id=t and purchase_id=p_purchase_id order by transit_id for update;
  -- Reverse recorded movements, including precisely identified historical notes.
  for r in select m.item_id,sum(m.filled_quantity_change) filled,sum(m.empty_quantity_change) empties
    from public.inventory_movements m where m.tenant_id=t and
      (m.reference_id=p_purchase_id and m.reference_type in ('purchase_dispatch','purchase_receipt_refill','purchase_receipt_new')
      or p.legacy_record and m.reference_id is null and m.notes in
        ('Empty bottles sent for refill (Purchase '||p_purchase_id||')','Received goods from Purchase '||p_purchase_id,
         'Quantity adjustment for Purchase '||p_purchase_id))
    group by m.item_id order by m.item_id loop
    perform 1 from public.items where tenant_id=t and item_id=r.item_id for update;
    if exists(select 1 from public.items where tenant_id=t and item_id=r.item_id
      and (filled_quantity-r.filled<0 or empty_quantity-r.empties<0)) then
      raise exception 'Cannot cancel: received cylinders are no longer available in stock. Restore the stock before cancelling.'; end if;
    insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,filled_quantity_change,empty_quantity_change,notes,created_by)
      values(t,r.item_id,'purchase_adjustment','purchase_cancellation',p_purchase_id,-r.filled,-r.empties,'Purchase cancelled: stock reversed',auth.uid());
  end loop;
  perform app_private.ensure_tenant_wallets(t);
  perform 1 from public.wallets where tenant_id=t order by wallet_id for update;
  select wallet_id into dw from public.wallets where tenant_id=t and type='dealership';
  select wallet_id into lw from public.wallets where tenant_id=t and type='logistics';
  select -coalesce(sum(amount),0) into refund from public.wallet_transactions where tenant_id=t and wallet_id=dw
    and reference_id=p_purchase_id and type in ('purchase_expense','purchase_company_payment','purchase_logistics_payment','purchase_transport_funding');
  if refund<>0 then
    insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description)
      values(t,dw,refund,'purchase_cancel_refund',p_purchase_id,'Cancelled purchase payments refunded');
    update public.wallets set balance=balance+refund,updated_at=now() where tenant_id=t and wallet_id=dw;
  end if;
  select coalesce(sum(amount),0) into refund from public.wallet_transactions where tenant_id=t and wallet_id=lw
    and reference_id=p_purchase_id and type in ('transport_income','transport_income_adj','purchase_transport_settlement','purchase_transport_funding');
  if refund<>0 then
    insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description)
      values(t,lw,-refund,'purchase_transport_refund',p_purchase_id,'Cancelled purchase transport fee returned');
    update public.wallets set balance=balance-refund,updated_at=now() where tenant_id=t and wallet_id=lw;
  end if;
  update public.transits set status='cancelled',revision=revision+1,updated_at=now() where tenant_id=t and purchase_id=p_purchase_id;
  update public.purchases set status='cancelled',cancelled_at=now(),updated_at=now(),revision=revision+1 where tenant_id=t and purchase_id=p_purchase_id;
  if not exists(select 1 from public.transits where tenant_id=t and truck_id=p.truck_id and status='active')
    and not exists(select 1 from public.purchases where tenant_id=t and truck_id=p.truck_id and status='in_transit') then
    update public.trucks set status='idle',updated_at=now() where tenant_id=t and truck_id=p.truck_id;
  end if;
  insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details)
    values(t,p_purchase_id,'cancelled',auth.uid(),jsonb_build_object('previous_status',p.status,'notes','Stock and recorded payments reversed; incurred transit costs retained'));
  return jsonb_build_object('purchase_id',p_purchase_id);
end $$;


create or replace function public.list_transits() returns setof jsonb
language plpgsql security definer set search_path='' as $$
declare t uuid := app_private.require_any_permission(array['logistics:view','logistics:manage']);
begin
  return query select to_jsonb(tr)||jsonb_build_object('truck_name',truck.name,
    'status',case when p.status='received' and tr.status='active' then 'completed' else tr.status::text end)
    from public.transits tr join public.trucks truck on truck.tenant_id=tr.tenant_id and truck.truck_id=tr.truck_id
    left join public.purchases p on p.tenant_id=tr.tenant_id and p.purchase_id=tr.purchase_id
    where tr.tenant_id=t order by tr.created_at desc;
end $$;

-- Normalize old received/active truck assignments without posting costs.
update public.transits tr set status='completed',revision=tr.revision+1 from public.purchases p
  where p.tenant_id=tr.tenant_id and p.purchase_id=tr.purchase_id and p.status='received' and tr.status='active';
update public.trucks truck set status='idle',updated_at=now()
  where exists(select 1 from public.transits tr join public.purchases p on p.tenant_id=tr.tenant_id and p.purchase_id=tr.purchase_id
    where tr.tenant_id=truck.tenant_id and tr.truck_id=truck.truck_id and p.status='received')
  and not exists(select 1 from public.transits where tenant_id=truck.tenant_id and truck_id=truck.truck_id and status='active')
  and not exists(select 1 from public.purchases where tenant_id=truck.tenant_id and truck_id=truck.truck_id and status='in_transit');


alter function app_private.check_purchase_empties(uuid,jsonb) owner to postgres;
revoke all on function app_private.check_purchase_empties(uuid,jsonb) from public,anon,authenticated;

alter function app_private.fund_purchase_transport(uuid,uuid) owner to postgres;
revoke all on function app_private.fund_purchase_transport(uuid,uuid) from public,anon,authenticated;

alter function public.receive_purchase(uuid,integer) owner to postgres;
revoke all on function public.receive_purchase(uuid,integer) from public,anon,authenticated;

grant execute on function public.receive_purchase(uuid,integer) to authenticated;

alter function public.save_transit_costs(uuid,jsonb,integer) owner to postgres;
revoke all on function public.save_transit_costs(uuid,jsonb,integer) from public,anon,authenticated;

grant execute on function public.save_transit_costs(uuid,jsonb,integer) to authenticated;

alter function public.create_custom_transit(jsonb) owner to postgres;
revoke all on function public.create_custom_transit(jsonb) from public,anon,authenticated;

grant execute on function public.create_custom_transit(jsonb) to authenticated;

alter function public.transition_transit(uuid,text,integer) owner to postgres;
revoke all on function public.transition_transit(uuid,text,integer) from public,anon,authenticated;

grant execute on function public.transition_transit(uuid,text,integer) to authenticated;

alter function public.cancel_purchase(uuid,integer) owner to postgres;
revoke all on function public.cancel_purchase(uuid,integer) from public,anon,authenticated;

grant execute on function public.cancel_purchase(uuid,integer) to authenticated;

notify pgrst,'reload schema';
