-- Supplemental opening balances must remain settleable without creating a new
-- expense or fictional invoice. Existing operational receivables/payables retain
-- their original sale/purchase/payroll settlement paths.
create table public.finance_obligations (
 tenant_id uuid not null references public.tenants(tenant_id),obligation_id uuid not null default gen_random_uuid(),account text not null references public.accounting_accounts(code),origin text not null default 'opening' check(origin in ('opening','incurred')),cash_activity text not null default 'operating' check(cash_activity in ('operating','investing','financing','unclassified')),
 entity_id uuid,description text not null,amount numeric(16,2) not null check(amount>0),settled numeric(16,2) not null default 0 check(settled>=0),
 occurred_on date not null,created_at timestamptz not null default clock_timestamp(),created_by uuid,primary key(tenant_id,obligation_id),check(settled<=amount)
);
alter table public.finance_obligations owner to postgres;
alter table public.finance_obligations enable row level security;
revoke all on public.finance_obligations from public,anon,authenticated;
-- Replacement canonical definitions below extend the existing operation and
-- register contracts; there are no extra overloads or direct browser writes.

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
  insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,operation_id,description,accounting_date) values(t,wallet,case when ob.account='customer_receivable' then amount else -amount end,'settle_obligationment',id,p_request_id,note,d);
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
  id:=commission.commission_id;category:=commission.business_category;
  insert into public.commission_applications(tenant_id,commission_id,purchase_id,amount,created_by) values(t,id,p.purchase_id,amount,auth.uid());
  update public.supplier_commissions set used=used+accounting_op.amount where tenant_id=t and commission_id=id;
  update public.purchases set paid_amount=paid_amount+amount,payment_status=case when paid_amount+amount>=payable_amount then 'paid' else 'partial' end,revision=revision+1 where tenant_id=t and purchase_id=p.purchase_id;
  entries:=jsonb_build_array(app_private.accounting_line('supplier_payable',amount,category,p.purchase_id),app_private.accounting_line('supplier_receivable',-amount,category,id));
 else raise exception 'Unsupported accounting action';end if;
 perform app_private.post_journal(t,'owner_operation',p_request_id,'record',d,note,entries,false,action='opening_entry' or action='loan_create' and coalesce((p_payload->>'opening')::boolean,false) or action='asset_register' and p_payload->>'funding'='opening');
 result:=jsonb_build_object('id',id);insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,result,auth.uid());return result;end $$;
create or replace function app_private.account_wallet() returns trigger language plpgsql set search_path='' as $$
declare other text;entity uuid:=new.reference_id;cat text:='shared';ep public.employee_payments;begin
 if new.type in ('pos_sale_income','customer_collection','sale_refund') then other:='customer_receivable';
  select customer_id,coalesce(to_jsonb(s)->>'business_category','lpg') into entity,cat from public.sales s where tenant_id=new.tenant_id and sale_id=new.reference_id;
 elsif new.type like 'purchase%' then other:='supplier_payable';select coalesce(to_jsonb(p)->>'business_category','lpg') into cat from public.purchases p where tenant_id=new.tenant_id and purchase_id=new.reference_id;
 elsif new.type like 'payroll_%' then
  select p.* into ep from public.employee_payment_entries e join public.employee_payments p using(tenant_id,payment_id) where e.tenant_id=new.tenant_id and e.entry_id=new.employee_entry_id;
  other:='employee_payable';entity:=case when ep.kind='trips' then ep.transit_id else ep.employee_id end;cat:=case when ep.kind='trips' then 'logistics' else 'shared' end;
 elsif new.type like 'transit_client_%' then other:='transport_receivable';cat:='logistics';
 elsif new.type in ('transit_expense','transit_expense_return','vehicle_service_expense','vehicle_service_expense_return') then other:='operating_payable';cat:='logistics';
 elsif new.type='settle_obligationment' then select o.account,o.entity_id into other,entity from public.finance_obligations o where o.tenant_id=new.tenant_id and o.obligation_id=new.reference_id;
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
create or replace function public.get_accounting_register(p_kind text,p_offset integer default 0) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['finance:view','finance:manage']);r jsonb;begin
 if p_offset is null or p_offset<0 then raise exception 'Invalid page';end if;
 if p_kind='loans' then select jsonb_build_object('total',count(*),'entries',coalesce((select jsonb_agg(to_jsonb(p)) from(select * from public.loans where tenant_id=t order by created_at desc,loan_id offset p_offset limit 20)p),'[]')) into r from public.loans where tenant_id=t;
 elsif p_kind='assets' then select jsonb_build_object('total',count(*),'entries',coalesce((select jsonb_agg(to_jsonb(p)) from(select * from public.business_assets where tenant_id=t order by created_at desc,asset_id offset p_offset limit 20)p),'[]')) into r from public.business_assets where tenant_id=t;
 elsif p_kind='commissions' then select jsonb_build_object('total',count(*),'entries',coalesce((select jsonb_agg(to_jsonb(p)) from(select * from public.supplier_commissions where tenant_id=t order by created_at desc,commission_id offset p_offset limit 20)p),'[]')) into r from public.supplier_commissions where tenant_id=t;
 elsif p_kind in ('opening','obligations') then select jsonb_build_object('total',count(*),'entries',coalesce((select jsonb_agg(to_jsonb(p)) from(select * from public.finance_obligations where tenant_id=t and origin=case when p_kind='opening' then 'opening' else 'incurred' end order by created_at desc,obligation_id offset p_offset limit 20)p),'[]')) into r from public.finance_obligations where tenant_id=t and origin=case when p_kind='opening' then 'opening' else 'incurred' end;
 else raise exception 'Invalid register';end if;return r;end $$;
CREATE OR REPLACE FUNCTION public.get_sale_settlement(p_sale_id uuid, p_offset integer DEFAULT 0, p_limit integer DEFAULT 10) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare t uuid:=app_private.require_any_permission(array['finance:view','finance:manage','sales:view','receipts:print','dashboard:view']); s public.sales; result jsonb;
begin
 if p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid payment page'; end if;
 select * into s from public.sales where tenant_id=t and sale_id=p_sale_id;
 if not found then raise exception 'Sale not found'; end if;
 select jsonb_build_object('sale_id',s.sale_id,'status',s.status,'refund_due',case when s.status='voided' then s.paid_amount-coalesce((select sum(amount) from public.sale_refunds where tenant_id=t and sale_id=p_sale_id),0) else 0 end,'original_total',s.total_amount,'additional_charges',s.additional_charges,'total',(s.total_amount+s.additional_charges),'paid',s.paid_amount,'due',case when s.status='voided' then 0 else (s.total_amount+s.additional_charges)-s.paid_amount end,
  'paid_at_checkout',s.paid_at_checkout,'checkout_payments',coalesce((select jsonb_agg(jsonb_build_object('wallet_id',wallet_id,'wallet_name',wallet_name,'method',method,'amount',amount,'reference',reference) order by created_at,payment_id) from public.sale_payments where tenant_id=t and sale_id=p_sale_id and phase='checkout'),'[]'),
  'unattributed_paid',s.paid_amount-(select coalesce(sum(amount),0) from public.sale_payments where tenant_id=t and sale_id=p_sale_id),
  'payment_count',(select count(*) from public.sale_payments where tenant_id=t and sale_id=p_sale_id),
  'payments',coalesce((select jsonb_agg(to_jsonb(p) order by created_at desc,payment_id) from
   (select * from public.sale_payments where tenant_id=t and sale_id=p_sale_id order by created_at desc,payment_id limit p_limit offset p_offset) p),'[]'),
  'receipt_payments',coalesce((select jsonb_agg(to_jsonb(p) order by phase,wallet_name,method) from
   (select wallet_name,method,phase,sum(amount) amount from public.sale_payments where tenant_id=t and sale_id=p_sale_id group by wallet_name,method,phase) p),'[]')) into result;
 return result;
end $$;
CREATE OR REPLACE FUNCTION public.get_purchase_settlement(p_purchase_id uuid, p_offset integer DEFAULT 0, p_limit integer DEFAULT 10) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare t uuid:=app_private.require_any_permission(array['purchases:view','purchases:manage']); p public.purchases; result jsonb;
begin
 if p_offset is null or p_limit is null or p_offset<0 or p_limit not between 1 and 100 then raise exception 'Invalid payment page'; end if;
 select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id;
 if not found then raise exception 'Purchase not found'; end if;
 select jsonb_build_object('total',p.payable_amount,'allocated_transport',p.transport_cost,'paid',p.paid_amount,'due',case when p.status='cancelled' then 0 else greatest(0,p.payable_amount-p.paid_amount) end,
 'refund_due',p.refund_due,'refunded',p.refunded_amount,'financial_closed_at',p.financial_closed_at,'can_cancel',public.can_cancel_purchases(),
 'financial_locked',p.paid_amount>0 or p.status='received' or p.payment_status='paid' or exists(select 1 from public.wallet_transactions where tenant_id=t and reference_id=p_purchase_id and amount<0 and type in ('purchase_expense','purchase_company_payment','purchase_logistics_payment','purchase_payment_company','purchase_payment_labour','purchase_payment_transport','purchase_payment')),
 'obligations',coalesce((select jsonb_agg(to_jsonb(o)||jsonb_build_object('refunded',coalesce(q.amount,0),'remaining',o.amount-coalesce(q.amount,0)) order by o.component)
 from public.purchase_refund_obligations o left join lateral(select sum(amount) amount from public.purchase_payments where tenant_id=t and obligation_id=o.obligation_id) q on true where o.tenant_id=t and o.purchase_id=p_purchase_id),'[]'),
 'payment_count',(select count(*) from public.wallet_transactions where tenant_id=t and reference_id=p_purchase_id),
 'payments',coalesce((select jsonb_agg(to_jsonb(e) order by e.entry_no) from (select x.transaction_id,x.purchase_payment_id,x.wallet_name_snapshot wallet_name,x.wallet_method_snapshot method,x.amount,x.type,x.created_at,x.entry_no,x.operation_id,x.description,x.counterparty_wallet_id,pp.reference,pp.component,pp.obligation_id,up.full_name actor
  from public.wallet_transactions x left join public.purchase_payments pp on pp.tenant_id=t and pp.payment_id=x.purchase_payment_id
  left join public.user_profiles up on up.tenant_id=t and up.user_id=x.created_by
  where x.tenant_id=t and x.reference_id=p_purchase_id order by x.entry_no limit p_limit offset p_offset) e),'[]')) into result;
 return result;
end $$;
drop function public.get_purchase_overview();
CREATE OR REPLACE FUNCTION public.get_purchase_overview(p_category text default null) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare t uuid:=app_private.require_any_permission(array['purchases:view','purchases:manage']); result jsonb;
begin
 select jsonb_build_object('total',count(*),'created',count(*) filter(where status='created'),'in_transit',count(*) filter(where status='in_transit'),
 'unpaid',count(*) filter(where payment_status<>'paid' and status not in ('created','cancelled')),
 'company_payable',coalesce(sum(company_payable) filter(where payment_status<>'paid' and status not in ('created','cancelled')),0),
 'outstanding',coalesce(sum(greatest(0,payable_amount-paid_amount)) filter(where status not in ('created','cancelled')),0),
 'refund_due',coalesce(sum(refund_due),0),'pending_refunds',count(*) filter(where status='cancelled' and financial_closed_at is null)) into result from public.purchases where tenant_id=t and (p_category is null or business_category=p_category);
 return result;
end $$;
alter function public.get_purchase_overview(text) owner to postgres;
revoke all on function public.get_purchase_overview(text) from public,anon;
grant execute on function public.get_purchase_overview(text) to authenticated;
alter function public.accounting_operation(jsonb,uuid) owner to postgres;
alter function app_private.account_wallet() owner to postgres;
alter function public.get_accounting_register(text,integer) owner to postgres;
alter table app_private.accounting_source_state enable row level security;
