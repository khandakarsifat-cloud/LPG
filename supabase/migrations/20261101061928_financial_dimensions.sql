-- Type identifies the event; account fixes recognition; business owns the value.
-- Existing amounts/source IDs survive this forward development normalization.
create function app_private.valid_business_allocation(a jsonb) returns boolean
language sql immutable set search_path='' as $$
 select case when jsonb_typeof(a)='object' then
  (select count(*) between 1 and 3 and bool_and(key in ('lpg','stove','logistics') and jsonb_typeof(value)='number'
    and value::text::numeric>0 and value::text::numeric<=100 and round(value::text::numeric,4)=value::text::numeric)
    and sum(value::text::numeric)=100 from jsonb_each(a)) else false end;$$;

-- Split cumulative rounded boundaries: exact cents, deterministic, sign symmetric.
create function app_private.allocate_money(value numeric,a jsonb)
returns table(business text,amount numeric) language plpgsql immutable set search_path='' as $$begin
 if not coalesce(app_private.valid_business_allocation(a),false) then raise exception 'Business percentages must total 100';end if;
 return query with weights as(select j.key k,j.value::text::numeric p from jsonb_each(a)j), boundaries as(
 select k,p,sum(p) over(order by k) boundary from weights)
 select k,round(value*boundary/100,2)-round(value*(boundary-p)/100,2) from boundaries order by k;
end $$;

create table public.financial_types(
 type_id uuid primary key default gen_random_uuid(),tenant_id uuid references public.tenants(tenant_id),
 code text unique,name text not null check(length(trim(name)) between 1 and 80),
 origin text not null check(origin in ('system','custom')),account text references public.accounting_accounts(code),
 allocations jsonb not null default '{"lpg":100}' check(app_private.valid_business_allocation(allocations)),
 is_active boolean not null default true,revision integer not null default 1,
 check((origin='system' and tenant_id is null and code is not null and account is null) or
       (origin='custom' and tenant_id is not null and code is null and account is not null)),
 unique(tenant_id,name)
);
alter table public.financial_types enable row level security;
revoke all on public.financial_types from public,anon,authenticated;
create index financial_types_tenant on public.financial_types(tenant_id,type_id);

insert into public.financial_types(type_id,code,name,origin,allocations)
select md5('lpg:type:'||code)::uuid,code,name,'system',jsonb_build_object(business,100)
from(values
 ('sale','Product invoice / correction','lpg'),('pos_sale_income','POS payment','lpg'),
 ('customer_collection','Customer collection','lpg'),('sale_refund','Customer refund','lpg'),
 ('sale_reversal','Sale cancellation','lpg'),('purchase','Purchase invoice / correction','lpg'),
 ('purchase_payment','Purchase payment','lpg'),('purchase_payment_company','Purchase company payment','lpg'),
 ('purchase_payment_labour','Purchase labour payment','lpg'),('purchase_refund','Purchase refund','lpg'),
 ('purchase_receipt','FIFO purchase receipt','lpg'),('purchase_dispatch','Empty-shell dispatch','lpg'),
 ('purchase_cancellation','Purchase dispatch return','lpg'),('stove_purchase_cancellation','Stove purchase return','stove'),
 ('inventory_sale','FIFO sale cost','lpg'),('inventory_return','FIFO sale return','lpg'),
 ('bottle_obligation','Customer shell asset','lpg'),('bottle_return','Bottle collection','lpg'),
 ('inventory_opening','Opening stock','lpg'),('inventory_capital','Contributed stock','lpg'),
 ('inventory_gain','Stock gain','lpg'),('inventory_loss','Stock loss / damage','lpg'),
 ('monthly_commission','Monthly earned LPG commission','lpg'),('commission_reversal','Commission reversal','lpg'),
 ('commission_receipt','Commission settlement','lpg'),('transit_revenue','External transport invoice','logistics'),
 ('transit_client_receipt','External transport collection','logistics'),('transit_client_refund','External transport refund','logistics'),
 ('internal_transport','Internal purchase transport','logistics'),('internal_transport_payment','Internal transport payment','lpg'),
 ('internal_transport_receipt','Internal transport received','logistics'),('internal_transport_return','Internal transport returned','logistics'),
 ('internal_inventory','Internal transport in FIFO stock','lpg'),('internal_cogs','Internal transport FIFO cost','lpg'),
 ('transit_diesel','Transit diesel','logistics'),('transit_driver','Transit driver earnings','logistics'),
 ('transit_helper','Transit helper earnings','logistics'),('operating_cost','Transit operating cost','logistics'),
 ('vehicle_service','Vehicle service incurred','logistics'),('transit_expense','Transit expense payment','logistics'),
 ('transit_expense_return','Transit expense returned','logistics'),('vehicle_service_expense','Vehicle service payment','logistics'),
 ('vehicle_service_expense_return','Vehicle service funds returned','logistics'),
 ('salary_accrual','Contract salary','lpg'),('bonus','Named employee bonus','lpg'),
 ('payroll_salary','Salary payment / advance','lpg'),('payroll_bonus','Bonus payment','lpg'),
 ('payroll_trips','Driver / helper payment','logistics'),('payroll_reversal','Employee funds returned','lpg'),
 ('opening','Opening balances','lpg'),('opening_cash','Opening cash','lpg'),('owner_capital','Owner investment','lpg'),
 ('capital','Capital contribution','lpg'),('balance_adjustment','Wallet correction','lpg'),
 ('business_spending','Operating expense','lpg'),('owner_withdrawal','Owner withdrawal','lpg'),
 ('wallet_transfer','Wallet / business transfer','lpg'),('loan_create','Loan recognition','lpg'),
 ('loan_receipt','Loan receipt','lpg'),('loan_repayment','Loan principal repayment','lpg'),
 ('opening_entry','Opening asset / liability','lpg'),('expense_accrue','Unpaid operating expense','lpg'),
 ('obligation_settlement','Recorded balance settlement','lpg'),('asset_register','Asset acquisition','lpg'),
 ('asset_purchase','Asset payment','lpg'),('asset_depreciate','Asset depreciation','lpg'),
 ('asset_dispose','Asset disposal','lpg'),('asset_proceeds','Asset disposal proceeds','lpg'),
 ('asset_disposal_expense','Asset disposal cost','lpg'),('asset_improve','Asset improvement','lpg')
)v(code,name,business);

insert into public.accounting_accounts values
 ('business_allocation_equity','Business allocation of equity','equity'),
 ('internal_logistics_revenue','Internal transport revenue','income'),
 ('retained_earnings','Supported opening accumulated earnings','equity');

alter table public.accounting_lines add column type_id uuid references public.financial_types(type_id);
alter table public.accounting_lines add column consolidated_amount numeric(20,2);
alter table public.wallet_transactions add column allocations jsonb;
alter table public.wallet_transactions add column type_id uuid references public.financial_types(type_id);
alter table public.wallet_transactions add column business_balance_after jsonb;
alter table public.wallets add column business_balances jsonb not null default '{"lpg":0,"stove":0,"logistics":0}';
alter table public.business_assets add column allocations jsonb not null default '{"lpg":100}' check(app_private.valid_business_allocation(allocations));
alter table public.loans add column allocations jsonb not null default '{"lpg":100}' check(app_private.valid_business_allocation(allocations));
alter table public.finance_obligations add column allocations jsonb not null default '{"lpg":100}' check(app_private.valid_business_allocation(allocations));
alter table public.employees add column business_allocations jsonb not null default '{"lpg":100}' check(app_private.valid_business_allocation(business_allocations));
update public.business_assets set allocations='{"logistics":100}' where vehicle_id is not null or kind='vehicles';
update public.employees set business_allocations='{"logistics":100}' where business_unit='truck_business';
create table app_private.salary_business_allocations(
 tenant_id uuid not null,source_id uuid not null,employee_id uuid not null,allocations jsonb not null check(app_private.valid_business_allocation(allocations)),
 primary key(tenant_id,source_id),foreign key(tenant_id,employee_id) references public.employees(tenant_id,employee_id)
);
alter table app_private.salary_business_allocations enable row level security;
alter table app_private.salary_business_allocations owner to postgres;
revoke all on app_private.salary_business_allocations from public,anon,authenticated;
insert into app_private.salary_business_allocations
select s.tenant_id,s.source_id,e.employee_id,e.business_allocations from app_private.accounting_source_state s
join public.employees e on e.tenant_id=s.tenant_id and e.employee_id=(select (x->>'entity_id')::uuid from jsonb_array_elements(s.lines)x where x->>'account'='employee_payable' limit 1)
where s.source='salary_accrual';
create function app_private.employee_business_default() returns trigger language plpgsql set search_path='' as $$begin
 if tg_op='INSERT' and new.business_unit='truck_business' and new.business_allocations='{"lpg":100}' then new.business_allocations:='{"logistics":100}';end if;return new;end $$;
create trigger employee_business_default before insert on public.employees for each row execute function app_private.employee_business_default();
do $$declare s text;begin s:=pg_get_functiondef('app_private.sync_payroll(uuid,boolean)'::regprocedure);
 s:=replace(s,'amount:=(app_private.employee_month_balance',
 'insert into app_private.salary_business_allocations select t,id,employee_id,business_allocations from public.employees where tenant_id=t and employee_id=r.employee_id on conflict do nothing;amount:=(app_private.employee_month_balance');execute s;end $$;

create function app_private.system_type(code text) returns uuid language sql stable set search_path='' as $$
 select type_id from public.financial_types t where t.code=$1 and origin='system';$$;

create function app_private.source_type(t uuid,src text,id uuid,account text default null) returns uuid
language plpgsql stable set search_path='' as $$declare c text:=src;m public.inventory_movements;e public.operating_cost_events;begin
 if src='wallet' then select type into c from public.wallet_transactions where tenant_id=t and transaction_id=id;
 elsif src='inventory' then
  select * into m from public.inventory_movements where tenant_id=t and movement_id=id;
  c:=case when account='supplier_receivable' then 'monthly_commission'
   when m.reference_type in ('purchase_receipt_refill','purchase_receipt_package','stove_purchase_receipt') then 'purchase_receipt'
   when m.reference_type='purchase_dispatch' then 'purchase_dispatch' when m.reference_type='purchase_cancellation' then 'purchase_cancellation'
   when m.reference_type='stove_purchase_cancellation' then 'stove_purchase_cancellation'
   when m.reference_type='sale_reversal' then 'inventory_return'
   when m.reference_type='sale' then case when m.filled_quantity_change>0 or m.empty_quantity_change>0 then 'bottle_return' else 'inventory_sale' end
   when m.valuation->>'counter_account'='opening_equity' then 'inventory_opening'
   when m.valuation->>'counter_account'='capital' then 'inventory_capital'
   when m.filled_quantity_change<0 or m.empty_quantity_change<0 then 'inventory_loss' else 'inventory_gain' end;
 elsif src='operating_cost' then
  select * into e from public.operating_cost_events where tenant_id=t and event_id=id;
  c:=case when e.service_trip_id is not null then 'vehicle_service' when lower(e.category)='driver earnings' then 'transit_driver'
   when lower(e.category)='helper earnings' then 'transit_helper' when lower(e.category) in ('diesel','oil','fuel') then 'transit_diesel' else 'operating_cost' end;
 elsif src='development_opening' then c:='opening';
 elsif src='owner_operation' then
  select coalesce(payload->'body'->>'action',payload->>'action') into c from public.finance_requests where tenant_id=t and request_id=id;
  c:=coalesce(c,case when account='depreciation_expense' then 'asset_depreciate' else 'opening_entry' end);
 elsif src='salary' then c:='salary_accrual';
 end if;
 return app_private.system_type(c);
end $$;

-- Recover deterministic ownership from original settlement sources before
-- classifying formerly shared cash/counterpart lines. This helper exists only
-- for this forward metadata normalization; it is not a runtime fallback.
create function app_private.historical_wallet_allocation(x public.wallet_transactions) returns jsonb language plpgsql stable set search_path='' as $$declare a jsonb;begin
 if x.type in ('loan_receipt','loan_repayment') then select allocations into a from public.loans where tenant_id=x.tenant_id and loan_id=x.reference_id;
 elsif x.type like 'asset_%' then select allocations into a from public.business_assets where tenant_id=x.tenant_id and asset_id=x.reference_id;
 elsif x.type='obligation_settlement' then select allocations into a from public.finance_obligations where tenant_id=x.tenant_id and obligation_id=x.reference_id;
 elsif x.type like 'payroll_%' then select case when p.kind='trips' then '{"logistics":100}'::jsonb else e.business_allocations end into a from public.employee_payment_entries pe join public.employee_payments p using(tenant_id,payment_id) join public.employees e using(tenant_id,employee_id) where pe.tenant_id=x.tenant_id and pe.entry_id=x.employee_entry_id;
 elsif x.type like 'transit_%' or x.type like 'vehicle_service_%' then a:='{"logistics":100}';
 elsif x.type like 'purchase%' then select jsonb_build_object(business_category,100) into a from public.purchases where tenant_id=x.tenant_id and purchase_id=x.reference_id;
 elsif x.type in ('pos_sale_income','customer_collection','sale_refund') then select jsonb_build_object(business_category,100) into a from public.sales where tenant_id=x.tenant_id and sale_id=x.reference_id;
 elsif x.type in ('business_spending','owner_withdrawal') then select case when lower(category_name)='logistics' then '{"logistics":100}'::jsonb else '{"lpg":100}'::jsonb end into a from public.spendings where tenant_id=x.tenant_id and spending_id=x.reference_id;
 end if;return coalesce(a,'{"lpg":100}'::jsonb);end $$;
alter table public.wallet_transactions disable trigger immutable_wallet_entry;
update public.wallet_transactions x set allocations=app_private.historical_wallet_allocation(x);
alter table public.wallet_transactions enable trigger immutable_wallet_entry;
drop function app_private.historical_wallet_allocation(public.wallet_transactions);

create function app_private.source_allocation(t uuid,src text,id uuid) returns jsonb
language plpgsql stable set search_path='' as $$declare a jsonb;ref uuid;p public.employee_payments;begin
 if src='salary_accrual' then select allocations into a from app_private.salary_business_allocations where tenant_id=t and source_id=id;
 elsif src='bonus' then select e.business_allocations into a from public.employee_payments x join public.employees e using(tenant_id,employee_id) where x.tenant_id=t and x.payment_id=id;
 elsif src='development_opening' then a:='{"logistics":100}';
 elsif src='owner_operation' then
  select coalesce(ba.allocations,lo.allocations,ob.allocations) into a from public.finance_requests r
  left join public.business_assets ba on ba.tenant_id=t and ba.asset_id=(r.result->>'id')::uuid
  left join public.loans lo on lo.tenant_id=t and lo.loan_id=(r.result->>'id')::uuid
  left join public.finance_obligations ob on ob.tenant_id=t and ob.obligation_id=(r.result->>'id')::uuid where r.tenant_id=t and r.request_id=id;
 elsif src='wallet' then
  select allocations into a from public.wallet_transactions where tenant_id=t and transaction_id=id;
 end if;
 return coalesce(a,'{"lpg":100}'::jsonb);
end $$;

-- Central normalization also applies to source-state targets, so later deltas
-- compare retained business allocations rather than drifting type defaults.
create function app_private.dimension_entries(t uuid,src text,id uuid,entries jsonb) returns jsonb
language plpgsql stable set search_path='' as $$declare result jsonb;begin
 select coalesce(jsonb_agg(x || jsonb_build_object('amount',s.amount,'consolidated_amount',s.consolidated_amount,
  'business_category',s.business,'type_id',coalesce((x->>'type_id')::uuid,app_private.source_type(t,src,id,x->>'account')))),'[]') into result
 from jsonb_array_elements(entries)x cross join lateral(
 select a.business,a.amount,c.amount consolidated_amount from app_private.allocate_money((x->>'amount')::numeric,
  case when coalesce(x->>'business_category','shared')='shared' then coalesce(x->'allocations',app_private.source_allocation(t,src,id)) else jsonb_build_object(x->>'business_category',100) end)a
 join app_private.allocate_money(coalesce((x->>'consolidated_amount')::numeric,(x->>'amount')::numeric),
  case when coalesce(x->>'business_category','shared')='shared' then coalesce(x->'allocations',app_private.source_allocation(t,src,id)) else jsonb_build_object(x->>'business_category',100) end)c using(business)
 )s where s.amount<>0;
 return result;
end $$;

create or replace function app_private.post_journal(t uuid,src text,id uuid,event text,d date,note text,entries jsonb,estimate boolean default false,opening_entry boolean default false)
returns uuid language plpgsql set search_path='' as $$declare jid uuid;start_day date;begin
 if jsonb_typeof(entries) is distinct from 'array' then raise exception 'Journal lines are required';end if;
 entries:=app_private.dimension_entries(t,src,id,entries);
 if exists(select 1 from jsonb_array_elements(entries)x where x->>'type_id' is null) then raise exception 'Unclassified accounting source: %',src;end if;
 if (select coalesce(sum((x->>'amount')::numeric),0)<>0 or coalesce(sum((x->>'consolidated_amount')::numeric),0)<>0 from jsonb_array_elements(entries)x) then
 raise exception 'Unbalanced accounting journal (%): business %, consolidated %',src,(select sum((x->>'amount')::numeric) from jsonb_array_elements(entries)x),(select sum((x->>'consolidated_amount')::numeric) from jsonb_array_elements(entries)x);end if;
 if not exists(select 1 from jsonb_array_elements(entries)) then return null;end if;
 select (started_at at time zone 'Asia/Dhaka')::date into start_day from public.accounting_periods where tenant_id=t;
 if start_day is null then raise exception 'Accounting opening position is missing';end if;
 if d is null or not isfinite(d) then raise exception 'A finite accounting date is required';end if;
 if d<start_day then update public.accounting_periods set started_at=d::timestamp at time zone 'Asia/Dhaka' where tenant_id=t;end if;
 insert into public.accounting_journals(tenant_id,source,source_id,event_key,occurred_on,description,estimated,is_opening,created_by)
 values(t,src,id,event,d,note,estimate,opening_entry,case when src='salary_accrual' then null else auth.uid() end) returning journal_id into jid;
 insert into public.accounting_lines(tenant_id,journal_id,line_no,account,amount,consolidated_amount,business_category,entity_id,details,type_id)
 select t,jid,n::integer,x->>'account',(x->>'amount')::numeric,(x->>'consolidated_amount')::numeric,x->>'business_category',(x->>'entity_id')::uuid,coalesce(x->'details','{}'),(x->>'type_id')::uuid
 from jsonb_array_elements(entries) with ordinality a(x,n);
 return jid;end $$;

create or replace function app_private.sync_journal(t uuid,src text,id uuid,d date,note text,target jsonb,opening_entry boolean default false)
returns void language plpgsql set search_path='' as $$declare prior app_private.accounting_source_state;delta jsonb;begin
 target:=app_private.dimension_entries(t,src,id,target);
 insert into app_private.accounting_source_state values(t,src,id,'[]',0) on conflict do nothing;
 select * into prior from app_private.accounting_source_state where tenant_id=t and source=src and source_id=id for update;
 with all_lines as(select x,1 sign from jsonb_array_elements(target)x union all select x,-1 from jsonb_array_elements(prior.lines)x),
 grouped as(select x->>'account' account,x->>'business_category' category,(x->>'entity_id')::uuid entity,(x->>'type_id')::uuid type_id,
  sum(sign*(x->>'amount')::numeric) amount,sum(sign*coalesce((x->>'consolidated_amount')::numeric,(x->>'amount')::numeric)) consolidated_amount from all_lines group by 1,2,3,4)
 select coalesce(jsonb_agg(app_private.accounting_line(account,amount,category,entity)||jsonb_build_object('type_id',type_id,'consolidated_amount',consolidated_amount)) filter(where amount<>0),'[]') into delta from grouped;
 if delta<>'[]' then perform app_private.post_journal(t,src,id,(prior.revision+1)::text,d,note,delta,false,opening_entry);
 update app_private.accounting_source_state set lines=target,revision=revision+1 where tenant_id=t and source=src and source_id=id;end if;
end $$;

-- Normalize only dimensional metadata of existing development evidence. Values,
-- source identities and dates are not reset or absorbed into a baseline.
alter table public.accounting_lines disable trigger accounting_immutable;
do $$declare r record;entries jsonb;begin
 for r in select * from public.accounting_journals order by tenant_id,entry_no loop
  select jsonb_agg(app_private.accounting_line(account,amount,business_category,entity_id,details)) into entries from public.accounting_lines where tenant_id=r.tenant_id and journal_id=r.journal_id;
  entries:=app_private.dimension_entries(r.tenant_id,r.source,r.source_id,entries);
  delete from public.accounting_lines where tenant_id=r.tenant_id and journal_id=r.journal_id;
  insert into public.accounting_lines(tenant_id,journal_id,line_no,account,amount,consolidated_amount,business_category,entity_id,details,type_id)
  select r.tenant_id,r.journal_id,n::integer,x->>'account',(x->>'amount')::numeric,(x->>'consolidated_amount')::numeric,x->>'business_category',(x->>'entity_id')::uuid,x->'details',(x->>'type_id')::uuid from jsonb_array_elements(entries) with ordinality a(x,n);
 end loop;
end $$;
alter table public.accounting_lines enable trigger accounting_immutable;
update app_private.accounting_source_state set lines=app_private.dimension_entries(tenant_id,source,source_id,lines);
alter table public.accounting_lines alter column type_id set not null;
alter table public.accounting_lines alter column consolidated_amount set not null;
alter table public.accounting_lines drop constraint accounting_lines_business_category_check;
alter table public.accounting_lines add check(business_category in ('lpg','stove','logistics'));
create index accounting_type_history on public.accounting_lines(tenant_id,type_id,business_category,account,journal_id) include(amount,consolidated_amount,entity_id);

-- A type from another tenant cannot be attached even by an incorrect privileged
-- source function. Public clients cannot insert financial evidence directly.
create function app_private.check_line_dimensions() returns trigger language plpgsql set search_path='' as $$begin
 if not exists(select 1 from public.financial_types t where t.type_id=new.type_id and (t.tenant_id is null or t.tenant_id=new.tenant_id)) then raise exception 'Financial type belongs to another business';end if;
 return new;end $$;
create trigger check_line_dimensions before insert on public.accounting_lines for each row execute function app_private.check_line_dimensions();

create or replace function app_private.check_journal_balance() returns trigger language plpgsql security definer set search_path='' set plan_cache_mode='force_custom_plan' as $$begin
 if not exists(select 1 from public.accounting_lines where tenant_id=new.tenant_id and journal_id=new.journal_id)
 or (select sum(amount)<>0 or sum(consolidated_amount)<>0 from public.accounting_lines where tenant_id=new.tenant_id and journal_id=new.journal_id) then raise exception 'Journal must contain balanced business and consolidated values';end if;return null;end $$;

-- Wallet allocation is fixed before balance posting. Source-specific inference
-- covers every system settlement; explicit allocations are supplied by owner
-- commands and transfers. Returns retain the originating allocation.
create function app_private.wallet_dimensions() returns trigger language plpgsql set search_path='' as $$declare cat text;a jsonb;p public.employee_payments;begin
 if new.type_id is null then new.type_id:=app_private.system_type(new.type);end if;
 if new.allocations is null then
  if new.type in ('pos_sale_income','customer_collection','sale_refund') then select jsonb_build_object(business_category,100) into a from public.sales where tenant_id=new.tenant_id and sale_id=new.reference_id;
  elsif new.type like 'purchase%' then select jsonb_build_object(business_category,100) into a from public.purchases where tenant_id=new.tenant_id and purchase_id=new.reference_id;
  elsif new.type like 'payroll_%' then
   select ep.* into p from public.employee_payment_entries e join public.employee_payments ep using(tenant_id,payment_id) where e.tenant_id=new.tenant_id and e.entry_id=new.employee_entry_id;
   if p.kind='trips' then a:='{"logistics":100}';else select business_allocations into a from public.employees where tenant_id=new.tenant_id and employee_id=p.employee_id;end if;
  elsif new.type like 'transit_%' or new.type like 'vehicle_service_%' or new.type in ('internal_transport_receipt','internal_transport_return') then a:='{"logistics":100}';
  elsif new.type in ('loan_receipt','loan_repayment') then select allocations into a from public.loans where tenant_id=new.tenant_id and loan_id=new.reference_id;
  elsif new.type like 'asset_%' then select allocations into a from public.business_assets where tenant_id=new.tenant_id and asset_id=new.reference_id;
  elsif new.type='obligation_settlement' then select allocations into a from public.finance_obligations where tenant_id=new.tenant_id and obligation_id=new.reference_id;
  end if;
  new.allocations:=coalesce(a,'{"lpg":100}'::jsonb);
 end if;
 if new.type_id is null or not coalesce(app_private.valid_business_allocation(new.allocations),false) then raise exception 'Wallet type and business allocation are required';end if;
 return new;end $$;
create trigger aa_wallet_dimensions before insert on public.wallet_transactions for each row execute function app_private.wallet_dimensions();

alter table public.wallet_transactions disable trigger immutable_wallet_entry;
update public.wallet_transactions x set type_id=app_private.system_type(x.type),allocations=coalesce(
 (select jsonb_object_agg(l.business_category,100*abs(l.amount)/abs(x.amount)) from public.accounting_journals j join public.accounting_lines l using(tenant_id,journal_id) where j.tenant_id=x.tenant_id and j.source='wallet' and j.source_id=x.transaction_id and l.account='cash'),'{"lpg":100}'::jsonb);
alter table public.wallet_transactions enable trigger immutable_wallet_entry;
alter table public.wallet_transactions alter column type_id set not null;
alter table public.wallet_transactions alter column allocations set not null;
alter table public.wallet_transactions add check(app_private.valid_business_allocation(allocations));

update public.wallets w set business_balances=jsonb_build_object('lpg',coalesce((select sum(amount) from public.accounting_lines where tenant_id=w.tenant_id and account='cash' and entity_id=w.wallet_id and business_category='lpg'),0),
 'stove',coalesce((select sum(amount) from public.accounting_lines where tenant_id=w.tenant_id and account='cash' and entity_id=w.wallet_id and business_category='stove'),0),
 'logistics',coalesce((select sum(amount) from public.accounting_lines where tenant_id=w.tenant_id and account='cash' and entity_id=w.wallet_id and business_category='logistics'),0));
alter table public.wallets add check(jsonb_typeof(business_balances)='object' and business_balances ?& array['lpg','stove','logistics'] and
 (business_balances->>'lpg')::numeric+(business_balances->>'stove')::numeric+(business_balances->>'logistics')::numeric=balance);

-- Extend the established row-locking posting path; no second cash ledger.
do $$declare s text;begin
 s:=pg_get_functiondef('app_private.post_wallet_entry()'::regprocedure);
 s:=replace(s,'set balance=balance+new.amount,updated_at=clock_timestamp()',
 'set balance=balance+new.amount,business_balances=(select jsonb_object_agg(b.business,coalesce((business_balances->>b.business)::numeric,0)+b.amount) from (select k business,coalesce(a.amount,0) amount from unnest(array[''lpg'',''stove'',''logistics''])k left join app_private.allocate_money(new.amount,new.allocations)a on a.business=k)b),updated_at=clock_timestamp()');
 s:=replace(s,'returning balance into new.balance_after','returning balance,business_balances into new.balance_after,new.business_balance_after');execute s;
 s:=pg_get_functiondef('app_private.account_wallet()'::regprocedure);
 s:=replace(s,'elsif new.type=''wallet_transfer'' then other:=''other_assets'';entity:=new.operation_id;',
 'elsif new.type=''wallet_transfer'' then other:=''business_allocation_equity'';entity:=new.operation_id;');
 s:=replace(s,'if other is null then','cat:=''shared''; if other is null then');
 s:=replace(s,'app_private.accounting_line(''cash'',new.amount,cat,new.wallet_id),app_private.accounting_line(other,-new.amount,cat,entity)',
 'app_private.accounting_line(''cash'',new.amount,cat,new.wallet_id)||jsonb_build_object(''allocations'',new.allocations,''type_id'',new.type_id),app_private.accounting_line(other,-new.amount,cat,entity)||jsonb_build_object(''allocations'',new.allocations,''type_id'',new.type_id)');execute s;
end $$;

-- Source defaults are snapshotted once for asset/loan/obligation ownership.
-- Explicit action metadata is attached before the request result is persisted.
do $$declare s text;begin
 s:=pg_get_functiondef('public.accounting_operation(jsonb,uuid)'::regprocedure);
 s:=replace(s,'entries jsonb:=''[]'';', 'alloc jsonb:=coalesce(p_payload->''allocations'',case when p_payload->>''business_category'' in (''lpg'',''stove'',''logistics'') then jsonb_build_object(p_payload->>''business_category'',100) else ''{"lpg":100}''::jsonb end); op_type uuid; entries jsonb:=''[]'';');
 s:=replace(s,'amount:=app_private.purchase_money', 'if action=''asset_register'' and (p_payload->>''kind''=''vehicles'' or p_payload->>''vehicle_id'' is not null) then alloc:=''{"logistics":100}'';end if; if not coalesce(app_private.valid_business_allocation(alloc),false) then raise exception ''Business percentages must total 100'';end if;op_type:=app_private.system_type(action); amount:=app_private.purchase_money');
 s:=replace(s,'accounting_date) values(', 'accounting_date,allocations) values(');
 s:=replace(s,',p_request_id,note,d);',',p_request_id,note,d,alloc);');
 s:=replace(s,'received_on,opening,created_by)', 'received_on,opening,created_by,allocations)');
 s:=replace(s,'false),auth.uid()) returning loan_id','false),auth.uid(),alloc) returning loan_id');
 s:=replace(s,'valuation_source,created_by)', 'valuation_source,created_by,allocations)');
 s:=replace(s,'''verified'',auth.uid()) returning asset_id','''verified'',auth.uid(),alloc) returning asset_id');
 s:=replace(s,'id:=loan.loan_id;', 'id:=loan.loan_id;alloc:=loan.allocations;');
 s:=replace(s,'id:=ob.obligation_id;', 'id:=ob.obligation_id;alloc:=ob.allocations;');
 s:=replace(s,'id:=asset.asset_id;', 'id:=asset.asset_id;alloc:=asset.allocations;');
 s:=replace(s,'perform app_private.post_journal(t,''owner_operation''',
 'update public.finance_obligations set allocations=alloc where tenant_id=t and (obligation_id=id or entity_id=id); select coalesce(jsonb_agg(x||jsonb_build_object(''allocations'',alloc,''type_id'',op_type)),''[]'') into entries from jsonb_array_elements(entries)x; perform app_private.post_journal(t,''owner_operation''');
 execute s;
end $$;

create or replace function public.move_wallet_money(p_payload jsonb,p_request_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$declare
 t uuid:=app_private.require_permission('finance:manage');prior public.finance_requests;body jsonb:=p_payload||jsonb_build_object('actor',auth.uid());
 src uuid:=(p_payload->>'wallet_id')::uuid;dest uuid:=(p_payload->>'destination_id')::uuid;a numeric:=(p_payload->>'amount')::numeric;
 b text:=coalesce(p_payload->>'business','lpg');db text:=coalesce(p_payload->>'destination_business',b);action text:=p_payload->>'action';reason text:=trim(p_payload->>'reason');result jsonb;d date:=coalesce((p_payload->>'date')::date,(now() at time zone 'Asia/Dhaka')::date);begin
 if p_request_id is null then raise exception 'Request ID is required';end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from body then raise exception 'Request ID already used with different details';end if;return prior.result;end if;
 if action not in ('transfer','adjustment') or action is null or reason is null or length(reason) not between 3 and 500 or jsonb_typeof(p_payload->'amount') is distinct from 'number'
 or a=0 or abs(a)<>app_private.purchase_money(abs(a)) or b not in ('lpg','stove','logistics') or db not in ('lpg','stove','logistics') or not isfinite(d) or d>(now() at time zone 'Asia/Dhaka')::date then raise exception 'Choose a valid operation, amount, business, date and reason';end if;
 perform 1 from public.wallets where tenant_id=t and wallet_id in(src,dest) order by wallet_id for update;
 if not exists(select 1 from public.wallets where tenant_id=t and wallet_id=src and is_active) then raise exception 'Active source wallet not found';end if;
 if action='transfer' then
  if a<0 or dest is null or dest=src and db=b then raise exception 'Choose a different wallet or business and positive amount';end if;
  if not exists(select 1 from public.wallets where tenant_id=t and wallet_id=dest and is_active) then raise exception 'Active destination wallet not found';end if;
  insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,description,counterparty_wallet_id,operation_id,accounting_date,allocations) values
   (t,src,-a,'wallet_transfer',reason,dest,p_request_id,d,jsonb_build_object(b,100)),(t,dest,a,'wallet_transfer',reason,src,p_request_id,d,jsonb_build_object(db,100));
 else
  if dest is not null or coalesce(p_payload->>'classification','correction') not in ('correction','opening','capital') then raise exception 'Invalid adjustment classification';end if;
  if p_payload->>'classification' in ('opening','capital') then perform app_private.require_owner('finance:manage');if a<0 then raise exception 'Opening and capital must be positive';end if;end if;
  insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,description,operation_id,accounting_date,allocations)
  values(t,src,a,case p_payload->>'classification' when 'opening' then 'opening_cash' when 'capital' then 'owner_capital' else 'balance_adjustment' end,reason,p_request_id,d,jsonb_build_object(b,100));
 end if;
 result:=jsonb_build_object('operation_id',p_request_id);insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,result,auth.uid());return result;
end $$;

-- Private helpers are never callable through PostgREST.
alter table public.financial_types owner to postgres;
do $$declare r record;begin for r in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='app_private'
 and p.proname in ('valid_business_allocation','allocate_money','system_type','source_type','source_allocation','dimension_entries','check_line_dimensions','wallet_dimensions','employee_business_default') loop
 execute format('alter function %s owner to postgres',r.signature);
 execute format('revoke all on function %s from public,anon,authenticated',r.signature);end loop;end $$;
revoke all on function public.move_wallet_money(jsonb,uuid) from public,anon;
grant execute on function public.move_wallet_money(jsonb,uuid) to authenticated;
