-- Restore the single-quantity refill exchange on Created plans only.
-- Keep actual receipt, prepaid billing, historical dispatched quantities and
-- every existing stock/wallet row intact. Public RPC signatures are unchanged.
create or replace function app_private.save_purchase_lines(p_tenant uuid,p_purchase uuid,p_lines jsonb) returns void
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

alter function app_private.save_purchase_lines(uuid,uuid,jsonb) owner to postgres;
alter function public.dispatch_purchase(uuid,integer) owner to postgres;
revoke all on function app_private.save_purchase_lines(uuid,uuid,jsonb) from public,anon,authenticated;
revoke all on function public.dispatch_purchase(uuid,integer) from public,anon;
grant execute on function public.dispatch_purchase(uuid,integer) to authenticated;
notify pgrst,'reload schema';
