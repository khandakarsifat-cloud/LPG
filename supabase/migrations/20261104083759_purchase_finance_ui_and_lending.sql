-- One loan register supports borrowing and lending with distinct principal accounts.
alter table public.loans add column direction text not null default 'borrowed' check (direction in ('borrowed','lent'));
insert into public.accounting_accounts(code,name,kind) values ('loan_receivable','Money lent','asset');
insert into public.financial_types(code,name,origin) values ('loan_lend','Money lent','system'),('loan_collect','Lending repayment received','system');
CREATE OR REPLACE FUNCTION public.accounting_operation(p_payload jsonb, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
<<accounting_op>>
declare t uuid:=app_private.require_owner('finance:manage');action text:=p_payload->>'action';d date:=(p_payload->>'date')::date;
 body jsonb:=jsonb_build_object('action','accounting_operation','actor',auth.uid(),'body',p_payload);prior public.finance_requests;result jsonb;id uuid;amount numeric;ob public.finance_obligations;
 wallet uuid:=(p_payload->>'wallet_id')::uuid;w public.wallets;loan public.loans;asset public.business_assets;p public.purchases;
 alloc jsonb:=coalesce(p_payload->'allocations',case when p_payload->>'business_category' in ('lpg','stove','logistics') then jsonb_build_object(p_payload->>'business_category',100) else '{"lpg":100}'::jsonb end); op_type uuid; entries jsonb:='[]';note text:=trim(p_payload->>'description');account text;counter text;proceeds numeric;expense numeric;book numeric;category text:=coalesce(p_payload->>'business_category','shared');begin perform app_private.require_permission('finance:owner');
 if p_request_id is null or d is null or not isfinite(d) or d>(now() at time zone 'Asia/Dhaka')::date or nullif(note,'') is null or length(note)>1000 then raise exception 'Request ID, date and description are required';end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from body then raise exception 'Request ID already used with different details';end if;return prior.result;end if;
 if category not in ('lpg','stove','logistics','shared') then raise exception 'Invalid business category';end if;
 if action='asset_register' and (p_payload->>'kind'='vehicles' or p_payload->>'vehicle_id' is not null) then alloc:='{"logistics":100}';end if; if not coalesce(app_private.valid_business_allocation(alloc),false) then raise exception 'Business percentages must total 100';end if;op_type:=app_private.system_type(action); amount:=app_private.purchase_money(coalesce((p_payload->>'amount')::numeric,0));
 if action in ('loan_repay','loan_collect','loan_lend','capital','settle_obligation') or action='loan_create' and not coalesce((p_payload->>'opening')::boolean,false) or action='asset_register' and p_payload->>'funding'='wallet' or action='asset_dispose' or action='asset_improve' and p_payload->>'funding'='wallet' then
  select * into w from public.wallets where tenant_id=t and wallet_id=wallet and is_active;
  if not found then raise exception 'Choose an active business wallet';end if;
 end if;
 if action in ('loan_create','loan_lend') then
  if amount<=0 or nullif(trim(p_payload->>'lender'),'') is null then raise exception 'Enter lender and principal';end if;
  if action='loan_lend' and coalesce((p_payload->>'opening')::boolean,false) then raise exception 'Lending requires an actual wallet payment';end if;
  insert into public.loans(tenant_id,lender,description,principal,outstanding,received_on,opening,created_by,allocations,direction)
  values(t,trim(p_payload->>'lender'),note,amount,amount,d,coalesce((p_payload->>'opening')::boolean,false),auth.uid(),alloc,case when action='loan_lend' then 'lent' else 'borrowed' end) returning loan_id into id;
  if coalesce((p_payload->>'opening')::boolean,false) then entries:=jsonb_build_array(app_private.accounting_line('opening_equity',amount),app_private.accounting_line('loan_payable',-amount,'shared',id));
  else insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,operation_id,description,accounting_date,allocations) values(t,wallet,case when action='loan_lend' then -amount else amount end,case when action='loan_lend' then 'loan_lend' else 'loan_receipt' end,id,p_request_id,note,d,alloc);end if;
  insert into public.loan_activity(tenant_id,loan_id,action,amount,wallet_id,occurred_on,created_by) values(t,id,case when coalesce((p_payload->>'opening')::boolean,false) then 'opening' when action='loan_lend' then 'money lent' else 'receipt' end,amount,case when not coalesce((p_payload->>'opening')::boolean,false) then wallet end,d,auth.uid());
 elsif action in ('loan_repay','loan_collect') then
  select * into loan from public.loans where tenant_id=t and loan_id=(p_payload->>'loan_id')::uuid for update;
  if not found or loan.direction<>(case when action='loan_collect' then 'lent' else 'borrowed' end) or amount<=0 or amount>loan.outstanding then raise exception 'Repayment exceeds outstanding principal or loan was not found';end if;if d<loan.received_on or d<(select max(occurred_on) from public.loan_activity where tenant_id=t and loan_id=loan.loan_id) then raise exception 'Repayment date precedes the recorded loan history';end if;id:=loan.loan_id;alloc:=loan.allocations;
  update public.loans set outstanding=outstanding-amount where tenant_id=t and loan_id=id;
  insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,operation_id,description,accounting_date,allocations) values(t,wallet,case when action='loan_collect' then amount else -amount end,case when action='loan_collect' then 'loan_collect' else 'loan_repayment' end,id,p_request_id,note,d,alloc);
  insert into public.loan_activity(tenant_id,loan_id,action,amount,wallet_id,occurred_on,created_by) values(t,id,case when action='loan_collect' then 'repayment received' else 'principal repayment' end,amount,wallet,d,auth.uid());
 elsif action='expense_accrue' then
  if amount<=0 then raise exception 'Enter a positive obligation amount';end if;id:=p_request_id;
  insert into public.finance_obligations(tenant_id,obligation_id,account,origin,entity_id,description,amount,occurred_on,created_by) values(t,id,'other_liability','incurred',id,note,amount,d,auth.uid());
  entries:=jsonb_build_array(app_private.accounting_line('operating_expense',amount),app_private.accounting_line('other_liability',-amount,'shared',id));
 elsif action='settle_obligation' then
  select * into ob from public.finance_obligations where tenant_id=t and obligation_id=(p_payload->>'obligation_id')::uuid for update;
  if not found or amount<=0 or amount>ob.amount-ob.settled or d<ob.occurred_on then raise exception 'Obligation or settlement amount is invalid';end if;
  id:=ob.obligation_id;alloc:=ob.allocations;update public.finance_obligations set settled=settled+accounting_op.amount where tenant_id=t and obligation_id=id;
  insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,operation_id,description,accounting_date,allocations) values(t,wallet,case when ob.account='customer_receivable' then amount else -amount end,'obligation_settlement',id,p_request_id,note,d,alloc);
  if ob.account='customer_receivable' then insert into public.customer_transactions(tenant_id,customer_id,type,amount,reference_id,created_by) values(t,ob.entity_id,'payment',amount,id,auth.uid());end if;
 elsif action in ('capital') then
  if amount<=0 then raise exception 'Enter a positive amount';end if;id:=p_request_id;
  insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,operation_id,description,accounting_date,allocations) values(t,wallet,amount,'owner_capital',id,p_request_id,note,d,alloc);

 elsif action='opening_entry' then
  account:=p_payload->>'account';id:=coalesce((p_payload->>'entity_id')::uuid,p_request_id);
  if amount<=0 or account is null or account not in ('customer_receivable','supplier_payable','other_assets','other_liability','operating_payable','employee_payable','retained_earnings') then raise exception 'Choose an opening asset / liability and positive value';end if;
  if account='customer_receivable' then
   if not exists(select 1 from public.customers where tenant_id=t and customer_id=id) then raise exception 'Choose an existing business customer';end if;
   insert into public.customer_transactions(tenant_id,customer_id,type,amount,reference_id,created_by) values(t,id,'invoice_charge',-amount,p_request_id,auth.uid());
  end if;
  if account in ('customer_receivable','supplier_payable','other_liability','operating_payable','employee_payable') then
   insert into public.finance_obligations(tenant_id,obligation_id,account,cash_activity,entity_id,description,amount,occurred_on,created_by) values(t,p_request_id,account,case when account='other_liability' then 'unclassified' else 'operating' end,id,note,amount,d,auth.uid());
  end if;
  amount:=case when account in ('supplier_payable','other_liability','operating_payable','employee_payable','retained_earnings') then -amount else amount end;
  entries:=jsonb_build_array(app_private.accounting_line(account,amount,category,id),app_private.accounting_line('opening_equity',-amount));
 elsif action='asset_register' then
  account:=p_payload->>'kind';counter:=case p_payload->>'funding' when 'wallet' then 'other_assets' when 'opening' then 'opening_equity' when 'capital' then 'capital' when 'credit' then 'other_liability' end;
  if p_payload->>'amount' is null or amount<0 or account is null or account not in ('vehicles','equipment','other_assets') or counter is null or nullif(trim(p_payload->>'name'),'') is null then raise exception 'Enter an asset name, book value, type and funding';end if;
  if (p_payload->>'vehicle_id')::uuid is not null and (account<>'vehicles' or not exists(select 1 from public.vehicles where tenant_id=t and vehicle_id=(p_payload->>'vehicle_id')::uuid)) then raise exception 'Vehicle not found';end if;
  insert into public.business_assets(tenant_id,vehicle_id,name,kind,cost,acquired_on,valuation_source,created_by,allocations) values(t,(p_payload->>'vehicle_id')::uuid,trim(p_payload->>'name'),account,amount,d,'verified',auth.uid(),alloc) returning asset_id into id;
  if counter='other_assets' and amount>0 then insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,operation_id,description,accounting_date,allocations) values(t,wallet,-amount,'asset_purchase',id,p_request_id,note,d,alloc);end if;
  if counter='other_liability' then insert into public.finance_obligations(tenant_id,account,origin,cash_activity,entity_id,description,amount,occurred_on,created_by) values(t,'other_liability','incurred','investing',id,'Asset payable: '||note,amount,d,auth.uid());end if;
  entries:=jsonb_build_array(app_private.accounting_line(account,amount,'shared',id),app_private.accounting_line(counter,-amount,'shared',case when counter in ('other_assets','other_liability') then id end));
  insert into public.asset_activity(tenant_id,asset_id,action,occurred_on,details,created_by) values(t,id,'registered',d,p_payload,auth.uid());
 elsif action='asset_improve' then
 select * into asset from public.business_assets where tenant_id=t and asset_id=(p_payload->>'asset_id')::uuid for update;
 if not found or asset.status<>'active' or amount<=0 or d<coalesce((select max(occurred_on) from public.asset_activity where tenant_id=t and asset_id=asset.asset_id),asset.acquired_on) or coalesce(p_payload->>'funding','') not in ('wallet','credit','capital') then raise exception 'Choose an active asset, valid improvement cost and funding';end if;
 id:=asset.asset_id;alloc:=asset.allocations;counter:=case p_payload->>'funding' when 'wallet' then 'other_assets' when 'credit' then 'other_liability' else 'capital' end;
 update public.business_assets set cost=cost+amount,revision=revision+1 where tenant_id=t and asset_id=id;
 if counter='other_assets' then insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,operation_id,description,accounting_date,allocations) values(t,wallet,-amount,'asset_purchase',id,p_request_id,note,d,alloc);end if;
 if counter='other_liability' then insert into public.finance_obligations(tenant_id,obligation_id,account,origin,cash_activity,entity_id,description,amount,occurred_on,created_by,allocations) values(t,p_request_id,'other_liability','incurred','investing',id,note,amount,d,auth.uid(),alloc);end if;
 entries:=jsonb_build_array(app_private.accounting_line(asset.kind,amount,'shared',id),app_private.accounting_line(counter,-amount,'shared',case when counter in ('other_assets','other_liability') then id end));
 insert into public.asset_activity(tenant_id,asset_id,action,occurred_on,details,created_by) values(t,id,action,d,p_payload||jsonb_build_object('amount',amount,'allocations',alloc),auth.uid());
 elsif action in ('asset_depreciate','asset_dispose') then
  select * into asset from public.business_assets where tenant_id=t and asset_id=(p_payload->>'asset_id')::uuid for update;
  if not found or asset.status<>'active' then raise exception 'Active asset not found';end if;if d<asset.acquired_on or d<coalesce((select max(occurred_on) from public.asset_activity where tenant_id=t and asset_id=asset.asset_id),asset.acquired_on) then raise exception 'Asset date precedes its recorded history';end if;id:=asset.asset_id;alloc:=asset.allocations;book:=asset.cost-asset.accumulated_depreciation;
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
   if proceeds>0 then insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,operation_id,description,accounting_date,allocations) values(t,wallet,proceeds,'asset_proceeds',id,p_request_id,note,d,alloc);end if;
   if expense>0 then insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,operation_id,description,accounting_date,allocations) values(t,wallet,-expense,'asset_disposal_expense',id,p_request_id,note,d,alloc);end if;
   entries:=jsonb_build_array(app_private.accounting_line('other_assets',proceeds-expense,'shared',id),app_private.accounting_line(asset.kind,-book,'shared',id),app_private.accounting_line('disposal_gain',book-proceeds+expense));
  end if;
  insert into public.asset_activity(tenant_id,asset_id,action,occurred_on,details,created_by) values(t,id,action,d,p_payload||jsonb_build_object('previous_book_value',book),auth.uid());
 else raise exception 'Unsupported accounting action';end if;
 update public.finance_obligations set allocations=alloc where tenant_id=t and (obligation_id=id or entity_id=id); select coalesce(jsonb_agg(x||jsonb_build_object('allocations',alloc,'type_id',op_type,'business_category','shared')),'[]') into entries from jsonb_array_elements(entries)x; perform app_private.post_journal(t,'owner_operation',p_request_id,'record',d,note,entries,false,action='opening_entry' or action='loan_create' and coalesce((p_payload->>'opening')::boolean,false) or action='asset_register' and p_payload->>'funding'='opening');
 result:=jsonb_build_object('id',id);insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,result,auth.uid());return result;end $function$;
CREATE OR REPLACE FUNCTION app_private.account_wallet()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$declare
 other text;entity uuid:=new.reference_id;ep public.employee_payments;e public.financial_entries;entries jsonb;begin
 if new.type='wallet_transfer' then return new;end if;
 if new.type='custom_entry' then select * into e from public.financial_entries where tenant_id=new.tenant_id and entry_id=new.reference_id;
  other:=e.account;entity:=coalesce(e.asset_id,e.entry_id);
 elsif new.type in ('pos_sale_income','customer_collection','sale_refund') then other:='customer_receivable';select customer_id into entity from public.sales where tenant_id=new.tenant_id and sale_id=new.reference_id;
 elsif new.type like 'purchase%' then other:='supplier_payable';
 elsif new.type like 'payroll_%' then
  select p.* into ep from public.employee_payment_entries x join public.employee_payments p using(tenant_id,payment_id) where x.tenant_id=new.tenant_id and x.entry_id=new.employee_entry_id;
  other:='employee_payable';entity:=case when ep.kind='trips' then ep.transit_id else ep.employee_id end;
 elsif new.type like 'transit_client_%' then other:='transport_receivable';
 elsif new.type in ('transit_expense','transit_expense_return','vehicle_service_expense','vehicle_service_expense_return') then other:='operating_payable';
 elsif new.type='obligation_settlement' then select o.account,o.entity_id into other,entity from public.finance_obligations o where o.tenant_id=new.tenant_id and o.obligation_id=new.reference_id;
 elsif new.type='owner_withdrawal' then other:='withdrawals';
 elsif new.type='balance_adjustment' then other:='equity_adjustment';
 elsif new.type='owner_capital' then other:='capital';
 elsif new.type='opening_cash' then other:='opening_equity';
 elsif new.type in ('loan_lend','loan_collect') then other:='loan_receivable';
 elsif new.type in ('loan_receipt','loan_repayment') then other:='loan_payable';
 elsif new.type in ('asset_purchase','asset_proceeds','asset_disposal_expense') then other:='other_assets';
 else raise exception 'Wallet entry has no accounting classification: %',new.type;end if;
 if other is null then raise exception 'Wallet source is missing';end if;
 select jsonb_agg(line) into entries from jsonb_each_text(new.business_amounts)b cross join lateral(values
  (app_private.accounting_line('cash',b.value::numeric,b.key,new.wallet_id)||jsonb_build_object('type_id',new.type_id)),
  (app_private.accounting_line(other,-b.value::numeric,b.key,entity,jsonb_build_object('type_name',e.type_name))||jsonb_build_object('type_id',new.type_id)))v(line);
 perform app_private.post_journal(new.tenant_id,'wallet',new.transaction_id,'cash',new.accounting_date,new.description,entries,false,new.type='opening_cash');return new;
end $function$;
CREATE OR REPLACE FUNCTION app_private.wallet_dimensions()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$declare cat text;a jsonb;p public.employee_payments;begin
 if new.type_id is null then new.type_id:=app_private.system_type(new.type);end if;
 if new.type='wallet_transfer' then
  if new.type_id is null or new.allocations is not null or new.business_amounts is not null then raise exception 'Treasury transfers have no business allocation';end if;return new;
 end if;
 if new.allocations is null then
  if new.type in ('pos_sale_income','customer_collection','sale_refund') then select jsonb_build_object(business_category,100) into a from public.sales where tenant_id=new.tenant_id and sale_id=new.reference_id;
  elsif new.type like 'purchase%' then select jsonb_build_object(business_category,100) into a from public.purchases where tenant_id=new.tenant_id and purchase_id=new.reference_id;
  elsif new.type like 'payroll_%' then
   select ep.* into p from public.employee_payment_entries e join public.employee_payments ep using(tenant_id,payment_id) where e.tenant_id=new.tenant_id and e.entry_id=new.employee_entry_id;
   if p.kind='trips' then a:='{"logistics":100}';else a:=p.allocations;end if;
  elsif new.type like 'transit_%' or new.type like 'vehicle_service_%' then a:='{"logistics":100}';
  elsif new.type in ('loan_receipt','loan_repayment','loan_lend','loan_collect') then select allocations into a from public.loans where tenant_id=new.tenant_id and loan_id=new.reference_id;
  elsif new.type like 'asset_%' then select allocations into a from public.business_assets where tenant_id=new.tenant_id and asset_id=new.reference_id;
  elsif new.type='obligation_settlement' then select allocations into a from public.finance_obligations where tenant_id=new.tenant_id and obligation_id=new.reference_id;
  end if;
  new.allocations:=coalesce(a,'{"lpg":100}'::jsonb);
 end if;
 if new.type_id is null or not coalesce(app_private.valid_business_allocation(new.allocations),false) then raise exception 'Wallet type and business allocation are required';end if;
 if new.business_amounts is null then new.business_amounts:=(select jsonb_object_agg(business,amount) from app_private.allocate_money(new.amount,new.allocations));end if; if not coalesce(app_private.valid_business_amounts(new.amount,new.business_amounts),false) then raise exception 'Business amounts must equal the wallet movement';end if;return new;end $function$;
CREATE OR REPLACE FUNCTION app_private.analysis_entity(t uuid, code text, id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare label text;k text;ref uuid:=id;begin
 if id is null and code='cash' then label:='Pooled business cash';
 elsif id is null then select a.name into label from public.accounting_accounts a where a.code=analysis_entity.code;
 elsif code='cash' then select name,'wallet' into label,k from public.wallets where tenant_id=t and wallet_id=id;
 elsif code in ('inventory_lpg','inventory_stove') then
  select coalesce(i.product_name,concat_ws(' ',b.brand_name,i.size_kg||' kg',i.mouth_size)),'product' into label,k from public.items i left join public.lpg_brands b using(tenant_id,brand_id) where i.tenant_id=t and i.item_id=id;
 elsif code='customer_receivable' then select coalesce(nullif(shop_name,''),name),'customer' into label,k from public.customers where tenant_id=t and customer_id=id;
 elsif code in ('loan_payable','loan_receivable') then select lender,'loan' into label,k from public.loans where tenant_id=t and loan_id=id;
 elsif code in ('vehicles','equipment','other_assets') then select name,'asset' into label,k from public.business_assets where tenant_id=t and asset_id=id;
 elsif code in ('supplier_payable','inventory_transit') then select coalesce(supplier_name,'Supplier')||' · Purchase #'||left(id::text,8),'purchase' into label,k from public.purchases where tenant_id=t and purchase_id=id;
 elsif code='other_income' and exists(select 1 from public.purchases where tenant_id=t and purchase_id=id) then select coalesce(supplier_name,'Company')||' · Purchase #'||left(id::text,8),'purchase' into label,k from public.purchases where tenant_id=t and purchase_id=id;
 elsif code='bottle_receivable' then select 'Cylinders · Sale #'||left(id::text,8),'sale' into label,k from public.sales where tenant_id=t and sale_id=id;
 elsif code='supplier_receivable' and exists(select 1 from app_private.purchase_rebate_accounts where tenant_id=t and account_id=id) then select company_name||' · Company rebate credit' into label from app_private.purchase_rebate_accounts where tenant_id=t and account_id=id;
 elsif code='supplier_receivable' then select brand_name||' · Supplier advance/refund' into label from public.lpg_brands where tenant_id=t and brand_id=id; 
 elsif code='employee_payable' then select name,'employee' into label,k from public.employees where tenant_id=t and employee_id=id;
 end if;
 if label is null then select description,'obligation' into label,k from public.finance_obligations where tenant_id=t and obligation_id=id;end if;
 if label is null then select 'Journey · '||destination||' #'||left(id::text,8),'transit' into label,k from public.transits where tenant_id=t and transit_id=id;end if;
 if label is null then select a.name into label from public.accounting_accounts a where a.code=analysis_entity.code;end if;
 return jsonb_build_object('entity_name',label,'record_kind',k,'record_id',ref);end $function$;
CREATE OR REPLACE FUNCTION app_private.analysis_group(code text, kind text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$select
 case when kind='asset' then case when code='cash' then 'cash' when code in ('inventory_lpg','inventory_stove','inventory_transit','bottle_receivable') then 'inventory' when code in ('vehicles','equipment','other_assets') then 'fixed_assets' when code in ('customer_receivable','supplier_receivable','transport_receivable','loan_receivable') then 'receivables' else 'other_assets' end
 when kind='liability' then case when code in ('loan_payable','supplier_payable') then 'dues' when code='employee_payable' then 'employees' else 'other_liabilities' end
 when kind='income' then 'revenue' when kind='expense' then 'expenses' when code in ('capital','opening_equity') then 'capital' when code='withdrawals' then 'withdrawals' else 'other_equity' end;$function$;
CREATE OR REPLACE FUNCTION app_private.reconcile_record(t uuid, k text, id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare observed jsonb;expected jsonb;safe boolean:=false;note text:='Canonical source comparison';v numeric;v2 numeric;salary_period record;d date;pos jsonb;hash text;begin
 if k='customer' then
  if not exists(select 1 from public.customers where tenant_id=t and customer_id=id) then return false;end if;
  insert into app_private.customer_metrics(tenant_id,customer_id) values(t,id) on conflict do nothing;
  perform 1 from app_private.customer_metrics where tenant_id=t and customer_id=id for update nowait;
  select to_jsonb(c)-'tenant_id'-'customer_id' into observed from app_private.customer_metrics c where tenant_id=t and customer_id=id;
  select jsonb_build_object('ledger_balance',coalesce((select sum(amount) from public.customer_transactions where tenant_id=t and customer_id=id),0),
   'transactions',count(*),'refill',coalesce(sum(q.refill),0),'package',coalesce(sum(q.package),0),
   'total_sold_amount',coalesce(sum(s.total_amount+s.additional_charges),0),'total_due',coalesce(sum(greatest(0,s.total_amount+s.additional_charges-s.paid_amount)),0),'last_transaction_at',max(s.created_at)) into expected
  from public.sales s left join lateral(select coalesce(sum(quantity) filter(where type='refill'),0) refill,coalesce(sum(quantity) filter(where type='package'),0) package from public.sale_items i where i.tenant_id=t and i.sale_id=s.sale_id)q on true
  where s.tenant_id=t and s.customer_id=id and s.status='completed';
  if observed is distinct from expected then
   update app_private.customer_metrics set ledger_balance=(expected->>'ledger_balance')::numeric,transactions=(expected->>'transactions')::bigint,refill=(expected->>'refill')::bigint,package=(expected->>'package')::bigint,total_sold_amount=(expected->>'total_sold_amount')::numeric,total_due=(expected->>'total_due')::numeric,last_transaction_at=(expected->>'last_transaction_at')::timestamptz where tenant_id=t and customer_id=id;
   safe:=found;end if;
 elsif k='wallet' then
  perform 1 from public.wallets where tenant_id=t and wallet_id=id for update nowait;
  if not found then return false;end if;
  select balance,opening_balance+coalesce((select sum(amount) from public.wallet_transactions where tenant_id=t and wallet_id=id),0) into v,v2 from public.wallets where tenant_id=t and wallet_id=id;
  observed:=jsonb_build_object('balance',v,'combined_cash',(select coalesce(sum(balance),0) from public.wallets where tenant_id=t));
  expected:=jsonb_build_object('balance',v2,'combined_cash',(select coalesce(sum(amount),0) from public.accounting_lines where tenant_id=t and account='cash'));
  -- A wallet is reconciled to its own ledger; only the pooled total is compared
  -- with journal Cash. Treasury transfers deliberately have no business journal.
  if v<>v2 and (select coalesce(sum(opening_balance),0)+coalesce((select sum(amount) from public.wallet_transactions where tenant_id=t),0) from public.wallets where tenant_id=t)=(expected->>'combined_cash')::numeric then
   update public.wallets set balance=v2 where tenant_id=t and wallet_id=id;safe:=true;
  end if;
 elsif k='inventory' then
  -- Never repair physical stock from a financial discrepancy. Cost evidence and
  -- movement coverage must agree before an operator can investigate a count.
  perform 1 from public.items where tenant_id=t and item_id=id for update nowait;
  if not found then return false;end if;
  perform 1 from public.inventory_costs where tenant_id=t and item_id=id for update nowait;
  select jsonb_build_object('filled',i.filled_quantity,'empty',i.empty_quantity,'pool_filled',c.filled_quantity,'pool_empty',c.empty_quantity,'filled_value',c.filled_value,'empty_value',c.empty_value,'journal_value',c.filled_value+c.empty_value,'missing_movements',0) into observed from public.items i join public.inventory_costs c using(tenant_id,item_id) where i.tenant_id=t and i.item_id=id;
  select jsonb_build_object('filled',coalesce(sum(filled_change),0),'empty',coalesce(sum(empty_change),0),'pool_filled',coalesce(sum(filled_change),0),'pool_empty',coalesce(sum(empty_change),0),'filled_value',coalesce(sum(filled_value),0),'empty_value',coalesce(sum(empty_value),0),
   'journal_value',coalesce((select sum(consolidated_amount) from public.accounting_lines where tenant_id=t and entity_id=id and account in ('inventory_lpg','inventory_stove')),0),
   'missing_movements',(select count(*) from public.inventory_movements m where m.tenant_id=t and m.item_id=id and not exists(select 1 from public.inventory_cost_entries e where e.tenant_id=t and e.movement_id=m.movement_id))) into expected from public.inventory_cost_entries where tenant_id=t and item_id=id;
 observed:=observed||jsonb_build_object('fifo_consistent',
  not exists(select 1 from app_private.fifo_layers l left join lateral(select coalesce(sum(x.quantity),0) q,coalesce(sum(x.value),0) v,coalesce(sum(x.shell_value),0) s from app_private.fifo_consumptions x where x.tenant_id=t and x.layer_id=l.layer_id)x on true where l.tenant_id=t and l.item_id=id and (l.quantity<>l.remaining+x.q or l.value<>l.remaining_value+x.v or l.shell_value<>l.remaining_shell_value+x.s))
  and coalesce((select c.filled_quantity=x.f and c.empty_quantity=x.e and c.filled_value=x.fv and c.empty_value=x.ev from public.inventory_costs c cross join lateral(select coalesce(sum(remaining) filter(where component='filled'),0) f,coalesce(sum(remaining) filter(where component='empty'),0) e,coalesce(sum(remaining_value) filter(where component='filled'),0) fv,coalesce(sum(remaining_value) filter(where component='empty'),0) ev from app_private.fifo_layers where tenant_id=t and item_id=id and remaining>0)x where c.tenant_id=t and c.item_id=id),true));
 expected:=expected||jsonb_build_object('fifo_consistent',true);
 elsif k='loan' then
  perform 1 from public.loans where tenant_id=t and loan_id=id for update nowait;
  if not found then return false;end if;
  select jsonb_build_object('outstanding',outstanding) into observed from public.loans where tenant_id=t and loan_id=id;
  select jsonb_build_object('outstanding',principal-coalesce((select sum(amount) from public.loan_activity where tenant_id=t and loan_id=id and action in ('principal repayment','repayment received')),0)) into expected from public.loans where tenant_id=t and loan_id=id;
 elsif k='asset' then
  perform 1 from public.business_assets where tenant_id=t and asset_id=id for update nowait;
  if not found then return false;end if;
  select jsonb_build_object('book_value',case when status='active' then cost-accumulated_depreciation else 0 end) into observed from public.business_assets where tenant_id=t and asset_id=id;
  select jsonb_build_object('book_value',coalesce(sum(amount),0)) into expected from public.accounting_lines where tenant_id=t and entity_id=id and account in ('vehicles','equipment','other_assets');
 elsif k='obligation' then
  perform 1 from public.finance_obligations where tenant_id=t and obligation_id=id for update nowait;
  if not found then return false;end if;
  select jsonb_build_object('settled',settled) into observed from public.finance_obligations where tenant_id=t and obligation_id=id;
  select jsonb_build_object('settled',coalesce(sum(abs(amount)),0)) into expected from public.wallet_transactions where tenant_id=t and reference_id=id and type='obligation_settlement';
 elsif k='payroll' then
  perform 1 from public.employees where tenant_id=t and employee_id=id for update nowait;
  if not found then return false;end if;
  -- Compare each actual payment header with its immutable wallet allocations.
  select jsonb_build_object('payments',coalesce(sum(amount),0)) into observed from public.employee_payments where tenant_id=t and employee_id=id;
  select jsonb_build_object('payments',coalesce(sum(e.amount),0)) into expected from public.employee_payment_entries e join public.employee_payments p using(tenant_id,payment_id) where p.tenant_id=t and p.employee_id=id;
  for salary_period in select date_trunc('month',x)::date period from generate_series((select min(effective_from)::timestamp from public.employee_terms where tenant_id=t and employee_id=id),date_trunc('month',now() at time zone 'Asia/Dhaka'),'1 month')x loop
   v:=(app_private.employee_month_balance(t,id,salary_period.period)->>'salary_amount')::numeric;
   v2:=coalesce((select sum(l.amount) from public.accounting_lines l join public.accounting_journals j using(tenant_id,journal_id) where j.tenant_id=t and j.source='salary_accrual' and j.source_id=md5(id::text||salary_period.period::text)::uuid and l.account='employee_expense'),0);
   if v<>v2 then observed:=observed||jsonb_build_object(salary_period.period::text,v2);expected:=expected||jsonb_build_object(salary_period.period::text,v);end if;
  end loop;
 elsif k='sale' then
  perform 1 from public.sales where tenant_id=t and sale_id=id for update nowait;
  if not found then return false;end if;
  select jsonb_build_object('recognized_invoice',case when status='completed' then total_amount+additional_charges else 0 end) into expected from public.sales where tenant_id=t and sale_id=id;
  select jsonb_build_object('recognized_invoice',coalesce(sum(l.amount),0)) into observed from public.accounting_journals j join public.accounting_lines l using(tenant_id,journal_id) where j.tenant_id=t and j.source='sale' and j.source_id=id and l.account='customer_receivable';
 elsif k='purchase' then
  perform 1 from public.purchases where tenant_id=t and purchase_id=id for update nowait;
  if not found then return false;end if;
  select jsonb_build_object('recognized_invoice',case when status in ('in_transit','received') then payable_amount else 0 end) into expected from public.purchases where tenant_id=t and purchase_id=id;
  select jsonb_build_object('recognized_invoice',coalesce(-sum(l.amount),0)) into observed from public.accounting_journals j join public.accounting_lines l using(tenant_id,journal_id) where j.tenant_id=t and j.source='purchase' and j.source_id=id and l.account='supplier_payable';
 elsif k='transit' then
  perform 1 from public.transits where tenant_id=t and transit_id=id for update nowait;
  if not found then return false;end if;
  select jsonb_build_object('earned_revenue',case when purchase_id is null and status<>'cancelled' then transport_fee else 0 end,
   'incurred_costs',coalesce((select sum(amount) from public.operating_cost_events where tenant_id=t and transit_id=id),0)) into expected from public.transits where tenant_id=t and transit_id=id;
  select jsonb_build_object('earned_revenue',coalesce((select -sum(l.amount) from public.accounting_journals j join public.accounting_lines l using(tenant_id,journal_id) where j.tenant_id=t and j.source='transit_revenue' and j.source_id=id and l.account='logistics_revenue'),0),
   'incurred_costs',coalesce((select sum(l.amount) from public.operating_cost_events e join public.accounting_journals j on j.tenant_id=e.tenant_id and j.source='operating_cost' and j.source_id=e.event_id join public.accounting_lines l on l.tenant_id=j.tenant_id and l.journal_id=j.journal_id join public.accounting_accounts a on a.code=l.account where e.tenant_id=t and e.transit_id=id and a.kind='expense'),0)) into observed;
 elsif k='journal' then
  select jsonb_build_object('imbalance',coalesce(sum(amount),0),'has_lines',count(*)>0) into observed from public.accounting_lines where tenant_id=t and journal_id=id;
  expected:=jsonb_build_object('imbalance',0,'has_lines',true);
 elsif k='snapshot' then
  -- Validate one month per queue item; requeue the next month through its audit
  -- revision in the sweep. Exact rows, not just the equation, must agree.
  select min(month_end) into d from app_private.accounting_snapshots s where s.tenant_id=t and md5(s.month_end::text)::uuid=id;
  if d is null then return false;end if;
  if exists(select 1 from app_private.accounting_snapshot_state where tenant_id=t and invalid_from<=d) then return false;end if;
  select checksum into hash from app_private.accounting_snapshots where tenant_id=t and month_end=d;
  observed:=jsonb_build_object('checksum',hash,'difference',0);
  with full_history as(select l.account,l.business_category,l.entity_id,l.type_id,sum(l.amount) amount,sum(l.consolidated_amount) consolidated_amount from public.accounting_lines l join public.accounting_journals j using(tenant_id,journal_id) where j.tenant_id=t and j.occurred_on<=d group by 1,2,3,4),
 diff as(select * from full_history except select account,business_category,entity_id,type_id,amount,consolidated_amount from app_private.accounting_snapshot_lines where tenant_id=t and month_end=d),
 reverse_diff as(select account,business_category,entity_id,type_id,amount,consolidated_amount from app_private.accounting_snapshot_lines where tenant_id=t and month_end=d except select * from full_history)
 select jsonb_build_object('checksum',md5(coalesce((select string_agg(concat_ws(':',account,business_category,entity_id,type_id,amount,consolidated_amount),'|' order by account,business_category,entity_id,type_id) from full_history),'')),'difference',(select count(*) from diff)+(select count(*) from reverse_diff)) into expected;
  if observed is distinct from expected then update app_private.accounting_snapshot_state set invalid_from=least(invalid_from,d) where tenant_id=t;note:='Savepoint invalidated; canonical journals remain unchanged';end if;
 else raise exception 'Unknown reconciliation kind';end if;
 if observed is null and expected is null then return false;end if;
 if observed is distinct from expected then
  insert into app_private.reconciliation_findings(tenant_id,kind,entity_id,observed,expected,status,diagnostic) values(t,k,id,coalesce(observed,'null'),coalesce(expected,'null'),case when safe then 'repaired' else 'unresolved' end,note);return true;
 end if;return false;end $function$;
CREATE OR REPLACE FUNCTION app_private.finance_analysis_report(p_filters jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare ids uuid[]:=app_private.analysis_scope(p_filters);f date:=(p_filters->>'from')::date;u date:=(p_filters->>'to')::date;cat text:=coalesce(p_filters->>'category','all');
 grain text:=coalesce(p_filters->>'grain','month');opening jsonb;closing jsonb;result jsonb;r record;coverage boolean;estimated boolean;missing bigint;original boolean:=coalesce((p_filters->>'all_time')::boolean,false);begin

 if f is null or u is null or not isfinite(f) or not isfinite(u) or f>u or u>(now() at time zone 'Asia/Dhaka')::date or u-f>36525 or grain not in ('day','month','year') or grain='day' and u-f>730 or cat not in ('all','lpg','stove','logistics') then raise exception 'Choose a valid reporting period and business activity';end if;
 if original then select min((started_at at time zone 'Asia/Dhaka')::date) into f from public.accounting_periods where tenant_id=any(ids);f:=least(f,u);if grain='day' and u-f>730 then grain:='month';end if;end if;
 select bool_and(true),bool_or(a.estimated) into coverage,estimated from public.accounting_periods a where tenant_id=any(ids);
 select count(*) into missing from public.vehicles v where v.tenant_id=any(ids) and v.availability<>'retired' and not exists(select 1 from public.business_assets a where a.tenant_id=v.tenant_id and a.vehicle_id=v.vehicle_id);
 coverage:=coalesce(coverage,false) and missing=0;
 opening:=app_private.scoped_position(ids,f,cat,true,original);closing:=app_private.scoped_position(ids,u,cat);
 with period_lines as materialized(
 select j.tenant_id,j.journal_id,j.occurred_on,j.source,j.source_id,j.description,l.account,case when cat='all' then l.consolidated_amount else l.amount end amount,l.amount business_amount,l.business_category,l.entity_id,a.kind,a.name
 from public.accounting_journals j join public.accounting_lines l using(tenant_id,journal_id) join public.accounting_accounts a on a.code=l.account
 where j.tenant_id=any(ids) and j.occurred_on between f and u and not j.is_opening),
 attributed as materialized(select * from period_lines where cat='all' or business_category=cat),
 totals as(select coalesce(-sum(amount) filter(where kind='income'),0) revenue,coalesce(sum(amount) filter(where kind='expense'),0) expenses,
 coalesce(-sum(amount) filter(where account='capital'),0) contributions,coalesce(sum(amount) filter(where account='withdrawals'),0) withdrawals,
 coalesce(-sum(amount) filter(where account in ('opening_equity','equity_adjustment','business_allocation_equity','retained_earnings')),0)+coalesce((
 select -sum(case when cat='all' then l.consolidated_amount else l.amount end) from public.accounting_journals j join public.accounting_lines l using(tenant_id,journal_id)
 where j.tenant_id=any(ids) and j.is_opening and j.occurred_on>=f and j.occurred_on<=u and not(original and j.occurred_on=f)
 and l.account in ('opening_equity','equity_adjustment','business_allocation_equity','retained_earnings','capital') and (cat='all' or l.business_category=cat)),0) equity_adjustments,
 coalesce(sum(amount) filter(where account='cash' and amount>0 and description is not null and source='wallet'),0) gross_cash_in,
 coalesce(-sum(amount) filter(where account='cash' and amount<0 and source='wallet'),0) gross_cash_out from attributed),
 cash as materialized(select l.*,x.type,
 case when x.type='custom_entry' then (select case when e.account in ('capital','withdrawals') then 'financing' when e.account in ('equipment','other_assets') then 'investing' else 'operating' end from public.financial_entries e where e.tenant_id=x.tenant_id and e.entry_id=x.reference_id) when x.type='obligation_settlement' then coalesce((select o.cash_activity from public.finance_obligations o where o.tenant_id=x.tenant_id and o.obligation_id=x.reference_id),'unclassified') when x.type in ('loan_lend','loan_collect') then 'investing' when x.type in ('loan_receipt','loan_repayment','owner_capital','balance_adjustment','owner_withdrawal') then 'financing'
 when x.type in ('asset_purchase','asset_proceeds','asset_disposal_expense') then 'investing' else 'operating' end cash_category
 from attributed l join public.wallet_transactions x on x.tenant_id=l.tenant_id and x.transaction_id=l.source_id where l.account='cash' and l.source='wallet'),
 buckets as(select d::date period from generate_series(date_trunc(grain,f::timestamp),date_trunc(grain,u::timestamp),('1 '||grain)::interval)d),
 activity_trend as(select date_trunc(grain,occurred_on)::date period,coalesce(-sum(amount) filter(where kind='income'),0) revenue,coalesce(sum(amount) filter(where kind='expense'),0) expenses
 from attributed group by 1),
 cash_trend as(select date_trunc(grain,occurred_on)::date period,sum(greatest(0,amount)) cash_in,-sum(least(0,amount)) cash_out,sum(amount) cash_flow from cash group by 1),
 position_events as (
 select b.tenant_id,b.account,case when b.account='cash' then null::uuid else b.entity_id end entity_id,date_trunc(grain,f::timestamp)::date period,case when cat='all' then b.consolidated_amount else b.amount end amount
 from app_private.dimensional_balances(ids,f,true,original)b join public.accounting_accounts a on a.code=b.account where (cat='all' or b.business_category=cat) and a.kind in ('asset','liability')
 union all
 select l.tenant_id,l.account,case when l.account='cash' then null::uuid else l.entity_id end,date_trunc(grain,j.occurred_on)::date,case when cat='all' then l.consolidated_amount else l.amount end
 from public.accounting_journals j join public.accounting_lines l using(tenant_id,journal_id) join public.accounting_accounts a on a.code=l.account
 where j.tenant_id=any(ids) and j.occurred_on between f and u and not(original and j.is_opening and j.occurred_on=f) and (cat='all' or l.business_category=cat) and a.kind in ('asset','liability')),
 position_deltas as(select tenant_id,account,entity_id,period,sum(amount) amount from position_events group by 1,2,3,4),
 position_running as(select *,sum(amount) over(partition by tenant_id,account,entity_id order by period) balance from position_deltas),
 position_changes as(select *,case when account='cash' then balance-lag(balance,1,0::numeric) over(partition by tenant_id,account,entity_id order by period) else greatest(balance,0)-greatest(lag(balance,1,0::numeric) over(partition by tenant_id,account,entity_id order by period),0) end asset_change,
 case when account='cash' then 0 else -least(balance,0)+least(lag(balance,1,0::numeric) over(partition by tenant_id,account,entity_id order by period),0) end liability_change from position_running),
 position_trend as(select period,sum(asset_change) asset_change,sum(liability_change) liability_change from position_changes group by period),
 trend as(select b.period,greatest(f,b.period) period_start,least(u,(b.period+('1 '||grain)::interval-interval '1 day')::date) period_end,
 coalesce(a.revenue,0) revenue,coalesce(a.expenses,0) expenses,coalesce(a.revenue,0)-coalesce(a.expenses,0) profit,
 coalesce(c.cash_in,0) cash_in,coalesce(c.cash_out,0) cash_out,coalesce(c.cash_flow,0) cash_flow,
 sum(coalesce(p.asset_change,0)) over(order by b.period) assets,sum(coalesce(p.liability_change,0)) over(order by b.period) liabilities,
 sum(coalesce(p.asset_change,0)-coalesce(p.liability_change,0)) over(order by b.period) net_worth
 from buckets b left join activity_trend a using(period) left join cash_trend c using(period) left join position_trend p using(period)),
 categories as(select account,name,kind,sum(case when kind='income' then -amount else amount end) amount from attributed where kind in ('income','expense') group by 1,2,3),
 business as(select tenant_id,business_category,coalesce(-sum(business_amount) filter(where kind='income'),0) revenue,coalesce(sum(business_amount) filter(where kind='expense'),0) expenses from period_lines where kind in ('income','expense') group by 1,2)
 select jsonb_build_object('from',f,'to',u,'category',cat,'opening',opening,'closing',closing,'complete',coverage,'estimated',estimated,'missing_asset_values',missing,
 'coverage',coalesce((select jsonb_agg(jsonb_build_object('tenant_id',a.tenant_id,'started_at',a.started_at,'note',a.opening_note)) from public.accounting_periods a where a.tenant_id=any(ids)),'[]'),
 'totals',jsonb_build_object('revenue',revenue,'expenses',expenses,'profit',case when coverage then revenue-expenses end,
 'contributions',contributions,'withdrawals',withdrawals,'equity_adjustments',equity_adjustments,
 'cash_in',coalesce((select sum(amount) from cash where amount>0),0),'cash_out',coalesce((select -sum(amount) from cash where amount<0),0),
 'cash_flow',coalesce((select sum(amount) from cash),0),'transfers',case when cat='all' then coalesce((select sum(x.amount) from public.wallet_transactions x where x.tenant_id=any(ids) and x.type='wallet_transfer' and x.amount>0 and x.accounting_date between f and u),0) else 0 end,
 'position_profit',case when coverage then (closing->>'assets')::numeric-(closing->>'liabilities')::numeric-(opening->>'assets')::numeric+(opening->>'liabilities')::numeric-contributions+withdrawals-equity_adjustments end),
 'categories',coalesce((select jsonb_agg(to_jsonb(c) order by kind,amount desc) from categories c),'[]'),
 'cash_categories',coalesce((select jsonb_agg(to_jsonb(c)) from(select cash_category category,sum(greatest(0,amount)) received,-sum(least(0,amount)) spent,sum(amount) net from cash group by cash_category)c),'[]'),
 'trend',coalesce((select jsonb_agg(to_jsonb(t) order by period) from trend t),'[]'),
 'businesses',coalesce((select jsonb_agg(to_jsonb(b)) from business b),'[]'),
 'all_time',original,'period_income',(closing->>'accumulated_income')::numeric-(opening->>'accumulated_income')::numeric,
 'invested_capital',closing->'capital','retained_earnings',(closing->>'accumulated_income')::numeric+coalesce((closing->>'historical_earnings')::numeric,0),'capital_recorded',closing->'capital','withdrawals_to_date',closing->'withdrawals') into result from totals;
 return result||jsonb_build_object('business_positions',(select jsonb_agg(jsonb_build_object('category',b,'opening',case when b=cat then opening else app_private.scoped_position(ids,f,b,true,original) end,'closing',case when b=cat then closing else app_private.scoped_position(ids,u,b) end)) from unnest(array['lpg','stove','logistics','all'])b),'period_values',app_private.period_financial_values(p_filters||jsonb_build_object('from',result->>'from')));end $function$;
CREATE OR REPLACE FUNCTION public.get_accounting_register(p_kind text, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_any_permission(array['finance:view','finance:manage']);r jsonb;begin
 if p_offset is null or p_offset<0 then raise exception 'Invalid page';end if;
 if p_kind in ('loans','lending') then select jsonb_build_object('total',count(*),'entries',coalesce((select jsonb_agg(to_jsonb(p)) from(select * from public.loans where tenant_id=t and direction=case when p_kind='lending' then 'lent' else 'borrowed' end order by created_at desc,loan_id offset p_offset limit 20)p),'[]')) into r from public.loans where tenant_id=t and direction=case when p_kind='lending' then 'lent' else 'borrowed' end;
 elsif p_kind='assets' then select jsonb_build_object('total',count(*),'entries',coalesce((select jsonb_agg(to_jsonb(p)) from(select * from public.business_assets where tenant_id=t order by created_at desc,asset_id offset p_offset limit 20)p),'[]')) into r from public.business_assets where tenant_id=t;
 elsif p_kind in ('opening','obligations') then select jsonb_build_object('total',count(*),'entries',coalesce((select jsonb_agg(to_jsonb(p)) from(select * from public.finance_obligations where tenant_id=t and origin=case when p_kind='opening' then 'opening' else 'incurred' end order by created_at desc,obligation_id offset p_offset limit 20)p),'[]')) into r from public.finance_obligations where tenant_id=t and origin=case when p_kind='opening' then 'opening' else 'incurred' end;
 else raise exception 'Invalid register';end if;return r;end $function$;
CREATE OR REPLACE FUNCTION app_private.guard_purchase_rebate()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
 if tg_op='UPDATE' and old.status='received' and old.payment_status='paid' and new.rebate_amount is distinct from old.rebate_amount then raise exception 'Completed purchase commission rebate is locked';end if;
 if new.rebate_amount>new.subtotal then raise exception 'Commission rebate cannot exceed the company product invoice';end if;
 if new.status<>'cancelled' and new.paid_amount+new.rebate_amount>(new.subtotal+new.labour_cost) then raise exception 'Commission rebate and wallet payments exceed the purchase balance';end if;
 if new.status in ('in_transit','received') or new.status='created' and new.paid_amount>0 then
  new.payment_status:=case when new.paid_amount+new.rebate_amount>=(new.subtotal+new.labour_cost) then 'paid' when new.paid_amount+new.rebate_amount>0 then 'partial' else 'unpaid' end;
  new.paid_at:=case when new.payment_status='paid' then coalesce(new.paid_at,clock_timestamp()) else null end;
 end if;
 return new;
end $function$;
CREATE OR REPLACE FUNCTION public.set_purchase_rebate(p_purchase_id uuid, p_payload jsonb, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_owner('purchases:edit');p public.purchases;prior public.finance_requests;body jsonb;result jsonb;a numeric;
begin
 perform app_private.require_permission('purchases:manage');perform app_private.require_permission('purchases:pay');
 if p_request_id is null then raise exception 'Rebate request ID is required';end if;
 if jsonb_typeof(p_payload) is distinct from 'object' or p_payload-array['amount','revision','notes']<>'{}'::jsonb or not(p_payload ? 'amount') then raise exception 'Enter a rebate amount and purchase revision';end if;
 a:=app_private.rebate_money(p_payload->'amount');
 body:=jsonb_build_object('action','purchase_rebate','purchase',p_purchase_id,'body',p_payload,'actor',auth.uid());
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from body then raise exception 'Request ID already used with different details';end if;return prior.result;end if;
 select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id for update;
 if not found then raise exception 'Purchase not found';end if;
 if p.status='received' and p.payment_status='paid' then raise exception 'Completed purchase commission rebate is locked';end if;
 if p.status='cancelled' then raise exception 'Cancelled purchase rebates are locked; released credit belongs to the company';end if;
 if (p_payload->>'revision')::integer is distinct from p.revision then raise exception 'Purchase changed. Reload before saving the rebate';end if;
 if p.status='received' and p.payment_status='paid' and p_payload ? 'notes' and coalesce(p_payload->>'notes','') is distinct from coalesce(p.notes,'') then raise exception 'Completed purchase notes are locked';end if;
 if length(coalesce(p_payload->>'notes',''))>4000 then raise exception 'Purchase notes are too long';end if;
 update public.purchases set rebate_amount=a,notes=case when p.status='received' and p.payment_status='paid' then p.notes when p_payload ? 'notes' then p_payload->>'notes' else notes end,
 revision=revision+1,updated_at=clock_timestamp() where tenant_id=t and purchase_id=p_purchase_id;
 result:=jsonb_build_object('purchase_id',p_purchase_id,'rebate_amount',a,'due',p.payable_amount-a-p.paid_amount);
 insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,result,auth.uid());
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
 select jsonb_build_object('total',p.payable_amount,'rebate_amount',p.rebate_amount,'rebate_applied',case when p.status in ('in_transit','received') then p.rebate_amount else 0 end,'company_credit',coalesce((select sum(e.income_delta-e.applied_delta) from app_private.purchase_rebate_events e join app_private.purchase_rebate_accounts a using(tenant_id,account_id) where e.tenant_id=t and a.company_key=app_private.rebate_company_key(p)),0),'can_rebate',not(p.status='received' and p.payment_status='paid') and p.status<>'cancelled' and app_private.is_owner() and app_private.has_permission('purchases:pay'),'allocated_transport',p.transport_cost,'paid',p.paid_amount,'due',case when p.status='cancelled' then 0 else greatest(0,p.payable_amount-p.rebate_amount-p.paid_amount) end,
 'refund_due',p.refund_due,'refunded',p.refunded_amount,'financial_closed_at',p.financial_closed_at,'can_cancel',public.can_cancel_purchases(),
 'financial_locked',p.paid_amount>0 or p.status='received' or p.payment_status='paid' or exists(select 1 from public.wallet_transactions where tenant_id=t and reference_id=p_purchase_id and amount<0 and type in ('purchase_expense','purchase_company_payment','purchase_logistics_payment','purchase_payment_company','purchase_payment_labour','purchase_payment_transport','purchase_payment')),
 'obligations',coalesce((select jsonb_agg(to_jsonb(o)||jsonb_build_object('refunded',coalesce(q.amount,0),'remaining',o.amount-coalesce(q.amount,0)) order by o.component)
 from public.purchase_refund_obligations o left join lateral(select sum(amount) amount from public.purchase_payments where tenant_id=t and obligation_id=o.obligation_id) q on true where o.tenant_id=t and o.purchase_id=p_purchase_id),'[]'),
 'payment_count',(select count(*) from public.wallet_transactions where tenant_id=t and reference_id=p_purchase_id),
 'payments',coalesce((select jsonb_agg(to_jsonb(e) order by e.entry_no) from (select x.transaction_id,x.purchase_payment_id,x.wallet_name_snapshot wallet_name,x.wallet_method_snapshot method,x.amount,x.type,x.created_at,x.entry_no,x.operation_id,x.description,x.counterparty_wallet_id,pp.reference,pp.component,pp.obligation_id,up.full_name actor
  from public.wallet_transactions x left join public.purchase_payments pp on pp.tenant_id=t and pp.payment_id=x.purchase_payment_id
  left join app_private.tenant_actors up on up.tenant_id=t and up.user_id=x.created_by
  where x.tenant_id=t and x.reference_id=p_purchase_id order by x.entry_no limit p_limit offset p_offset) e),'[]')) into result;
 return result;
end $function$;
CREATE OR REPLACE FUNCTION public.get_accounting_breakdown(p_filters jsonb, p_group text, p_side text, p_mode text DEFAULT 'components'::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$declare
 ids uuid[]:=app_private.analysis_scope(p_filters);d date:=(p_filters->>'to')::date;f date:=(p_filters->>'from')::date;
 cat text:=coalesce(p_filters->>'category','all');original boolean:=false;before_day boolean:=false;r jsonb;begin
 if coalesce(p_filters->>'direction','all') not in ('all','increase','decrease') or coalesce(p_filters->>'sort','newest') not in ('newest','oldest','largest','smallest')
 or nullif(p_filters->>'min','')::numeric<0 or nullif(p_filters->>'max','')::numeric<0
 or nullif(p_filters->>'min','')::numeric>nullif(p_filters->>'max','')::numeric
 or nullif(p_filters->>'history_from','')::date>d then raise exception 'Invalid activity ranges';end if;
 if p_side not in ('opening','closing','period') or p_mode not in ('components','history') or p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100
 or p_group not in ('all','assets','liabilities','equity','accumulated_income','cash','inventory','receivables','fixed_assets','other_assets','dues','employees','other_liabilities','capital','revenue','expenses','withdrawals','other_equity')
 or f is null or d is null or not isfinite(f) or not isfinite(d) or f>d or d>(now() at time zone 'Asia/Dhaka')::date or length(coalesce(p_filters->>'search',''))>500 or cat not in ('all','lpg','stove','logistics') then raise exception 'Invalid breakdown filters';end if;
 if coalesce((p_filters->>'all_time')::boolean,false) then select min((started_at at time zone 'Asia/Dhaka')::date) into f from public.accounting_periods where tenant_id=any(ids);f:=least(f,d);end if;
 if p_side='opening' then before_day:=true;d:=f;original:=coalesce((p_filters->>'all_time')::boolean,false);end if;
 with evidence as(select *,1 sign from app_private.dimensional_balances(ids,d,before_day,original) union all select *,-1 from app_private.dimensional_balances(ids,f,true,coalesce((p_filters->>'all_time')::boolean,false)) where p_side='period'),
 balances as materialized(select b.tenant_id,b.account,b.business_category,b.type_id,
 case when a.kind in ('income','expense','equity') or b.account='cash' then null else b.entity_id end entity_id,a.kind,a.name,
 sum(b.sign*case when cat='all' then b.consolidated_amount else b.amount end) amount
 from evidence b join public.accounting_accounts a on a.code=b.account where cat='all' or b.business_category=cat group by 1,2,3,4,5,6,7),
 classified as(select *,sum(amount) over(partition by tenant_id,account,entity_id) control_total,case when kind='liability' and sum(amount) over(partition by tenant_id,account,entity_id)>0 then 'asset'
 when kind='asset' and account<>'cash' and sum(amount) over(partition by tenant_id,account,entity_id)<0 then 'liability' else kind end reported_kind from balances),
 selected as materialized(select *,case when p_group='withdrawals' then 1 when p_group in ('equity','accumulated_income') or reported_kind in ('liability','income','equity') then -1 else 1 end sign
 from classified where (p_group='all' or app_private.analysis_matches(p_group,account,reported_kind))
 and (nullif(p_filters->>'account','') is null or account=p_filters->>'account')
 and (nullif(p_filters->>'type_id','') is null or type_id=(p_filters->>'type_id')::uuid)
 and (nullif(p_filters->>'component_business','') is null or business_category=p_filters->>'component_business')
 and (nullif(p_filters->>'entity_id','') is null or p_filters->>'entity_id'='none' and entity_id is null or entity_id=nullif(nullif(p_filters->>'entity_id',''),'none')::uuid)),
 described as materialized(select s.*,ft.name type_name,app_private.analysis_entity(s.tenant_id,s.account,s.entity_id) entity from selected s join public.financial_types ft using(type_id)),
 components as materialized(select * from described where
 (nullif(p_filters->>'min','') is null or abs(amount)>=(p_filters->>'min')::numeric)
 and (nullif(p_filters->>'max','') is null or abs(amount)<=(p_filters->>'max')::numeric)
 and (coalesce(p_filters->>'direction','all')='all' or p_filters->>'direction'='increase' and amount*sign>0 or p_filters->>'direction'='decrease' and amount*sign<0) and amount<>0 and (kind in ('income','expense','equity') or control_total<>0) and app_private.finance_search(concat_ws(' ',name,type_name,business_category,entity->>'entity_name'),coalesce(p_filters->>'search',''))),
 component_page as(select * from components order by abs(amount) desc,tenant_id,account,type_id,business_category,entity_id nulls first offset p_offset limit p_limit),
 movements as materialized(select j.tenant_id,j.journal_id,j.entry_no,j.occurred_on,j.description,j.source,j.source_id,j.source_id transaction_reference,j.estimated,l.line_no,l.account,s.name,l.type_id,s.type_name,l.business_category,l.entity_id,
 (case when cat='all' then l.consolidated_amount else l.amount end)*s.sign amount,app_private.analysis_entity(l.tenant_id,l.account,l.entity_id)||app_private.financial_source_link(j.tenant_id,j.source,j.source_id) entity
 from described s join public.accounting_lines l on l.tenant_id=s.tenant_id and l.account=s.account and l.type_id=s.type_id and l.business_category=s.business_category
 and (s.kind in ('income','expense','equity') or s.account='cash' or l.entity_id is not distinct from s.entity_id)
 join public.accounting_journals j on j.tenant_id=l.tenant_id and j.journal_id=l.journal_id
 where p_mode='history' and (p_side<>'period' or j.occurred_on>=f) and (case when before_day then j.occurred_on<d or original and j.is_opening and j.occurred_on=d else j.occurred_on<=d end)
 and (nullif(p_filters->>'history_from','') is null or j.occurred_on>=(p_filters->>'history_from')::date)
 and (nullif(p_filters->>'source','') is null or j.source=p_filters->>'source')
 and app_private.finance_search(concat_ws(' ',j.description,s.name,s.type_name,s.business_category,s.entity->>'entity_name',j.source,j.source_id),coalesce(p_filters->>'search',''))),
 filtered_movements as materialized(select * from movements where
 (nullif(p_filters->>'min','') is null or abs(amount)>=(p_filters->>'min')::numeric)
 and (nullif(p_filters->>'max','') is null or abs(amount)<=(p_filters->>'max')::numeric)
 and (coalesce(p_filters->>'direction','all')='all' or p_filters->>'direction'='increase' and amount>0 or p_filters->>'direction'='decrease' and amount<0)),
 history_page as(select * from filtered_movements order by
 case when p_filters->>'sort'='oldest' then occurred_on end asc,
 case when p_filters->>'sort'='largest' then abs(amount) end desc,
 case when p_filters->>'sort'='smallest' then abs(amount) end asc,
 occurred_on desc,entry_no desc,line_no offset p_offset limit p_limit)
 select jsonb_build_object('cutoff',case when before_day and not original then d-1 else d end,'original_opening',original,'accounts',(select jsonb_agg(jsonb_build_object('code',code,'name',name) order by name) from public.accounting_accounts),'sources',coalesce((select jsonb_agg(source order by source) from(select distinct source from public.accounting_journals where tenant_id=any(ids)) sources),'[]'::jsonb),
 'balance',coalesce((select sum(amount*sign) from selected),0),
 'total',case when p_mode='components' then (select count(*) from components) else (select count(*) from filtered_movements) end,
 'filtered_movement',case when p_mode='history' then (select coalesce(sum(amount),0) from filtered_movements) end,
 'entries',case when p_mode='components' then coalesce((select jsonb_agg(jsonb_build_object('tenant_id',tenant_id,'account',account,'name',name,'kind',reported_kind,'entity_id',entity_id,'type_id',type_id,'type_name',type_name,'business_category',business_category,'amount',amount*sign)||entity order by abs(amount) desc,tenant_id,account,type_id,business_category,entity_id nulls first) from component_page),'[]')
 else coalesce((select jsonb_agg((to_jsonb(p)-'entity')||entity order by case when p_filters->>'sort'='oldest' then occurred_on end asc,case when p_filters->>'sort'='largest' then abs(amount) end desc,case when p_filters->>'sort'='smallest' then abs(amount) end asc,occurred_on desc,entry_no desc,line_no) from history_page p),'[]') end) into r;return r;end $function$;
notify pgrst,'reload schema';
