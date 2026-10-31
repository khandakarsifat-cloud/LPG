-- Valuation follows the application's existing physical stock deltas, including
-- bottle exchange/receipt and reversible empty dispatch. No price-book value is
-- used. Filled/empty weighted averages are independent cost pools.
create function app_private.inventory_cost_created() returns trigger language plpgsql security definer set search_path='' as $$begin
 insert into public.inventory_costs(tenant_id,item_id) values(new.tenant_id,new.item_id);return new;end $$;
create trigger cost_pool_created after insert on public.items for each row execute function app_private.inventory_cost_created();
create function app_private.cost_inventory_movement() returns trigger language plpgsql set search_path='' as $$
declare c public.inventory_costs;p public.purchases;r record;fc numeric:=0;ec numeric:=0;counter text:='cogs';cat text:='lpg';account text:='inventory_lpg';
 asset_value numeric:=0;before_qty integer;gain numeric:=0;entity uuid:=new.reference_id;d date:=(clock_timestamp() at time zone 'Asia/Dhaka')::date;invoice numeric;totalqty numeric;empty_cost numeric;estimate boolean:=false;begin
 select * into c from public.inventory_costs where tenant_id=new.tenant_id and item_id=new.item_id for update;
 if not found then raise exception 'Missing inventory cost pool';end if;
 if (c.filled_quantity+new.filled_quantity_change<0 or c.empty_quantity+new.empty_quantity_change<0) then raise exception 'Insufficient valued stock';end if;
 select coalesce(to_jsonb(i)->>'business_category','lpg') into cat from public.items i where tenant_id=new.tenant_id and item_id=new.item_id;
 account:=case when cat='stove' then 'inventory_stove' else 'inventory_lpg' end;
 if new.filled_quantity_change<0 then fc:=case when -new.filled_quantity_change=c.filled_quantity then -c.filled_value else round(c.filled_value/c.filled_quantity*new.filled_quantity_change,2) end;end if;
 if new.empty_quantity_change<0 then ec:=case when -new.empty_quantity_change=c.empty_quantity then -c.empty_value else round(c.empty_value/c.empty_quantity*new.empty_quantity_change,2) end;end if;
 empty_cost:=coalesce(case when c.empty_quantity>0 then c.empty_value/c.empty_quantity end,c.empty_unit_cost);
 if new.reference_type in ('purchase_receipt_new','purchase_receipt_refill','stove_purchase_receipt') then
  select * into p from public.purchases where tenant_id=new.tenant_id and purchase_id=new.reference_id;
  select sum(pi.billed_quantity*pi.unit_price),sum(pi.billed_quantity) into invoice,totalqty from public.purchase_items pi where pi.tenant_id=new.tenant_id and pi.purchase_id=new.reference_id and pi.item_id=new.item_id
   and pi.type=case when new.reference_type='purchase_receipt_refill' then 'refill'::public.purchase_type else 'package'::public.purchase_type end;
  -- Invoice commission is a purchase discount. Internal transport is eliminated;
  -- actual transit costs are incurred separately, once. Labour is landed cost.
  fc:=round(invoice/nullif(totalqty,0)*new.filled_quantity_change*(case when p.subtotal=0 then 1 else (p.company_payable+p.labour_cost)/p.subtotal end),2);
  if p.subtotal=0 then fc:=round(new.filled_quantity_change*p.labour_cost/nullif((select sum(quantity) from public.purchase_items where tenant_id=new.tenant_id and purchase_id=new.reference_id),0),2);end if;
  if new.reference_type='purchase_receipt_refill' then
   select coalesce(-sum(e.empty_value),0) into ec from public.inventory_cost_entries e join public.inventory_movements m using(tenant_id,movement_id)
   where e.tenant_id=new.tenant_id and e.item_id=new.item_id and m.reference_id=new.reference_id and m.reference_type='purchase_dispatch';
   if not exists(select 1 from public.inventory_cost_entries e join public.inventory_movements m using(tenant_id,movement_id) where e.tenant_id=new.tenant_id and e.item_id=new.item_id and m.reference_id=new.reference_id and m.reference_type='purchase_dispatch') then
    select coalesce(sum(l.amount),0) into ec from public.accounting_lines l join public.accounting_journals j using(tenant_id,journal_id) where l.tenant_id=new.tenant_id and l.account='inventory_transit' and l.entity_id=new.reference_id and j.source='opening' and l.details->>'component'='dispatched_cylinder' and (l.details->>'item_id')::uuid=new.item_id;
   end if;
   -- The dispatched shell remains an asset in transit until its filled return.
   fc:=fc+ec;ec:=0;
  end if;
  if (select coalesce(sum(pi.quantity),0) from public.purchase_items pi where pi.tenant_id=new.tenant_id and pi.purchase_id=new.reference_id)
   =(select coalesce(sum(e.filled_change),0) from public.inventory_cost_entries e join public.inventory_movements m using(tenant_id,movement_id) where e.tenant_id=new.tenant_id and m.reference_id=new.reference_id and m.reference_type in ('purchase_receipt_new','purchase_receipt_refill','stove_purchase_receipt'))+new.filled_quantity_change then
   select coalesce(sum(amount),0) into fc from public.accounting_lines al where al.tenant_id=new.tenant_id and al.account='inventory_transit' and entity_id=new.reference_id;
  end if;counter:='inventory_transit';
 elsif new.reference_type='stove_purchase_cancellation' then
  select -coalesce(sum(e.filled_value),0) into fc from public.inventory_cost_entries e join public.inventory_movements m using(tenant_id,movement_id) where e.tenant_id=new.tenant_id and e.item_id=new.item_id and m.reference_id=new.reference_id and m.reference_type='stove_purchase_receipt';
  if c.filled_value+fc<0 then raise exception 'Recorded purchase value has been consumed; purchase cannot be reversed from the remaining inventory';end if;counter:='inventory_transit';
 elsif new.reference_type='purchase_dispatch' then counter:='inventory_transit';
 elsif new.reference_type='purchase_cancellation' then
  select coalesce(-sum(e.empty_value),0) into ec from public.inventory_cost_entries e join public.inventory_movements m using(tenant_id,movement_id)
  where e.tenant_id=new.tenant_id and e.item_id=new.item_id and m.reference_id=new.reference_id and m.reference_type='purchase_dispatch';
   if not exists(select 1 from public.inventory_cost_entries e join public.inventory_movements m using(tenant_id,movement_id) where e.tenant_id=new.tenant_id and e.item_id=new.item_id and m.reference_id=new.reference_id and m.reference_type='purchase_dispatch') then
    select coalesce(sum(l.amount),0) into ec from public.accounting_lines l join public.accounting_journals j using(tenant_id,journal_id) where l.tenant_id=new.tenant_id and l.account='inventory_transit' and l.entity_id=new.reference_id and j.source='opening' and l.details->>'component'='dispatched_cylinder' and (l.details->>'item_id')::uuid=new.item_id;
   end if;counter:='inventory_transit';
 elsif new.valuation is not null then
  counter:=new.valuation->>'counter_account';
  if counter not in ('opening_equity','inventory_loss','other_income','capital') then raise exception 'Invalid stock adjustment classification';end if;
  if new.filled_quantity_change>0 then fc:=round(new.filled_quantity_change*app_private.purchase_money((new.valuation->>'filled_unit_cost')::numeric),2);end if;
  if new.empty_quantity_change>0 then ec:=round(new.empty_quantity_change*app_private.purchase_money((new.valuation->>'empty_unit_cost')::numeric),2);end if;
 elsif new.reference_type='sale' then
  if new.empty_quantity_change>0 then
   if empty_cost is null then raise exception 'Record a verified cylinder opening value before receiving bottles';end if;
   select greatest(0,coalesce(sum(amount),0)) into asset_value from public.accounting_lines al where al.tenant_id=new.tenant_id and al.account='bottle_receivable' and entity_id=new.reference_id;
   select greatest(0,(select coalesce(sum(quantity),0) from public.sale_items where tenant_id=new.tenant_id and sale_id=new.reference_id and type='empty_return')-(select coalesce(sum(quantity),0) from public.sale_bottle_receipt_lines where tenant_id=new.tenant_id and sale_id=new.reference_id)+new.empty_quantity_change) into before_qty;
   ec:=case when before_qty>0 then round(asset_value*least(before_qty,new.empty_quantity_change)/before_qty,2) else 0 end;
   gain:=round(greatest(0,new.empty_quantity_change-before_qty)*empty_cost,2);ec:=ec+gain;counter:='bottle_receivable';

  end if;
 elsif new.reference_type='sale_reversal' then
  select -coalesce(sum(e.filled_value),0),-coalesce(sum(e.empty_value),0) into fc,ec from public.inventory_cost_entries e join public.inventory_movements m using(tenant_id,movement_id)
  where e.tenant_id=new.tenant_id and e.item_id=new.item_id and m.reference_id=new.reference_id and m.reference_type='sale';
 else raise exception 'Stock movement requires an accounting source and recorded valuation';end if;
 if fc is null or ec is null then raise exception 'Stock receipt cost is missing';end if;
 update public.inventory_costs set filled_quantity=filled_quantity+new.filled_quantity_change,empty_quantity=empty_quantity+new.empty_quantity_change,
 filled_value=filled_value+fc,empty_value=empty_value+ec,
 empty_unit_cost=case when empty_quantity+new.empty_quantity_change>0 then (empty_value+ec)/(empty_quantity+new.empty_quantity_change) else empty_unit_cost end
 where tenant_id=new.tenant_id and item_id=new.item_id returning * into c;
 insert into public.inventory_cost_entries(tenant_id,item_id,movement_id,occurred_on,filled_change,empty_change,filled_value,empty_value,filled_after,empty_after,reason,estimated,created_by)
 values(new.tenant_id,new.item_id,new.movement_id,d,new.filled_quantity_change,new.empty_quantity_change,fc,ec,c.filled_value,c.empty_value,coalesce(new.notes,'Stock movement'),c.estimated,auth.uid());
 perform app_private.post_journal(new.tenant_id,'inventory',new.movement_id,'cost',d,coalesce(new.notes,'Inventory carrying cost'),jsonb_build_array(
 app_private.accounting_line(account,fc+ec,cat,new.item_id),app_private.accounting_line(counter,-fc-ec+gain,cat,entity),app_private.accounting_line('other_income',-gain,cat)),estimate,counter='opening_equity');
 return new;end $$;
create trigger aa_cost_inventory after insert on public.inventory_movements for each row execute function app_private.cost_inventory_movement();
-- Retire the unvalued adjustment RPC. The new operation records reason and cost
-- atomically, with the same recoverable Finance request registry.
drop function public.create_inventory_movement(uuid,text,integer,integer,text);
drop function app_private.record_inventory_movement(uuid,text,integer,integer,text);
create function public.adjust_inventory(p_payload jsonb,p_request_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_owner('inventory:manage');body jsonb:=jsonb_build_object('action','inventory_adjustment','actor',auth.uid(),'body',p_payload);prior public.finance_requests;
 id uuid:=(p_payload->>'item_id')::uuid;f integer:=(p_payload->>'filled_quantity')::integer;e integer:=coalesce((p_payload->>'empty_quantity')::integer,0);kind text:=p_payload->>'kind';counter text;mid uuid;result jsonb;begin
 if p_request_id is null then raise exception 'Request ID is required';end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from body then raise exception 'Request ID already used with different details';end if;return prior.result;end if;
 if f is null or f=0 and e=0 or abs(f)>1000000 or abs(e)>1000000 or kind is null or kind not in ('opening','capital','gain','lost','stolen','damaged','other_loss')
 or nullif(trim(p_payload->>'reason'),'') is null or length(p_payload->>'reason')>1000 then raise exception 'Enter quantities, adjustment type and a reason';end if;
 if kind in ('opening','capital','gain') and (f<0 or e<0) or kind in ('lost','stolen','damaged','other_loss') and (f>0 or e>0) then raise exception 'Adjustment quantities do not match its type';end if;
 perform 1 from public.items where tenant_id=t and item_id=id for update;if not found then raise exception 'Product not found';end if;
 counter:=case kind when 'opening' then 'opening_equity' when 'capital' then 'capital' when 'gain' then 'other_income' else 'inventory_loss' end;
 if f>0 and (p_payload->>'filled_unit_cost') is null or e>0 and (p_payload->>'empty_unit_cost') is null then raise exception 'Unit costs are required for added inventory';end if;
 insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,filled_quantity_change,empty_quantity_change,notes,created_by,valuation)
 values(t,id,case when f+e>0 then 'adjust_gain' else 'adjust_loss' end,'valued_adjustment',p_request_id,f,e,kind||': '||trim(p_payload->>'reason'),auth.uid(),
 jsonb_build_object('counter_account',counter,'filled_unit_cost',p_payload->'filled_unit_cost','empty_unit_cost',p_payload->'empty_unit_cost')) returning movement_id into mid;
 result:=jsonb_build_object('movement_id',mid);insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,result,auth.uid());return result;end $$;
create or replace function public.get_inventory_valuation() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['inventory:view','inventory:manage','finance:view','finance:manage']);result jsonb;begin
 select jsonb_build_object('known_value',coalesce(sum(c.filled_value+c.empty_value),0),'filled_value',coalesce(sum(c.filled_value),0),'empty_value',coalesce(sum(c.empty_value),0),
 'lpg_value',coalesce(sum(c.filled_value+c.empty_value) filter(where coalesce(to_jsonb(i)->>'business_category','lpg')='lpg'),0),'stove_value',coalesce(sum(c.filled_value+c.empty_value) filter(where to_jsonb(i)->>'business_category'='stove'),0),
 'reconstructed_products',count(*) filter(where c.estimated),'method','moving_weighted_average') into result
 from public.inventory_costs c join public.items i using(tenant_id,item_id) where c.tenant_id=t;return result;end $$;
create function public.get_inventory_cost_history(p_item_id uuid,p_offset integer default 0) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['inventory:view','inventory:manage','finance:view','finance:manage']);r jsonb;begin
 if p_offset is null or p_offset<0 then raise exception 'Invalid page';end if;
 select jsonb_build_object('pool',(select to_jsonb(c) from public.inventory_costs c where tenant_id=t and item_id=p_item_id),
 'total',(select count(*) from public.inventory_cost_entries where tenant_id=t and item_id=p_item_id),
 'entries',coalesce((select jsonb_agg(to_jsonb(e)) from(select * from public.inventory_cost_entries where tenant_id=t and item_id=p_item_id order by created_at desc,entry_id desc offset p_offset limit 10)e),'[]')) into r;return r;end $$;
-- Accrue the same contractual monthly amounts used by Employees, independent of
-- cash payments. Future salary payments are advances until their month starts.
create function app_private.sync_payroll(t uuid,baseline boolean default false) returns void language plpgsql set search_path='' as $$
declare r record;m record;id uuid;amount numeric;lines jsonb;d date:=(now() at time zone 'Asia/Dhaka')::date;begin
 perform pg_advisory_xact_lock(hashtextextended(t::text||':accounting_payroll',0));
 for r in select e.employee_id,min(et.effective_from) starts from public.employees e join public.employee_terms et using(tenant_id,employee_id) where e.tenant_id=t group by e.employee_id order by e.employee_id loop
  for m in select day::date period from generate_series(date_trunc('month',r.starts::timestamp),date_trunc('month',d::timestamp),'1 month') day loop
   id:=md5(r.employee_id::text||m.period::text)::uuid;amount:=(app_private.employee_month_balance(t,r.employee_id,m.period)->>'salary_amount')::numeric;
   lines:=jsonb_build_array(app_private.accounting_line(case when m.period<date_trunc('month',(select started_at from public.accounting_periods where tenant_id=t))::date then 'opening_equity' else 'employee_expense' end,amount),app_private.accounting_line('employee_payable',-amount,'shared',r.employee_id));
   if baseline then insert into app_private.accounting_source_state(tenant_id,source,source_id,lines) values(t,'salary_accrual',id,lines) on conflict do nothing;
   else perform app_private.sync_journal(t,'salary_accrual',id,m.period,'Salary for '||m.period,lines,m.period<date_trunc('month',(select started_at from public.accounting_periods where tenant_id=t))::date);end if;
  end loop;
 end loop;end $$;
do $$ declare r record;begin for r in select tenant_id from public.tenants loop perform app_private.sync_payroll(r.tenant_id,true);end loop;end $$;
create function app_private.account_employee_terms() returns trigger language plpgsql set search_path='' as $$begin perform app_private.sync_payroll(new.tenant_id);return new;end $$;
create trigger accounting_terms after insert on public.employee_terms for each row execute function app_private.account_employee_terms();
-- Do not continue producing conflicting approximate cost evidence.
drop trigger capture_sale_cost on public.sale_items;
drop trigger purchase_buying_prices on public.purchases;
drop trigger commission_buying_prices on public.product_commission_rates;
drop trigger valuation_baseline_created on public.items;
-- Grants are explicit; private helpers remain unexposed.
revoke all on function public.adjust_inventory(jsonb,uuid),public.get_inventory_cost_history(uuid,integer) from public,anon;
grant execute on function public.adjust_inventory(jsonb,uuid),public.get_inventory_cost_history(uuid,integer) to authenticated;
