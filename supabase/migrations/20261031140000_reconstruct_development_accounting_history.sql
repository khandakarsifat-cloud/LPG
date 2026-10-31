-- Correct the development cutover without changing operational transactions.
-- The inspected deployment has only the reconstructed opening journal. Fail
-- closed if later journals appear before deployment, rather than erasing them.
-- All replacement estimates are identified on journals and carrying-cost entries.


create or replace function app_private.post_journal(t uuid,src text,id uuid,event text,d date,note text,entries jsonb,estimate boolean default false,opening_entry boolean default false) returns uuid language plpgsql set search_path='' as $$
declare jid uuid; total numeric;start_day date;begin
 if jsonb_typeof(entries) is distinct from 'array' then raise exception 'Journal lines are required';end if;
 select coalesce(sum((x->>'amount')::numeric),0) into total from jsonb_array_elements(entries) x;
 if total<>0 then raise exception 'Unbalanced accounting journal: %',total;end if;
 select (started_at at time zone 'Asia/Dhaka')::date into start_day from public.accounting_periods where tenant_id=t;
 if start_day is null then raise exception 'Accounting opening position is missing';end if;
 if d is null or not isfinite(d) then raise exception 'A finite accounting date is required';end if;
 if d<start_day then update public.accounting_periods set started_at=d::timestamp at time zone 'Asia/Dhaka' where tenant_id=t and started_at>d::timestamp at time zone 'Asia/Dhaka';end if;
 if not exists(select 1 from jsonb_array_elements(entries) x where (x->>'amount')::numeric<>0) then return null;end if;
 insert into public.accounting_journals(tenant_id,source,source_id,event_key,occurred_on,description,estimated,is_opening,created_by)
 values(t,src,id,event,d,note,estimate,opening_entry,case when src='salary_accrual' then null else auth.uid() end) on conflict(tenant_id,source,source_id,event_key) do nothing returning journal_id into jid;
 if jid is null then raise exception 'Accounting event already posted';end if;
 insert into public.accounting_lines(tenant_id,journal_id,line_no,account,amount,business_category,entity_id,details)
 select t,jid,row_number() over()::integer,x->>'account',(x->>'amount')::numeric,coalesce(x->>'business_category','shared'),(x->>'entity_id')::uuid,coalesce(x->'details','{}'::jsonb)
 from jsonb_array_elements(entries) x where (x->>'amount')::numeric<>0;
 return jid;end $$;

create or replace function app_private.sync_journal(t uuid,src text,id uuid,d date,note text,target jsonb,opening_entry boolean default false) returns void language plpgsql set search_path='' as $$
declare prior app_private.accounting_source_state;delta jsonb;begin
 insert into app_private.accounting_source_state values(t,src,id,'[]',0) on conflict do nothing;
 select * into prior from app_private.accounting_source_state where tenant_id=t and source=src and source_id=id for update;
 with all_lines as(select x,1 sign from jsonb_array_elements(target) x union all select x,-1 from jsonb_array_elements(prior.lines) x),
 grouped as(select x->>'account' account,coalesce(x->>'business_category','shared') category,(x->>'entity_id')::uuid entity,sum(sign*(x->>'amount')::numeric) amount from all_lines group by 1,2,3)
 select coalesce(jsonb_agg(app_private.accounting_line(account,amount,category,entity)) filter(where amount<>0),'[]') into delta from grouped;
 if delta<>'[]' then
 perform app_private.post_journal(t,src,id,(prior.revision+1)::text,d,note,delta,false,opening_entry);
 update app_private.accounting_source_state set lines=target,revision=revision+1 where tenant_id=t and source=src and source_id=id;
 end if;end $$;

create or replace function app_private.source_accounting() returns trigger language plpgsql set search_path='' as $$
declare t uuid:=new.tenant_id;id uuid;src text;d date:=(clock_timestamp() at time zone 'Asia/Dhaka')::date;a numeric;cat text:='shared';lines jsonb:='[]';begin
 if tg_table_name='sales' then
  id:=new.sale_id;src:='sale';if tg_op='INSERT' then d:=(new.created_at at time zone 'Asia/Dhaka')::date;end if;cat:=coalesce(to_jsonb(new)->>'business_category','lpg');a:=case when new.status='completed' then new.total_amount+new.additional_charges else 0 end;
  lines:=jsonb_build_array(app_private.accounting_line('customer_receivable',a,cat,new.customer_id),app_private.accounting_line('sales_revenue',-a,cat));
 elsif tg_table_name='purchases' then
  id:=new.purchase_id;src:='purchase';if tg_op='INSERT' then d:=(coalesce(new.dispatched_at,new.created_at) at time zone 'Asia/Dhaka')::date;end if;cat:=coalesce(to_jsonb(new)->>'business_category','lpg');a:=case when new.status in ('in_transit','received') then new.payable_amount else 0 end;
  lines:=jsonb_build_array(app_private.accounting_line('inventory_transit',a,cat,id),app_private.accounting_line('supplier_payable',-a,cat,id));
 elsif tg_table_name='transits' then
  id:=new.transit_id;src:='transit_revenue';if tg_op='INSERT' then d:=(new.created_at at time zone 'Asia/Dhaka')::date;end if;cat:='logistics';a:=case when new.purchase_id is null and new.status<>'cancelled' then new.transport_fee else 0 end;
  lines:=jsonb_build_array(app_private.accounting_line('transport_receivable',a,cat,id),app_private.accounting_line('logistics_revenue',-a,cat));
 elsif tg_table_name='employee_salary_months' then
  id:=new.salary_month_id;src:='salary';a:=new.salary_amount;
  if new.period>(now() at time zone 'Asia/Dhaka')::date then return new;end if;
  lines:=jsonb_build_array(app_private.accounting_line('employee_expense',a,'shared'),app_private.accounting_line('employee_payable',-a,'shared',new.employee_id));
 elsif tg_table_name='employee_payments' then
  if new.kind<>'bonus' then return new;end if;
  id:=new.payment_id;src:='bonus';a:=case when new.reversal_of is null then new.amount else -new.amount end;d:=new.payment_date;
  lines:=jsonb_build_array(app_private.accounting_line('employee_expense',a),app_private.accounting_line('employee_payable',-a,'shared',new.employee_id));
 elsif tg_table_name='operating_cost_events' then
  id:=new.event_id;src:='operating_cost';d:=new.incurred_on;cat:='logistics';a:=new.amount;
  lines:=jsonb_build_array(app_private.accounting_line(case when new.service_trip_id is null then 'logistics_expense' else 'vehicle_expense' end,a,cat),app_private.accounting_line(case when lower(new.category) in ('driver earnings','helper earnings') then 'employee_payable' else 'operating_payable' end,-a,cat,coalesce(new.transit_id,new.service_trip_id)));
 else return new;end if;
 perform app_private.sync_journal(t,src,id,d,replace(src,'_',' ')||' recognition',lines);return new;end $$;

create or replace function app_private.sync_payroll(t uuid,baseline boolean default false) returns void language plpgsql set search_path='' as $$
declare r record;m record;id uuid;amount numeric;lines jsonb;d date:=(now() at time zone 'Asia/Dhaka')::date;begin
 perform pg_advisory_xact_lock(hashtextextended(t::text||':accounting_payroll',0));
 for r in select e.employee_id,min(et.effective_from) starts from public.employees e join public.employee_terms et using(tenant_id,employee_id) where e.tenant_id=t group by e.employee_id order by e.employee_id loop
  for m in select day::date period from generate_series(date_trunc('month',r.starts::timestamp),date_trunc('month',d::timestamp),'1 month') day loop
   id:=md5(r.employee_id::text||m.period::text)::uuid;amount:=(app_private.employee_month_balance(t,r.employee_id,m.period)->>'salary_amount')::numeric;
   lines:=jsonb_build_array(app_private.accounting_line('employee_expense',amount),app_private.accounting_line('employee_payable',-amount,'shared',r.employee_id));
   if baseline then insert into app_private.accounting_source_state(tenant_id,source,source_id,lines) values(t,'salary_accrual',id,lines) on conflict do nothing;
   else perform app_private.sync_journal(t,'salary_accrual',id,m.period,'Salary for '||m.period,lines,false);end if;
  end loop;
 end loop;end $$;

create or replace function app_private.cost_inventory_movement() returns trigger language plpgsql set search_path='' as $$
declare c public.inventory_costs;p public.purchases;r record;fc numeric:=0;ec numeric:=0;counter text:='cogs';cat text:='lpg';account text:='inventory_lpg';
 asset_value numeric:=0;before_qty integer;gain numeric:=0;entity uuid:=new.reference_id;d date:=(new.created_at at time zone 'Asia/Dhaka')::date;invoice numeric;totalqty numeric;empty_cost numeric;estimate boolean:=false;begin
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
counter:='inventory_transit';
 elsif new.valuation is not null then
  counter:=new.valuation->>'counter_account';
  if counter not in ('opening_equity','inventory_loss','other_income','capital') then raise exception 'Invalid stock adjustment classification';end if;
  if new.filled_quantity_change>0 then fc:=round(new.filled_quantity_change*app_private.purchase_money((new.valuation->>'filled_unit_cost')::numeric),2);end if;
  if new.empty_quantity_change>0 then ec:=round(new.empty_quantity_change*app_private.purchase_money((new.valuation->>'empty_unit_cost')::numeric),2);end if;
 elsif new.reference_type='sale' then
  if new.empty_quantity_change>0 then
   if empty_cost is null then raise exception 'Record a verified cylinder opening value before receiving bottles';end if;
   select greatest(0,coalesce(sum(amount),0)) into asset_value from public.accounting_lines al where al.tenant_id=new.tenant_id and al.account='bottle_receivable' and entity_id=new.reference_id;
   select greatest(0,(select coalesce(sum(quantity),0) from public.sale_items where tenant_id=new.tenant_id and sale_id=new.reference_id and type='empty_return')-(select coalesce(sum(e.empty_change),0) from public.inventory_cost_entries e join public.inventory_movements m using(tenant_id,movement_id) where e.tenant_id=new.tenant_id and m.reference_type='sale' and m.reference_id=new.reference_id and e.empty_change>0)) into before_qty;
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
 values(new.tenant_id,new.item_id,new.movement_id,d,new.filled_quantity_change,new.empty_quantity_change,fc,ec,c.filled_value,c.empty_value,coalesce(new.notes,'Stock movement'),c.estimated,new.created_by);
 perform app_private.post_journal(new.tenant_id,'inventory',new.movement_id,'cost',d,coalesce(new.notes,'Inventory carrying cost'),jsonb_build_array(
 app_private.accounting_line(account,fc+ec,cat,new.item_id),app_private.accounting_line(counter,-fc-ec+gain,cat,entity),app_private.accounting_line('other_income',-gain,cat)),c.estimated,counter='opening_equity');
 return new;end $$;

create or replace function app_private.recognize_bottle_asset() returns trigger language plpgsql set search_path='' as $$declare unit_cost numeric;begin
 if new.type='empty_return' then
  select coalesce(case when c.empty_quantity>0 then c.empty_value/c.empty_quantity end,c.empty_unit_cost) into unit_cost from public.inventory_costs c where c.tenant_id=new.tenant_id and c.item_id=new.item_id;
  if unit_cost is null then raise exception 'Record the cylinder opening value before checkout';end if;
  perform app_private.post_journal(new.tenant_id,'bottle_obligation',new.sale_item_id,'recognize',(select (created_at at time zone 'Asia/Dhaka')::date from public.sales where tenant_id=new.tenant_id and sale_id=new.sale_id),'Returnable bottle asset',jsonb_build_array(
   app_private.accounting_line('bottle_receivable',round(unit_cost*new.quantity,2),'lpg',new.sale_id),app_private.accounting_line('cogs',-round(unit_cost*new.quantity,2),'lpg')));
 end if;return new;end $$;

create or replace function app_private.account_wallet() returns trigger language plpgsql set search_path='' as $$
declare other text;entity uuid:=new.reference_id;cat text:='shared';ep public.employee_payments;begin
 if new.type in ('pos_sale_income','customer_collection','sale_refund') then other:='customer_receivable';
  select customer_id,coalesce(to_jsonb(s)->>'business_category','lpg') into entity,cat from public.sales s where tenant_id=new.tenant_id and sale_id=new.reference_id;
 elsif new.type in ('purchase_transport_funding','purchase_transport_refund','accounting_normalization') then other:='other_assets';cat:='logistics';
 elsif new.type like 'purchase%' then other:='supplier_payable';select coalesce(to_jsonb(p)->>'business_category','lpg') into cat from public.purchases p where tenant_id=new.tenant_id and purchase_id=new.reference_id;
 elsif new.type like 'payroll_%' then
  select p.* into ep from public.employee_payment_entries e join public.employee_payments p using(tenant_id,payment_id) where e.tenant_id=new.tenant_id and e.entry_id=new.employee_entry_id;
  other:='employee_payable';entity:=case when ep.kind='trips' then ep.transit_id else ep.employee_id end;cat:=case when ep.kind='trips' then 'logistics' else 'shared' end;
 elsif new.type like 'transit_client_%' then other:='transport_receivable';cat:='logistics';
 elsif new.type in ('transit_expense','transit_expense_return','vehicle_service_expense','vehicle_service_expense_return') then other:='operating_payable';cat:='logistics';
 elsif new.type='obligation_settlement' then select o.account,o.entity_id into other,entity from public.finance_obligations o where o.tenant_id=new.tenant_id and o.obligation_id=new.reference_id;
 elsif new.type='business_spending' then
  select case when lower(category_name)='interest' then 'interest_expense' else 'operating_expense' end into other from public.spendings where tenant_id=new.tenant_id and spending_id=new.reference_id;
 elsif new.type='owner_withdrawal' then other:='withdrawals';
 elsif new.type='wallet_transfer' then other:='other_assets';entity:=new.operation_id;
 elsif new.type='balance_adjustment' then other:='equity_adjustment';
 elsif new.type='owner_capital' then other:='capital';
 elsif new.type='opening_cash' then other:='opening_equity';
 elsif new.type in ('loan_receipt','loan_repayment') then other:='loan_payable';
 elsif new.type in ('asset_purchase','asset_proceeds','asset_disposal_expense') then other:='other_assets';
 elsif new.type='commission_receipt' then other:='supplier_receivable';
 else raise exception 'Wallet entry has no accounting classification: %',new.type;end if;
 if other is null then raise exception 'Wallet source is missing';end if;
 perform app_private.post_journal(new.tenant_id,'wallet',new.transaction_id,'cash',new.accounting_date,new.description,jsonb_build_array(
 app_private.accounting_line('cash',new.amount,cat,new.wallet_id),app_private.accounting_line(other,-new.amount,cat,entity)),false,new.type='opening_cash');
 return new;end $$;

create or replace function public.accounting_operation(p_payload jsonb,p_request_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
<<accounting_op>>
declare t uuid:=app_private.require_owner('finance:manage');action text:=p_payload->>'action';d date:=(p_payload->>'date')::date;
 body jsonb:=jsonb_build_object('action','accounting_operation','actor',auth.uid(),'body',p_payload);prior public.finance_requests;result jsonb;id uuid;amount numeric;ob public.finance_obligations;
 wallet uuid:=(p_payload->>'wallet_id')::uuid;w public.wallets;loan public.loans;asset public.business_assets;commission public.supplier_commissions;p public.purchases;
 entries jsonb:='[]';note text:=trim(p_payload->>'description');account text;counter text;proceeds numeric;expense numeric;book numeric;category text:=coalesce(p_payload->>'business_category','shared');begin
 if p_request_id is null or d is null or not isfinite(d) or d>(now() at time zone 'Asia/Dhaka')::date or nullif(note,'') is null or length(note)>1000 then raise exception 'Request ID, date and description are required';end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from body then raise exception 'Request ID already used with different details';end if;return prior.result;end if;
 if category not in ('lpg','stove','logistics','shared') then raise exception 'Invalid business category';end if;
 amount:=app_private.purchase_money(coalesce((p_payload->>'amount')::numeric,0));
 if action in ('loan_repay','capital','opening_cash','settle_obligation') or action='loan_create' and not coalesce((p_payload->>'opening')::boolean,false) or action='asset_register' and p_payload->>'funding'='wallet' or action='asset_dispose' then
  select * into w from public.wallets where tenant_id=t and wallet_id=wallet and is_active for update;
  if not found then raise exception 'Choose an active business wallet';end if;
 end if;
 if action='loan_create' then
  if amount<=0 or nullif(trim(p_payload->>'lender'),'') is null then raise exception 'Enter lender and principal';end if;
  insert into public.loans(tenant_id,lender,description,principal,outstanding,received_on,opening,created_by)
  values(t,trim(p_payload->>'lender'),note,amount,amount,d,coalesce((p_payload->>'opening')::boolean,false),auth.uid()) returning loan_id into id;
  if coalesce((p_payload->>'opening')::boolean,false) then entries:=jsonb_build_array(app_private.accounting_line('opening_equity',amount),app_private.accounting_line('loan_payable',-amount,'shared',id));
  else insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,operation_id,description,accounting_date) values(t,wallet,amount,'loan_receipt',id,p_request_id,note,d);end if;
  insert into public.loan_activity(tenant_id,loan_id,action,amount,wallet_id,occurred_on,created_by) values(t,id,case when coalesce((p_payload->>'opening')::boolean,false) then 'opening' else 'receipt' end,amount,case when not coalesce((p_payload->>'opening')::boolean,false) then wallet end,d,auth.uid());
 elsif action='loan_repay' then
  select * into loan from public.loans where tenant_id=t and loan_id=(p_payload->>'loan_id')::uuid for update;
  if not found or amount<=0 or amount>loan.outstanding then raise exception 'Repayment exceeds outstanding principal or loan was not found';end if;if d<loan.received_on or d<(select max(occurred_on) from public.loan_activity where tenant_id=t and loan_id=loan.loan_id) then raise exception 'Repayment date precedes the recorded loan history';end if;id:=loan.loan_id;
  update public.loans set outstanding=outstanding-amount where tenant_id=t and loan_id=id;
  insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,operation_id,description,accounting_date) values(t,wallet,-amount,'loan_repayment',id,p_request_id,note,d);
  insert into public.loan_activity(tenant_id,loan_id,action,amount,wallet_id,occurred_on,created_by) values(t,id,'principal repayment',amount,wallet,d,auth.uid());
 elsif action='expense_accrue' then
  if amount<=0 then raise exception 'Enter a positive obligation amount';end if;id:=p_request_id;
  insert into public.finance_obligations(tenant_id,obligation_id,account,origin,entity_id,description,amount,occurred_on,created_by) values(t,id,'other_liability','incurred',id,note,amount,d,auth.uid());
  entries:=jsonb_build_array(app_private.accounting_line('operating_expense',amount),app_private.accounting_line('other_liability',-amount,'shared',id));
 elsif action='settle_obligation' then
  select * into ob from public.finance_obligations where tenant_id=t and obligation_id=(p_payload->>'obligation_id')::uuid for update;
  if not found or amount<=0 or amount>ob.amount-ob.settled or d<ob.occurred_on then raise exception 'Obligation or settlement amount is invalid';end if;
  id:=ob.obligation_id;update public.finance_obligations set settled=settled+accounting_op.amount where tenant_id=t and obligation_id=id;
  insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,operation_id,description,accounting_date) values(t,wallet,case when ob.account='customer_receivable' then amount else -amount end,'obligation_settlement',id,p_request_id,note,d);
  if ob.account='customer_receivable' then insert into public.customer_transactions(tenant_id,customer_id,type,amount,reference_id,created_by) values(t,ob.entity_id,'payment',amount,id,auth.uid());end if;
 elsif action in ('capital','opening_cash') then
  if amount<=0 then raise exception 'Enter a positive amount';end if;id:=p_request_id;
  insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,operation_id,description,accounting_date) values(t,wallet,amount,case when action='opening_cash' then 'opening_cash' else 'owner_capital' end,id,p_request_id,note,d);

 elsif action='opening_entry' then
  account:=p_payload->>'account';id:=coalesce((p_payload->>'entity_id')::uuid,p_request_id);
  if amount<=0 or account is null or account not in ('customer_receivable','supplier_payable','other_assets','other_liability','operating_payable','employee_payable') then raise exception 'Choose an opening asset / liability and positive value';end if;
  if account='customer_receivable' then
   if not exists(select 1 from public.customers where tenant_id=t and customer_id=id) then raise exception 'Choose an existing business customer';end if;
   insert into public.customer_transactions(tenant_id,customer_id,type,amount,reference_id,created_by) values(t,id,'invoice_charge',-amount,p_request_id,auth.uid());
  end if;
  if account in ('customer_receivable','supplier_payable','other_liability','operating_payable','employee_payable') then
   insert into public.finance_obligations(tenant_id,obligation_id,account,cash_activity,entity_id,description,amount,occurred_on,created_by) values(t,p_request_id,account,case when account='other_liability' then 'unclassified' else 'operating' end,id,note,amount,d,auth.uid());
  end if;
  amount:=case when account in ('supplier_payable','other_liability','operating_payable','employee_payable') then -amount else amount end;
  entries:=jsonb_build_array(app_private.accounting_line(account,amount,category,id),app_private.accounting_line('opening_equity',-amount));
 elsif action='asset_register' then
  account:=p_payload->>'kind';counter:=case p_payload->>'funding' when 'wallet' then 'other_assets' when 'opening' then 'opening_equity' when 'capital' then 'capital' when 'credit' then 'other_liability' end;
  if p_payload->>'amount' is null or amount<0 or account is null or account not in ('vehicles','equipment','other_assets') or counter is null or nullif(trim(p_payload->>'name'),'') is null then raise exception 'Enter an asset name, book value, type and funding';end if;
  if (p_payload->>'vehicle_id')::uuid is not null and (account<>'vehicles' or not exists(select 1 from public.vehicles where tenant_id=t and vehicle_id=(p_payload->>'vehicle_id')::uuid)) then raise exception 'Vehicle not found';end if;
  insert into public.business_assets(tenant_id,vehicle_id,name,kind,cost,acquired_on,valuation_source,created_by) values(t,(p_payload->>'vehicle_id')::uuid,trim(p_payload->>'name'),account,amount,d,'verified',auth.uid()) returning asset_id into id;
  if counter='other_assets' and amount>0 then insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,operation_id,description,accounting_date) values(t,wallet,-amount,'asset_purchase',id,p_request_id,note,d);end if;
  if counter='other_liability' then insert into public.finance_obligations(tenant_id,account,origin,cash_activity,entity_id,description,amount,occurred_on,created_by) values(t,'other_liability','incurred','investing',id,'Asset payable: '||note,amount,d,auth.uid());end if;
  entries:=jsonb_build_array(app_private.accounting_line(account,amount,'shared',id),app_private.accounting_line(counter,-amount,'shared',case when counter in ('other_assets','other_liability') then id end));
  insert into public.asset_activity(tenant_id,asset_id,action,occurred_on,details,created_by) values(t,id,'registered',d,p_payload,auth.uid());
 elsif action in ('asset_depreciate','asset_dispose') then
  select * into asset from public.business_assets where tenant_id=t and asset_id=(p_payload->>'asset_id')::uuid for update;
  if not found or asset.status<>'active' then raise exception 'Active asset not found';end if;if d<asset.acquired_on or d<coalesce((select max(occurred_on) from public.asset_activity where tenant_id=t and asset_id=asset.asset_id),asset.acquired_on) then raise exception 'Asset date precedes its recorded history';end if;id:=asset.asset_id;book:=asset.cost-asset.accumulated_depreciation;
  if action='asset_depreciate' then
   if amount<=0 or amount>book then raise exception 'Depreciation exceeds remaining book value';end if;
   update public.business_assets set accumulated_depreciation=accumulated_depreciation+amount,revision=revision+1 where tenant_id=t and asset_id=id;
   entries:=jsonb_build_array(app_private.accounting_line('depreciation_expense',amount),app_private.accounting_line(asset.kind,-amount,'shared',id));
  else
   proceeds:=app_private.purchase_money(coalesce((p_payload->>'proceeds')::numeric,0));expense:=app_private.purchase_money(coalesce((p_payload->>'expense')::numeric,0));
   if p_payload->>'method' is null or p_payload->>'method' not in ('sold','dismantled') then raise exception 'Choose sell or dismantle';end if;
   if asset.vehicle_id is not null then
    perform 1 from public.vehicles where tenant_id=t and vehicle_id=asset.vehicle_id for update;
    if exists(select 1 from public.transits where tenant_id=t and vehicle_id=asset.vehicle_id and status='active') or exists(select 1 from public.purchases where tenant_id=t and vehicle_id=asset.vehicle_id and status='in_transit') then raise exception 'Return active vehicle assignments before retirement';end if;
    insert into public.vehicle_lifecycle(tenant_id,vehicle_id,previous_status,new_status,reason,created_by) select t,vehicle_id,availability,'retired',note,auth.uid() from public.vehicles where tenant_id=t and vehicle_id=asset.vehicle_id;
    update public.vehicles set availability='retired',revision=revision+1 where tenant_id=t and vehicle_id=asset.vehicle_id;
    update public.vehicle_assignments set ended_at=clock_timestamp(),ended_by=auth.uid() where tenant_id=t and vehicle_id=asset.vehicle_id and ended_at is null;
   end if;
   update public.business_assets set status=p_payload->>'method',revision=revision+1 where tenant_id=t and asset_id=id;
   if proceeds>0 then insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,operation_id,description,accounting_date) values(t,wallet,proceeds,'asset_proceeds',id,p_request_id,note,d);end if;
   if expense>0 then insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,operation_id,description,accounting_date) values(t,wallet,-expense,'asset_disposal_expense',id,p_request_id,note,d);end if;
   entries:=jsonb_build_array(app_private.accounting_line('other_assets',proceeds-expense,'shared',id),app_private.accounting_line(asset.kind,-book,'shared',id),app_private.accounting_line('disposal_gain',book-proceeds+expense));
  end if;
  insert into public.asset_activity(tenant_id,asset_id,action,occurred_on,details,created_by) values(t,id,action,d,p_payload||jsonb_build_object('previous_book_value',book),auth.uid());
 elsif action='commission_earn' then
  if amount<=0 or category not in ('lpg','stove') or nullif(trim(p_payload->>'supplier_name'),'') is null then raise exception 'Enter earned commission, supplier and business category';end if;
  insert into public.supplier_commissions(tenant_id,supplier_name,amount,earned_on,business_category,description,created_by) values(t,trim(p_payload->>'supplier_name'),amount,d,category,note,auth.uid()) returning commission_id into id;
  entries:=jsonb_build_array(app_private.accounting_line('supplier_receivable',amount,category,id),app_private.accounting_line('commission_revenue',-amount,category));
 elsif action='commission_apply' then
  -- Lock purchase before commission, consistent with purchase cancellation.
  select * into p from public.purchases where tenant_id=t and purchase_id=(p_payload->>'purchase_id')::uuid for update;
  if not found or p.status not in ('in_transit','received') then raise exception 'Choose an open purchase';end if;
  select * into commission from public.supplier_commissions where tenant_id=t and commission_id=(p_payload->>'commission_id')::uuid for update;
  if not found or amount<=0 or amount>commission.amount-commission.used or amount>p.payable_amount-p.paid_amount or commission.business_category<>p.business_category or lower(trim(commission.supplier_name))<>lower(trim(coalesce(p.supplier_name,(select b.brand_name from public.lpg_brands b where b.tenant_id=t and b.brand_id=p.brand_id)))) then raise exception 'Commission or purchase balance is insufficient';end if;
  if d<commission.earned_on or d<(coalesce(p.dispatched_at,p.created_at) at time zone 'Asia/Dhaka')::date then raise exception 'Application date precedes the earned commission or purchase';end if;
  id:=commission.commission_id;category:=commission.business_category;
  insert into public.commission_applications(tenant_id,commission_id,purchase_id,amount,created_by) values(t,id,p.purchase_id,amount,auth.uid());
  update public.supplier_commissions set used=used+accounting_op.amount where tenant_id=t and commission_id=id;
  update public.purchases set paid_amount=paid_amount+amount,payment_status=case when paid_amount+amount>=payable_amount then 'paid' else 'partial' end,revision=revision+1 where tenant_id=t and purchase_id=p.purchase_id;
  entries:=jsonb_build_array(app_private.accounting_line('supplier_payable',amount,category,p.purchase_id),app_private.accounting_line('supplier_receivable',-amount,category,id));
 else raise exception 'Unsupported accounting action';end if;
 perform app_private.post_journal(t,'owner_operation',p_request_id,'record',d,note,entries,false,action='opening_entry' or action='loan_create' and coalesce((p_payload->>'opening')::boolean,false) or action='asset_register' and p_payload->>'funding'='opening');
 result:=jsonb_build_object('id',id);insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,result,auth.uid());return result;end $$;

-- Reuse the live recognition/cost functions while replaying source snapshots.
-- These temporary tables have no stock, wallet or business-workflow triggers.
create temporary table sales (like public.sales) on commit drop;
create trigger replay after insert on pg_temp.sales for each row execute function app_private.source_accounting();
create temporary table purchases (like public.purchases) on commit drop;
create trigger replay after insert on pg_temp.purchases for each row execute function app_private.source_accounting();
create temporary table transits (like public.transits) on commit drop;
create trigger replay after insert on pg_temp.transits for each row execute function app_private.source_accounting();
create temporary table employee_payments (like public.employee_payments) on commit drop;
create trigger replay after insert on pg_temp.employee_payments for each row execute function app_private.source_accounting();
create temporary table operating_cost_events (like public.operating_cost_events) on commit drop;
create trigger replay after insert on pg_temp.operating_cost_events for each row execute function app_private.source_accounting();
create temporary table wallet_transactions (like public.wallet_transactions) on commit drop;
create trigger replay after insert on pg_temp.wallet_transactions for each row execute function app_private.account_wallet();
create temporary table inventory_movements (like public.inventory_movements) on commit drop;
create trigger replay after insert on pg_temp.inventory_movements for each row execute function app_private.cost_inventory_movement();
create temporary table sale_items (like public.sale_items) on commit drop;
create trigger replay after insert on pg_temp.sale_items for each row execute function app_private.recognize_bottle_asset();

alter table public.accounting_journals disable trigger accounting_immutable;
alter table public.accounting_lines disable trigger accounting_immutable;
alter table public.inventory_cost_entries disable trigger accounting_immutable;
alter table public.wallet_transactions disable trigger immutable_wallet_entry;

do $$
declare t record;r record;e record;start_day date;cost numeric;shell numeric;f integer;em integer;v numeric;entries jsonb;body jsonb;
begin
 for t in select * from public.accounting_periods where estimated and opening_note like 'Development opening position:%' loop
  if exists(select 1 from public.accounting_journals where tenant_id=t.tenant_id and source<>'opening') then
   raise exception 'Development reconstruction requires review: business % has post-cutover journals',t.tenant_id;
  end if;
  if exists(select 1 from public.sales where tenant_id=t.tenant_id and status<>'completed') or exists(select 1 from public.purchases where tenant_id=t.tenant_id and status='cancelled') then
   raise exception 'Development reconstruction requires explicit cancelled-source history review';
  end if;
  select least((select min((created_at at time zone 'Asia/Dhaka')::date) from public.inventory_movements where tenant_id=t.tenant_id),
   (select min((created_at at time zone 'Asia/Dhaka')::date) from public.sales where tenant_id=t.tenant_id),
   (select min(accounting_date) from public.wallet_transactions where tenant_id=t.tenant_id),
   (select min(date_trunc('month',effective_from)::date) from public.employee_terms where tenant_id=t.tenant_id),
   (t.started_at at time zone 'Asia/Dhaka')::date) into start_day;
  update public.accounting_periods set started_at=start_day::timestamp at time zone 'Asia/Dhaka',
   opening_note='Reconstructed development history. Invoices, movements, payments and contractual salary months retain their recorded dates. Initial stock costs use received invoice evidence; missing shell values use Tk 1,500 and missing filled values use Tk 100/kg plus shell. Vehicle values retain labeled capacity-based test estimates. Initial net assets are estimated owner capital; pre-history retained earnings are zero, not invented profit.'
   where tenant_id=t.tenant_id;

  -- Remove only exact, zero-net virtual-funding/correction pairs. Archive them
  -- using the existing evidence archive, and retain every real payment.
  for r in select wallet_id,reference_id from public.wallet_transactions where tenant_id=t.tenant_id
   and type in ('purchase_transport_funding','purchase_transport_refund','accounting_normalization')
   group by wallet_id,reference_id having sum(amount)=0 and bool_or(type='accounting_normalization')
   and bool_and(purchase_payment_id is null and employee_entry_id is null and operating_payment_id is null) loop
   insert into public.financial_source_archive(tenant_id,source_table,source_id,reference_id,record,reason)
   select tenant_id,'wallet_transactions',transaction_id,reference_id,to_jsonb(x),'Development reconstruction: exact cancelling virtual transport funding pair; no real payment'
   from public.wallet_transactions x where tenant_id=t.tenant_id and wallet_id=r.wallet_id and reference_id=r.reference_id
    and type in ('purchase_transport_funding','purchase_transport_refund','accounting_normalization') on conflict do nothing;
   delete from public.wallet_transactions where tenant_id=t.tenant_id and wallet_id=r.wallet_id and reference_id=r.reference_id
    and type in ('purchase_transport_funding','purchase_transport_refund','accounting_normalization');
  end loop;
  with balances as (select x.transaction_id,w.opening_balance+sum(x.amount) over(partition by x.wallet_id order by x.entry_no) balance
   from public.wallet_transactions x join public.wallets w using(tenant_id,wallet_id) where x.tenant_id=t.tenant_id)
  update public.wallet_transactions x set balance_after=b.balance from balances b where x.tenant_id=t.tenant_id and x.transaction_id=b.transaction_id;

  delete from public.accounting_lines where tenant_id=t.tenant_id;
  delete from public.accounting_journals where tenant_id=t.tenant_id;
  delete from public.inventory_cost_entries where tenant_id=t.tenant_id;
  delete from app_private.accounting_source_state where tenant_id=t.tenant_id;
  update public.inventory_costs set filled_quantity=0,empty_quantity=0,filled_value=0,empty_value=0,estimated=true where tenant_id=t.tenant_id;

  for r in select i.*,i.filled_quantity-coalesce(m.f,0) initial_f,i.empty_quantity-coalesce(m.e,0) initial_e from public.items i
   left join lateral(select sum(filled_quantity_change) f,sum(empty_quantity_change) e from public.inventory_movements where tenant_id=i.tenant_id and item_id=i.item_id)m on true where i.tenant_id=t.tenant_id loop
   if r.initial_f<0 or r.initial_e<0 then raise exception 'Inconsistent historical stock for %',r.item_id;end if;
   select max(unit) filter(where type='package'),max(unit) filter(where type='package')-max(unit) filter(where type='refill') into cost,shell
   from(select distinct on(pi.type) pi.type,pi.unit_price*(case when p.subtotal>0 then (p.company_payable+p.labour_cost)/p.subtotal else 1 end) unit
    from public.purchase_items pi join public.purchases p using(tenant_id,purchase_id)
    where pi.tenant_id=t.tenant_id and pi.item_id=r.item_id and p.status='received' order by pi.type,p.received_at,p.purchase_id) q;
   shell:=round(case when r.business_category='stove' then 0 else greatest(0,coalesce(shell,1500)) end,2);
   cost:=round(coalesce(cost,coalesce(r.size_kg,1)*100+shell),2);
   update public.inventory_costs set empty_unit_cost=shell,filled_quantity=r.initial_f,empty_quantity=r.initial_e,
    filled_value=round(r.initial_f*cost,2),empty_value=round(r.initial_e*shell,2) where tenant_id=t.tenant_id and item_id=r.item_id;
   if r.initial_f<>0 or r.initial_e<>0 then
    v:=round(r.initial_f*cost,2)+round(r.initial_e*shell,2);
    insert into public.inventory_cost_entries(tenant_id,item_id,occurred_on,filled_change,empty_change,filled_value,empty_value,filled_after,empty_after,reason,estimated)
     values(t.tenant_id,r.item_id,start_day,r.initial_f,r.initial_e,round(r.initial_f*cost,2),round(r.initial_e*shell,2),round(r.initial_f*cost,2),round(r.initial_e*shell,2),'Reconstructed development opening: invoice-derived unit costs or documented test estimates',true);
    perform app_private.post_journal(t.tenant_id,'development_opening',r.item_id,'stock',start_day,'Estimated initial stock capital',jsonb_build_array(
     app_private.accounting_line(case when r.business_category='stove' then 'inventory_stove' else 'inventory_lpg' end,v,r.business_category,r.item_id),app_private.accounting_line('opening_equity',-v)),true,true);
   end if;
  end loop;
  for r in select * from public.wallets where tenant_id=t.tenant_id and opening_balance<>0 loop
   perform app_private.post_journal(t.tenant_id,'development_opening',r.wallet_id,'cash',start_day,'Recorded opening wallet balance',jsonb_build_array(
    app_private.accounting_line('cash',r.opening_balance,'shared',r.wallet_id),app_private.accounting_line('opening_equity',-r.opening_balance)),true,true);
  end loop;
  for r in select * from public.business_assets where tenant_id=t.tenant_id loop
   if r.valuation_source<>'estimated_opening' or r.status<>'active' or r.accumulated_depreciation<>0 then raise exception 'Review recorded asset history before development reconstruction';end if;
   update public.business_assets set acquired_on=start_day where tenant_id=t.tenant_id and asset_id=r.asset_id;
   perform app_private.post_journal(t.tenant_id,'development_opening',r.asset_id,'asset',start_day,'Estimated opening vehicle capital: '||r.name,jsonb_build_array(
    app_private.accounting_line(r.kind,r.cost,'shared',r.asset_id),app_private.accounting_line('opening_equity',-r.cost)),true,true);
  end loop;

  -- Sale recognition and expected bottle assets precede their stock movements;
  -- negative stock precedes physical returns within the same checkout timestamp.
  for e in select * from (
   select created_at at_time,10 priority,'sale' kind,to_jsonb(s) body,sale_id id from public.sales s where tenant_id=t.tenant_id
   union all select s.created_at,20,'bottle',to_jsonb(si),si.sale_item_id from public.sale_items si join public.sales s using(tenant_id,sale_id) where si.tenant_id=t.tenant_id and si.type='empty_return'
   union all select coalesce(dispatched_at,created_at),5,'purchase',to_jsonb(p),purchase_id from public.purchases p where tenant_id=t.tenant_id
   union all select created_at,5,'transit',to_jsonb(tr),transit_id from public.transits tr where tenant_id=t.tenant_id
   union all select created_at,case when filled_quantity_change<0 or empty_quantity_change<0 then 30 else 40 end,'inventory',to_jsonb(m),movement_id from public.inventory_movements m where tenant_id=t.tenant_id
   union all select created_at,50,'wallet',to_jsonb(w),transaction_id from public.wallet_transactions w where tenant_id=t.tenant_id
   union all select created_at,5,'bonus',to_jsonb(p),payment_id from public.employee_payments p where tenant_id=t.tenant_id and kind='bonus'
   union all select recorded_at,5,'operating',to_jsonb(o),event_id from public.operating_cost_events o where tenant_id=t.tenant_id
  ) events order by at_time,priority,id loop
   body:=e.body;
   if e.kind='sale' then insert into pg_temp.sales select (jsonb_populate_record(null::public.sales,body)).*;
   elsif e.kind='bottle' then insert into pg_temp.sale_items select (jsonb_populate_record(null::public.sale_items,body)).*;
   elsif e.kind='purchase' then insert into pg_temp.purchases select (jsonb_populate_record(null::public.purchases,body)).*;
   elsif e.kind='transit' then insert into pg_temp.transits select (jsonb_populate_record(null::public.transits,body)).*;
   elsif e.kind='bonus' then insert into pg_temp.employee_payments select (jsonb_populate_record(null::public.employee_payments,body)).*;
   elsif e.kind='operating' then insert into pg_temp.operating_cost_events select (jsonb_populate_record(null::public.operating_cost_events,body)).*;
   elsif e.kind='wallet' then
    if body->>'type'='balance_adjustment' and body->>'description' like 'DEMO %fictional opening funds%' then body:=body||jsonb_build_object('type','owner_capital');end if;
    insert into pg_temp.wallet_transactions select (jsonb_populate_record(null::public.wallet_transactions,body)).*;
   elsif e.kind='inventory' then
    if body->>'reference_type' is null and body->>'movement_type'='adjust_gain' then
     select case when filled_quantity>0 then filled_value/filled_quantity else null end,empty_unit_cost into cost,shell from public.inventory_costs where tenant_id=t.tenant_id and item_id=(body->>'item_id')::uuid;
     if cost is null then
      select coalesce((select pi.unit_price*(case when p.subtotal>0 then (p.company_payable+p.labour_cost)/p.subtotal else 1 end) from public.purchase_items pi join public.purchases p using(tenant_id,purchase_id) where pi.tenant_id=i.tenant_id and pi.item_id=i.item_id and pi.type='package' and p.status='received' order by p.received_at,p.purchase_id limit 1),coalesce(i.size_kg,1)*100+coalesce(shell,0)) into cost from public.items i where i.tenant_id=t.tenant_id and i.item_id=(body->>'item_id')::uuid;
     end if;
     body:=body||jsonb_build_object('valuation',jsonb_build_object('counter_account','opening_equity','filled_unit_cost',round(cost,2),'empty_unit_cost',round(shell,2)),'notes','Reconstructed development opening stock: received invoice basis or documented test estimate');
    end if;
    insert into pg_temp.inventory_movements select (jsonb_populate_record(null::public.inventory_movements,body)).*;
   end if;
  end loop;
  perform app_private.sync_payroll(t.tenant_id);

  -- These are reconciliation assertions, never plugs to income or inventory.
  if exists(select 1 from public.wallets w where tenant_id=t.tenant_id and balance<>coalesce((select sum(amount) from public.accounting_lines l where l.tenant_id=w.tenant_id and l.account='cash' and l.entity_id=w.wallet_id),0)) then raise exception 'Reconstructed wallets do not reconcile';end if;
  if exists(select 1 from public.inventory_costs c join public.items i using(tenant_id,item_id) where c.tenant_id=t.tenant_id and (c.filled_quantity<>i.filled_quantity or c.empty_quantity<>i.empty_quantity or c.filled_value+c.empty_value<>coalesce((select sum(amount) from public.accounting_lines l where l.tenant_id=c.tenant_id and l.entity_id=c.item_id and l.account in ('inventory_lpg','inventory_stove')),0))) then raise exception 'Reconstructed stock does not reconcile';end if;
  if exists(select 1 from public.customers c where tenant_id=t.tenant_id and -coalesce((select sum(amount) from public.customer_transactions x where x.tenant_id=c.tenant_id and x.customer_id=c.customer_id),0)<>coalesce((select sum(amount) from public.accounting_lines l where l.tenant_id=c.tenant_id and l.entity_id=c.customer_id and l.account='customer_receivable'),0)) then raise exception 'Reconstructed customer balances do not reconcile';end if;
  if exists(select 1 from public.purchases p where tenant_id=t.tenant_id and status in ('received','in_transit') and payable_amount-paid_amount<>coalesce((select -sum(amount) from public.accounting_lines l where l.tenant_id=p.tenant_id and l.entity_id=p.purchase_id and l.account='supplier_payable'),0)) then raise exception 'Reconstructed supplier balances do not reconcile';end if;
 end loop;
end $$;

set constraints all immediate;
alter table public.accounting_journals enable trigger accounting_immutable;
alter table public.accounting_lines enable trigger accounting_immutable;
alter table public.inventory_cost_entries enable trigger accounting_immutable;
alter table public.wallet_transactions enable trigger immutable_wallet_entry;

-- Missing evidence is still an integrity error; an obsolete cutover date is not.
do $$declare s text;begin
 s:=pg_get_functiondef('public.reverse_sale(uuid,text,text,uuid)'::regprocedure);
 execute replace(s,'Pre-opening sale has no recorded carrying costs; it cannot be reversed automatically','Sale has no recorded carrying costs; reconcile its stock evidence before cancellation');
end $$;
