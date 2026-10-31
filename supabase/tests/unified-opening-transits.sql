-- Continuation of reconstructed historical records is checked only inside the restored,
-- disposable VPS database, and this transaction also rolls back its changes.
begin;
create temp table opening_transit_checks(purchase_id uuid,item_id uuid,filled_value numeric,empty_value numeric,expected_receipt numeric,expected_return numeric);
do $$declare p record;r record;actor uuid;baseline numeric;after_value numeric;checks integer:=0;begin
 for p in select * from public.purchases where status='in_transit' order by tenant_id,purchase_id loop
  select u.user_id into actor from public.user_profiles u join public.user_roles ur using(tenant_id,user_id) join public.roles role using(tenant_id,role_id)
  where u.tenant_id=p.tenant_id and u.is_active and role.name='OWNER' limit 1;
  if actor is null then raise exception 'Opening fixture has no trusted owner';end if;
  perform set_config('request.jwt.claim.sub',actor::text,true);
  insert into opening_transit_checks
  select p.purchase_id,c.item_id,c.filled_value,c.empty_value,
   round(sum(pi.quantity*pi.unit_price)*case when p.subtotal>0 then p.payable_amount/p.subtotal else 1 end,2)+
   coalesce((select -sum(e.empty_value) from public.inventory_cost_entries e join public.inventory_movements m using(tenant_id,movement_id) where e.tenant_id=p.tenant_id and m.reference_id=p.purchase_id and m.reference_type='purchase_dispatch' and e.item_id=c.item_id),0),
   coalesce((select -sum(e.empty_value) from public.inventory_cost_entries e join public.inventory_movements m using(tenant_id,movement_id) where e.tenant_id=p.tenant_id and m.reference_id=p.purchase_id and m.reference_type='purchase_dispatch' and e.item_id=c.item_id),0)
  from public.inventory_costs c join public.purchase_items pi using(tenant_id,item_id) where c.tenant_id=p.tenant_id and pi.purchase_id=p.purchase_id group by c.item_id,c.filled_value,c.empty_value;
  -- Cancel and roll back the isolated subtransaction, then receive the same
  -- original order. Both paths must use its recorded dispatch shell allocation.
  begin
   perform public.initiate_purchase_cancellation(p.purchase_id,p.revision,'CANCEL',gen_random_uuid());
   for r in select * from opening_transit_checks where purchase_id=p.purchase_id loop
    select empty_value into after_value from public.inventory_costs where tenant_id=p.tenant_id and item_id=r.item_id;
    if after_value-r.empty_value<>r.expected_return then raise exception 'Opening cancellation lost the per-product shell value';end if;
   end loop;
   if coalesce((select sum(amount) from public.accounting_lines where tenant_id=p.tenant_id and account='inventory_transit' and entity_id=p.purchase_id),0)<>0 then raise exception 'Opening cancellation did not clear transit inventory';end if;
   raise exception using errcode='ZX001',message='Roll back only the cancellation test';
  exception when sqlstate 'ZX001' then null;end;
  perform public.receive_purchase(p.purchase_id,p.revision);
  for r in select * from opening_transit_checks where purchase_id=p.purchase_id loop
   select filled_value into after_value from public.inventory_costs where tenant_id=p.tenant_id and item_id=r.item_id;
   if abs(after_value-r.filled_value-r.expected_receipt)>0.02 then raise exception 'Opening receipt lost the per-product transit carrying value';end if;
  end loop;
  if coalesce((select sum(amount) from public.accounting_lines where tenant_id=p.tenant_id and account='inventory_transit' and entity_id=p.purchase_id),0)<>0 then raise exception 'Opening receipt did not clear transit inventory';end if;
  checks:=checks+1;
 end loop;
 if checks=0 then raise exception 'No pre-opening in-transit records were available for continuation checks';end if;
end $$;
set constraints all immediate;
select 'PASS: pre-opening transit cancellation and receipt retain per-product dispatch shell values and clear all transit inventory';
rollback;
