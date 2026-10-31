-- One journal, one stock-cost ledger, one wallet posting path. Debit is positive.
-- Existing development activity becomes an explicitly reconstructed opening
-- position. Earlier operational history remains readable; profit is unavailable
-- before the accounting start. No historical cash or stock is invented.
create table public.accounting_accounts (
 code text primary key, name text not null,
 kind text not null check(kind in ('asset','liability','equity','income','expense'))
);
insert into public.accounting_accounts values
 ('cash','Wallet cash','asset'),('inventory_lpg','LPG inventory','asset'),('inventory_stove','Stove inventory','asset'),
 ('inventory_transit','Inventory in transit','asset'),('customer_receivable','Customer receivables','asset'),
 ('bottle_receivable','Returnable cylinders with customers','asset'),('transport_receivable','Transport receivables','asset'),('supplier_receivable','Supplier refunds / advances','asset'),
 ('vehicles','Vehicles','asset'),('equipment','Equipment','asset'),('other_assets','Other assets','asset'),
 ('supplier_payable','Supplier payables','liability'),('employee_payable','Employee salaries and earnings','liability'),
 ('operating_payable','Operating obligations / advances','liability'),('loan_payable','Loans','liability'),('other_liability','Other liabilities','liability'),
 ('opening_equity','Opening equity','equity'),('capital','Additional capital','equity'),('withdrawals','Owner withdrawals','equity'),('equity_adjustment','Other equity adjustments','equity'),
 ('sales_revenue','Product revenue','income'),('commission_revenue','Supplier commissions','income'),('logistics_revenue','External logistics revenue','income'),('other_income','Other income','income'),('disposal_gain','Asset disposal gain / loss','income'),
 ('cogs','Cost of goods sold','expense'),('inventory_loss','Inventory losses','expense'),('employee_expense','Employee costs','expense'),('logistics_expense','Logistics costs','expense'),('vehicle_expense','Vehicle maintenance','expense'),('operating_expense','Operating expenses','expense'),('interest_expense','Interest paid','expense'),('depreciation_expense','Depreciation','expense');
create table public.accounting_periods (
 tenant_id uuid primary key references public.tenants(tenant_id), started_at timestamptz not null default clock_timestamp(),
 opening_note text not null, estimated boolean not null default false
);
create table public.accounting_journals (
 tenant_id uuid not null references public.tenants(tenant_id), journal_id uuid not null default gen_random_uuid(),
 entry_no bigint generated always as identity, occurred_on date not null check(isfinite(occurred_on)),
 source text not null, source_id uuid not null, event_key text not null,
 description text not null, is_opening boolean not null default false, estimated boolean not null default false, created_at timestamptz not null default clock_timestamp(), created_by uuid,
 primary key(tenant_id,journal_id), unique(tenant_id,source,source_id,event_key)
);
create table public.accounting_lines (
 tenant_id uuid not null, journal_id uuid not null, line_no integer not null,
 account text not null references public.accounting_accounts(code), amount numeric(20,2) not null check(amount<>0 and abs(amount)<100000000000000000),
 business_category text not null default 'shared' check(business_category in ('lpg','stove','logistics','shared')),
 entity_id uuid, details jsonb not null default '{}', primary key(tenant_id,journal_id,line_no),
 foreign key(tenant_id,journal_id) references public.accounting_journals(tenant_id,journal_id)
);
create index accounting_period_index on public.accounting_journals(tenant_id,occurred_on,entry_no);
create index accounting_source_index on public.accounting_journals(tenant_id,source,source_id);
create index accounting_account_index on public.accounting_lines(tenant_id,account,business_category,entity_id) include(amount,journal_id);
create table app_private.accounting_source_state (
 tenant_id uuid not null references public.tenants(tenant_id),source text not null,source_id uuid not null,
 lines jsonb not null,revision bigint not null default 0, primary key(tenant_id,source,source_id)
);
create function app_private.require_owner(capability text) returns uuid language plpgsql set search_path='' as $$
declare t uuid:=app_private.require_permission(capability);begin
 if not exists(select 1 from public.user_roles u join public.roles r using(tenant_id,role_id) where u.tenant_id=t and u.user_id=auth.uid() and r.name='OWNER') then
 raise exception 'Only the owner can perform this operation' using errcode='42501';end if;return t;end $$;
create function app_private.accounting_line(code text,value numeric,category text default 'shared',entity uuid default null,details jsonb default '{}') returns jsonb language sql immutable set search_path='' as $$
 select jsonb_build_object('account',code,'amount',round(value,2),'business_category',category,'entity_id',entity,'details',details);$$;
create function app_private.post_journal(t uuid,src text,id uuid,event text,d date,note text,entries jsonb,estimate boolean default false,opening_entry boolean default false) returns uuid language plpgsql set search_path='' as $$
declare jid uuid; total numeric;start_day date;begin
 if jsonb_typeof(entries) is distinct from 'array' then raise exception 'Journal lines are required';end if;
 select coalesce(sum((x->>'amount')::numeric),0) into total from jsonb_array_elements(entries) x;
 if total<>0 then raise exception 'Unbalanced accounting journal: %',total;end if;
 select (started_at at time zone 'Asia/Dhaka')::date into start_day from public.accounting_periods where tenant_id=t;
 if start_day is null then raise exception 'Accounting opening position is missing';end if;
 if d is null or not isfinite(d) or d<start_day then raise exception 'Accounting date precedes the opening position';end if;
 if not exists(select 1 from jsonb_array_elements(entries) x where (x->>'amount')::numeric<>0) then return null;end if;
 insert into public.accounting_journals(tenant_id,source,source_id,event_key,occurred_on,description,estimated,is_opening,created_by)
 values(t,src,id,event,d,note,estimate,opening_entry,case when src='salary_accrual' then null else auth.uid() end) on conflict(tenant_id,source,source_id,event_key) do nothing returning journal_id into jid;
 if jid is null then raise exception 'Accounting event already posted';end if;
 insert into public.accounting_lines(tenant_id,journal_id,line_no,account,amount,business_category,entity_id,details)
 select t,jid,row_number() over()::integer,x->>'account',(x->>'amount')::numeric,coalesce(x->>'business_category','shared'),(x->>'entity_id')::uuid,coalesce(x->'details','{}'::jsonb)
 from jsonb_array_elements(entries) x where (x->>'amount')::numeric<>0;
 return jid;end $$;
create function app_private.check_journal_balance() returns trigger language plpgsql security definer set search_path='' set plan_cache_mode='force_custom_plan' as $$begin
 if coalesce((select sum(amount) from public.accounting_lines where tenant_id=new.tenant_id and journal_id=new.journal_id),0)<>0
 or not exists(select 1 from public.accounting_lines where tenant_id=new.tenant_id and journal_id=new.journal_id) then raise exception 'Journal must contain balanced debit and credit lines';end if;return null;end $$;
create constraint trigger journal_balance after insert on public.accounting_journals deferrable initially deferred for each row execute function app_private.check_journal_balance();
create function app_private.sync_journal(t uuid,src text,id uuid,d date,note text,target jsonb,opening_entry boolean default false) returns void language plpgsql set search_path='' as $$
declare prior app_private.accounting_source_state;delta jsonb;begin
 insert into app_private.accounting_source_state values(t,src,id,'[]',0) on conflict do nothing;
 select * into prior from app_private.accounting_source_state where tenant_id=t and source=src and source_id=id for update;
 with all_lines as(select x,1 sign from jsonb_array_elements(target) x union all select x,-1 from jsonb_array_elements(prior.lines) x),
 grouped as(select x->>'account' account,coalesce(x->>'business_category','shared') category,(x->>'entity_id')::uuid entity,sum(sign*(x->>'amount')::numeric) amount from all_lines group by 1,2,3)
 select coalesce(jsonb_agg(app_private.accounting_line(account,amount,category,entity)) filter(where amount<>0),'[]') into delta from grouped;
 if delta<>'[]' then
 perform app_private.post_journal(t,src,id,(prior.revision+1)::text,greatest(d,(select (started_at at time zone 'Asia/Dhaka')::date from public.accounting_periods where tenant_id=t)),note,delta,false,opening_entry);
 update app_private.accounting_source_state set lines=target,revision=revision+1 where tenant_id=t and source=src and source_id=id;
 end if;end $$;
-- Current cost pools are projections of immutable valuation movements. Four
-- decimals are unnecessary: each full pool consumption takes the exact remainder.
create table public.inventory_costs (
 tenant_id uuid not null,item_id uuid not null,filled_quantity integer not null default 0,empty_quantity integer not null default 0,
 filled_value numeric(20,2) not null default 0,empty_value numeric(20,2) not null default 0,
 empty_unit_cost numeric(16,6),estimated boolean not null default false,
 primary key(tenant_id,item_id),foreign key(tenant_id,item_id) references public.items(tenant_id,item_id),
 check(filled_quantity>=0 and empty_quantity>=0 and filled_value>=0 and empty_value>=0)
);
create table public.inventory_cost_entries (
 tenant_id uuid not null,entry_id uuid not null default gen_random_uuid(),item_id uuid not null,movement_id uuid,
 occurred_on date not null,filled_change integer not null,empty_change integer not null,filled_value numeric(20,2) not null,empty_value numeric(20,2) not null,
 filled_after numeric(20,2) not null,empty_after numeric(20,2) not null,reason text not null,estimated boolean not null default false,
 created_at timestamptz not null default clock_timestamp(),created_by uuid,
 primary key(tenant_id,entry_id),unique(tenant_id,movement_id),foreign key(tenant_id,item_id) references public.items(tenant_id,item_id),
 foreign key(tenant_id,movement_id) references public.inventory_movements(tenant_id,movement_id)
);
create index inventory_cost_history on public.inventory_cost_entries(tenant_id,item_id,occurred_on,created_at);
alter table public.inventory_movements add column valuation jsonb;
-- New assets require recorded book values; existing test vehicles receive labeled
-- opening estimates below. Manual depreciation is an explicit journal operation.
create table public.business_assets (
 tenant_id uuid not null references public.tenants(tenant_id),asset_id uuid not null default gen_random_uuid(),vehicle_id uuid,
 name text not null,kind text not null check(kind in ('vehicles','equipment','other_assets')),cost numeric(16,2) not null check(cost>=0 and cost<1000000000000),
 accumulated_depreciation numeric(16,2) not null default 0 check(accumulated_depreciation>=0),acquired_on date not null,
 valuation_source text not null check(valuation_source in ('verified','estimated_opening')),status text not null default 'active' check(status in ('active','sold','dismantled')),
 revision integer not null default 1,created_by uuid,created_at timestamptz not null default clock_timestamp(),
 primary key(tenant_id,asset_id),unique(tenant_id,vehicle_id),foreign key(tenant_id,vehicle_id) references public.vehicles(tenant_id,vehicle_id),check(accumulated_depreciation<=cost)
);
create table public.asset_activity (
 tenant_id uuid not null,activity_id uuid not null default gen_random_uuid(),asset_id uuid not null,action text not null,occurred_on date not null,details jsonb not null,
 created_at timestamptz not null default clock_timestamp(),created_by uuid,primary key(tenant_id,activity_id),foreign key(tenant_id,asset_id) references public.business_assets(tenant_id,asset_id)
);
create index asset_activity_parent on public.asset_activity(tenant_id,asset_id,created_at desc);
-- One cutover per existing business. Estimates are allowed only in this forward
-- development normalization, never as a default for new business operations.
insert into public.accounting_periods(tenant_id,opening_note,estimated) select tenant_id,'Development opening position: recorded balances and obligations; inventory costs derived from actual receipts where available, otherwise labeled test estimates. Earlier profit is unavailable.',true from public.tenants;
insert into public.inventory_costs(tenant_id,item_id,filled_quantity,empty_quantity,filled_value,empty_value,empty_unit_cost,estimated)
select i.tenant_id,i.item_id,i.filled_quantity,i.empty_quantity,round(i.filled_quantity*coalesce(p.package_cost,p.refill_cost+coalesce(p.package_cost-p.refill_cost,1500),i.size_kg*100+1500),2),
 round(i.empty_quantity*greatest(0,coalesce(p.package_cost-p.refill_cost,1500)),2),greatest(0,coalesce(p.package_cost-p.refill_cost,1500)),true
from public.items i left join lateral(
 select sum(pi.line_total*case when p.subtotal>0 then (p.company_payable+p.labour_cost)/p.subtotal else 1 end) filter(where pi.type='package')/nullif(sum(pi.billed_quantity) filter(where pi.type='package'),0) package_cost,
 sum(pi.line_total*case when p.subtotal>0 then (p.company_payable+p.labour_cost)/p.subtotal else 1 end) filter(where pi.type='refill')/nullif(sum(pi.billed_quantity) filter(where pi.type='refill'),0) refill_cost
 from public.purchase_items pi join public.purchases p using(tenant_id,purchase_id) where pi.tenant_id=i.tenant_id and pi.item_id=i.item_id and p.status='received'
) p on true;
insert into public.business_assets(tenant_id,vehicle_id,name,kind,cost,acquired_on,valuation_source)
select v.tenant_id,v.vehicle_id,v.name,'vehicles',greatest(150000,least(2500000,coalesce(v.capacity,0)*2500)),(a.started_at at time zone 'Asia/Dhaka')::date,'estimated_opening'
from public.vehicles v join public.accounting_periods a using(tenant_id);
-- Generic source recognition keeps mutable obligations auditable by posting only
-- changes. Payments independently settle the same control accounts.
create function app_private.source_accounting() returns trigger language plpgsql set search_path='' as $$
declare t uuid:=new.tenant_id;id uuid;src text;d date:=(clock_timestamp() at time zone 'Asia/Dhaka')::date;a numeric;cat text:='shared';lines jsonb:='[]';begin
 if tg_table_name='sales' then
  id:=new.sale_id;src:='sale';cat:=coalesce(to_jsonb(new)->>'business_category','lpg');a:=case when new.status='completed' then new.total_amount+new.additional_charges else 0 end;
  lines:=jsonb_build_array(app_private.accounting_line('customer_receivable',a,cat,new.customer_id),app_private.accounting_line('sales_revenue',-a,cat));
 elsif tg_table_name='purchases' then
  id:=new.purchase_id;src:='purchase';cat:=coalesce(to_jsonb(new)->>'business_category','lpg');a:=case when new.status in ('in_transit','received') then new.payable_amount else 0 end;
  lines:=jsonb_build_array(app_private.accounting_line('inventory_transit',a,cat,id),app_private.accounting_line('supplier_payable',-a,cat,id));
 elsif tg_table_name='transits' then
  id:=new.transit_id;src:='transit_revenue';cat:='logistics';a:=case when new.purchase_id is null and new.status<>'cancelled' then new.transport_fee else 0 end;
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
-- Seed recognition state, without recognizing old revenue/expenses at cutover.
insert into app_private.accounting_source_state(tenant_id,source,source_id,lines)
select tenant_id,'sale',sale_id,jsonb_build_array(app_private.accounting_line('customer_receivable',total_amount+additional_charges,'lpg',customer_id),app_private.accounting_line('sales_revenue',-total_amount-additional_charges,'lpg')) from public.sales where status='completed'
union all select tenant_id,'purchase',purchase_id,jsonb_build_array(app_private.accounting_line('inventory_transit',payable_amount,'lpg',purchase_id),app_private.accounting_line('supplier_payable',-payable_amount,'lpg',purchase_id)) from public.purchases where status in ('in_transit','received')
union all select tenant_id,'transit_revenue',transit_id,jsonb_build_array(app_private.accounting_line('transport_receivable',transport_fee,'logistics',transit_id),app_private.accounting_line('logistics_revenue',-transport_fee,'logistics')) from public.transits where purchase_id is null and status<>'cancelled';
create function app_private.account_wallet() returns trigger language plpgsql set search_path='' as $$
declare other text;entity uuid:=new.reference_id;cat text:='shared';ep public.employee_payments;begin
 if new.type in ('pos_sale_income','customer_collection','sale_refund') then other:='customer_receivable';
  select customer_id,coalesce(to_jsonb(s)->>'business_category','lpg') into entity,cat from public.sales s where tenant_id=new.tenant_id and sale_id=new.reference_id;
 elsif new.type like 'purchase%' then other:='supplier_payable';select coalesce(to_jsonb(p)->>'business_category','lpg') into cat from public.purchases p where tenant_id=new.tenant_id and purchase_id=new.reference_id;
 elsif new.type like 'payroll_%' then
  select p.* into ep from public.employee_payment_entries e join public.employee_payments p using(tenant_id,payment_id) where e.tenant_id=new.tenant_id and e.entry_id=new.employee_entry_id;
  other:='employee_payable';entity:=case when ep.kind='trips' then ep.transit_id else ep.employee_id end;cat:=case when ep.kind='trips' then 'logistics' else 'shared' end;
 elsif new.type like 'transit_client_%' then other:='transport_receivable';cat:='logistics';
 elsif new.type in ('transit_expense','transit_expense_return','vehicle_service_expense','vehicle_service_expense_return') then other:='operating_payable';cat:='logistics';
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
-- Build the opening from existing balance evidence, not historical payment sums
-- claimed to be complete. Control accounts retain source IDs for reconciliation.
do $$ declare t record;r record;component record;entries jsonb;total numeric;start_day date;amt numeric;begin
 for t in select * from public.accounting_periods loop
  start_day:=(t.started_at at time zone 'Asia/Dhaka')::date;entries:='[]';
  for r in select wallet_id,balance from public.wallets where tenant_id=t.tenant_id loop entries:=entries||jsonb_build_array(app_private.accounting_line('cash',r.balance,'shared',r.wallet_id));end loop;
  for r in select * from public.inventory_costs where tenant_id=t.tenant_id loop
   entries:=entries||jsonb_build_array(app_private.accounting_line('inventory_lpg',r.filled_value+r.empty_value,'lpg',r.item_id));
   insert into public.inventory_cost_entries(tenant_id,item_id,occurred_on,filled_change,empty_change,filled_value,empty_value,filled_after,empty_after,reason,estimated)
   values(t.tenant_id,r.item_id,start_day,r.filled_quantity,r.empty_quantity,r.filled_value,r.empty_value,r.filled_value,r.empty_value,'Reconstructed development opening stock',true);
  end loop;
  for r in select c.customer_id,-coalesce(sum(x.amount),0) due from public.customers c left join public.customer_transactions x using(tenant_id,customer_id) where c.tenant_id=t.tenant_id group by c.customer_id loop
   entries:=entries||jsonb_build_array(app_private.accounting_line('customer_receivable',r.due,'shared',r.customer_id));end loop;
  for r in select * from public.purchases where tenant_id=t.tenant_id and status in ('in_transit','received','cancelled') loop
   if r.status='cancelled' then amt:=-r.refund_due;else amt:=r.payable_amount-r.paid_amount;end if;
   entries:=entries||jsonb_build_array(app_private.accounting_line('supplier_payable',-amt,'lpg',r.purchase_id));
   if r.status='in_transit' then
    entries:=entries||jsonb_build_array(app_private.accounting_line('inventory_transit',r.payable_amount,'lpg',r.purchase_id,jsonb_build_object('component','invoice')));
    for component in select m.item_id,-sum(m.empty_quantity_change) quantity,-sum(m.empty_quantity_change*c.empty_unit_cost) value from public.inventory_movements m join public.inventory_costs c using(tenant_id,item_id) where m.tenant_id=t.tenant_id and m.reference_id=r.purchase_id and m.reference_type='purchase_dispatch' group by m.item_id loop
     entries:=entries||jsonb_build_array(app_private.accounting_line('inventory_transit',component.value,'lpg',r.purchase_id,jsonb_build_object('component','dispatched_cylinder','item_id',component.item_id,'quantity',component.quantity)));
    end loop;
   end if;
  end loop;
  for r in select s.sale_id,greatest(0,coalesce(e.qty,0)-coalesce(receipts.qty,0)) outstanding,coalesce(e.value/nullif(e.qty,0),0) unit_cost from public.sales s
  left join lateral(select sum(si.quantity) qty,sum(si.quantity*c.empty_unit_cost) value from public.sale_items si join public.inventory_costs c using(tenant_id,item_id) where si.tenant_id=s.tenant_id and si.sale_id=s.sale_id and si.type='empty_return') e on true
  left join lateral(select sum(quantity) qty from public.sale_bottle_receipt_lines where tenant_id=s.tenant_id and sale_id=s.sale_id) receipts on true where s.tenant_id=t.tenant_id and s.status='completed' loop
   entries:=entries||jsonb_build_array(app_private.accounting_line('bottle_receivable',r.outstanding*r.unit_cost,'lpg',r.sale_id));end loop;
  for r in select * from public.business_assets where tenant_id=t.tenant_id loop entries:=entries||jsonb_build_array(app_private.accounting_line(r.kind,r.cost-r.accumulated_depreciation,'shared',r.asset_id));end loop;
  for r in select * from public.transits where tenant_id=t.tenant_id loop
   if r.purchase_id is null then entries:=entries||jsonb_build_array(app_private.accounting_line('transport_receivable',case when r.status='cancelled' then 0 else r.transport_fee end-app_private.transit_client_paid(t.tenant_id,r.transit_id),'logistics',r.transit_id));end if;
   entries:=entries||jsonb_build_array(app_private.accounting_line('employee_payable',-r.driver_cost-r.helper_cost+app_private.transit_employee_paid(t.tenant_id,r.transit_id),'logistics',r.transit_id),
   app_private.accounting_line('operating_payable',-(r.total_cost-r.driver_cost-r.helper_cost)+app_private.transit_operating_paid(t.tenant_id,r.transit_id),'logistics',r.transit_id));
  end loop;
  for r in select s.*,app_private.service_paid(s.tenant_id,s.service_trip_id) paid from public.vehicle_service_trips s where tenant_id=t.tenant_id loop
   select coalesce(sum(amount),0) into amt from public.operating_cost_events where tenant_id=t.tenant_id and service_trip_id=r.service_trip_id;
   entries:=entries||jsonb_build_array(app_private.accounting_line('operating_payable',r.paid-amt,'logistics',r.service_trip_id));end loop;
  for r in select * from public.employees where tenant_id=t.tenant_id loop
   select coalesce(sum((app_private.employee_month_balance(t.tenant_id,r.employee_id,m::date)->>'outstanding')::numeric),0) into amt
   from generate_series(date_trunc('month',(select min(effective_from) from public.employee_terms where tenant_id=t.tenant_id and employee_id=r.employee_id)::timestamp),date_trunc('month',start_day::timestamp),'1 month') m;
   entries:=entries||jsonb_build_array(app_private.accounting_line('employee_payable',-amt,'shared',r.employee_id));
   select coalesce(sum(case when p.reversal_of is null then p.amount else -p.amount end),0) into amt from public.employee_payments p join public.employee_salary_months m using(tenant_id,salary_month_id) where p.tenant_id=t.tenant_id and p.employee_id=r.employee_id and m.period>date_trunc('month',start_day)::date;
   entries:=entries||jsonb_build_array(app_private.accounting_line('employee_payable',amt,'shared',r.employee_id));
  end loop;
  select coalesce(sum((x->>'amount')::numeric),0) into total from jsonb_array_elements(entries) x;
  entries:=entries||jsonb_build_array(app_private.accounting_line('opening_equity',-total));
  perform app_private.post_journal(t.tenant_id,'opening',t.tenant_id,'initial',start_day,t.opening_note,entries,true,true);
 end loop;end $$;
create trigger accounting_sale after insert or update of status,total_amount,additional_charges on public.sales for each row execute function app_private.source_accounting();
create trigger accounting_purchase after insert or update of status,payable_amount on public.purchases for each row execute function app_private.source_accounting();
create trigger accounting_transit after insert or update of status,transport_fee on public.transits for each row execute function app_private.source_accounting();

create trigger accounting_bonus after insert on public.employee_payments for each row execute function app_private.source_accounting();
create trigger accounting_operating after insert on public.operating_cost_events for each row execute function app_private.source_accounting();
create trigger accounting_wallet after insert on public.wallet_transactions for each row execute function app_private.account_wallet();
-- New tenants start with a verified zero position.
create function app_private.accounting_business_created() returns trigger language plpgsql set search_path='' as $$begin
 insert into public.accounting_periods(tenant_id,opening_note) values(new.tenant_id,'New business: zero opening position');return new;end $$;
create trigger aa_accounting_created after insert on public.tenants for each row execute function app_private.accounting_business_created();
set constraints all immediate;
-- Security: no browser table writes, including privileged source projections.
do $$ declare n text;begin
 foreach n in array array['accounting_accounts','accounting_periods','accounting_journals','accounting_lines','inventory_costs','inventory_cost_entries','business_assets','asset_activity'] loop
  execute format('alter table public.%I enable row level security',n);
  execute format('revoke all on public.%I from public,anon,authenticated',n);
  if n not in ('inventory_costs','business_assets','accounting_accounts','accounting_periods') then
   execute format('create trigger accounting_immutable before update or delete on public.%I for each row execute function app_private.immutable_finance_record()',n);end if;
 end loop;
 revoke all on app_private.accounting_source_state from public,anon,authenticated;
end $$;
