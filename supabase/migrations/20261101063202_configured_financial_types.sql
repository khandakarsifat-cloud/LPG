-- Replace editable spending categories with the canonical financial type catalog.
insert into public.financial_types(type_id,tenant_id,name,origin,account,allocations,is_active,revision)
select category_id,tenant_id,name,'custom',case when classification='withdrawal' then 'withdrawals' when lower(name)='interest' then 'interest_expense' else 'operating_expense' end,
 case when lower(name)='logistics' then '{"logistics":100}'::jsonb else '{"lpg":100}'::jsonb end,is_active,revision from public.spending_categories;
create unique index financial_custom_name on public.financial_types(tenant_id,lower(name)) where origin='custom';

alter table public.spendings rename to financial_entries;
alter table public.financial_entries disable trigger immutable_spending;
alter table public.financial_entries rename column spending_id to entry_id;
alter table public.financial_entries rename column category_id to type_id;
alter table public.financial_entries rename column category_name to type_name;
alter table public.financial_entries rename column spending_date to occurred_on;
do $$declare n text;begin select conname into n from pg_constraint where conrelid='public.financial_entries'::regclass and confrelid='public.spending_categories'::regclass;execute format('alter table public.financial_entries drop constraint %I',n);end $$;
alter table public.financial_entries add foreign key(type_id) references public.financial_types(type_id);
alter table public.financial_entries add column account text references public.accounting_accounts(code);
alter table public.financial_entries add column type_revision integer not null default 1;
alter table public.financial_entries add column allocations jsonb not null default '{"lpg":100}' check(app_private.valid_business_allocation(allocations));
alter table public.financial_entries add column business_amounts jsonb;
alter table public.financial_entries add column asset_id uuid;
alter table public.financial_entries add foreign key(tenant_id,asset_id) references public.business_assets(tenant_id,asset_id);
alter table public.financial_entries add column reversal_of uuid;
alter table public.financial_entries add foreign key(tenant_id,reversal_of) references public.financial_entries(tenant_id,entry_id);
create index financial_entry_returns on public.financial_entries(tenant_id,reversal_of) where reversal_of is not null;
update public.financial_entries e set account=case when classification='withdrawal' then 'withdrawals' when lower(e.type_name)='interest' then 'interest_expense' else 'operating_expense' end,
 allocations=t.allocations,type_revision=t.revision from public.financial_types t where t.type_id=e.type_id;
update public.financial_entries e set business_amounts=(select jsonb_object_agg(business,-amount) from app_private.allocate_money(e.amount,e.allocations));
alter table public.financial_entries alter column account set not null;
alter table public.financial_entries alter column business_amounts set not null;
alter table public.financial_entries drop column classification;
alter table public.financial_entries enable trigger immutable_spending;

-- Preserve original paid amounts and reclassify their dimensions to the retained
-- named custom type. All journal/source identities and cash totals are unchanged.
alter table public.accounting_lines disable trigger accounting_immutable;
update public.accounting_lines l set type_id=e.type_id,business_category=case when e.allocations ? 'logistics' then 'logistics' else 'lpg' end
from public.accounting_journals j join public.wallet_transactions x on x.tenant_id=j.tenant_id and x.transaction_id=j.source_id
join public.financial_entries e on e.tenant_id=x.tenant_id and e.entry_id=x.reference_id
where j.source='wallet' and l.tenant_id=j.tenant_id and l.journal_id=j.journal_id;
alter table public.accounting_lines enable trigger accounting_immutable;
alter table public.wallet_transactions disable trigger immutable_wallet_entry;
update public.wallet_transactions x set type_id=e.type_id,allocations=e.allocations,business_amounts=e.business_amounts
from public.financial_entries e where x.tenant_id=e.tenant_id and x.reference_id=e.entry_id;
alter table public.wallet_transactions enable trigger immutable_wallet_entry;
update public.wallets w set business_balances=(select jsonb_object_agg(k,coalesce((select sum(l.amount) from public.accounting_lines l where l.tenant_id=w.tenant_id and l.entity_id=w.wallet_id and l.account='cash' and l.business_category=k),0)) from unnest(array['lpg','stove','logistics'])k);
update app_private.accounting_snapshot_state s set invalid_from=least(invalid_from,(select min(occurred_on) from public.accounting_journals where tenant_id=s.tenant_id));

create function app_private.initialize_financial_types(t uuid) returns void language sql set search_path='' as $$
 insert into public.financial_types(tenant_id,name,origin,account,allocations) values
 (t,'Business','custom','operating_expense','{"lpg":100}'),(t,'Logistics','custom','operating_expense','{"logistics":100}'),
 (t,'Home','custom','withdrawals','{"lpg":100}'),(t,'Others','custom','withdrawals','{"lpg":100}'),(t,'Interest','custom','interest_expense','{"lpg":100}');$$;
create function app_private.financial_types_created() returns trigger language plpgsql set search_path='' as $$begin perform app_private.initialize_financial_types(new.tenant_id);return new;end $$;
drop trigger spending_categories_created on public.tenants;
drop function app_private.spending_categories_created();
drop function app_private.initialize_spending_categories(uuid);
create trigger financial_types_created after insert on public.tenants for each row execute function app_private.financial_types_created();
drop function public.get_spending_categories();
drop function public.save_spending_category(jsonb);
drop function public.record_spending(jsonb,uuid);
drop function public.get_spendings(jsonb,integer,integer);
drop table public.spending_categories;

create table public.financial_type_history(
 tenant_id uuid not null,type_id uuid not null,revision integer not null,definition jsonb not null,
 created_at timestamptz not null default clock_timestamp(),created_by uuid,
 primary key(tenant_id,type_id,revision),foreign key(type_id) references public.financial_types(type_id)
);
alter table public.financial_type_history enable row level security;
revoke all on public.financial_type_history from public,anon,authenticated;
insert into public.financial_type_history select tenant_id,type_id,revision,to_jsonb(t),clock_timestamp(),null from public.financial_types t where origin='custom';
create trigger immutable_type_history before update or delete on public.financial_type_history for each row execute function app_private.immutable_finance_record();

create function public.save_financial_type(p_payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$declare
 t uuid:=app_private.require_permission('settings:manage');id uuid:=(p_payload->>'type_id')::uuid;definition public.financial_types;begin
 if nullif(trim(p_payload->>'name'),'') is null or length(trim(p_payload->>'name'))>80 or not coalesce(app_private.valid_business_allocation(p_payload->'allocations'),false)
 or coalesce(p_payload->>'account','') not in ('operating_expense','interest_expense','withdrawals','other_income','capital','equipment','other_assets') then raise exception 'Enter a name, supported fixed category and percentages totaling 100';end if;
 if id is null then
  insert into public.financial_types(tenant_id,name,origin,account,allocations,is_active) values(t,trim(p_payload->>'name'),'custom',p_payload->>'account',p_payload->'allocations',coalesce((p_payload->>'is_active')::boolean,true)) returning * into definition;
 else
  update public.financial_types set name=trim(p_payload->>'name'),account=p_payload->>'account',allocations=p_payload->'allocations',is_active=coalesce((p_payload->>'is_active')::boolean,true),revision=revision+1
  where tenant_id=t and type_id=id and origin='custom' and revision=(p_payload->>'revision')::integer returning * into definition;
  if not found then raise exception 'Type changed. Reload before saving.';end if;
 end if;
 insert into public.financial_type_history values(t,definition.type_id,definition.revision,to_jsonb(definition),clock_timestamp(),auth.uid());
 return jsonb_build_object('type_id',definition.type_id);end $$;

create function app_private.valid_business_amounts(value numeric,a jsonb) returns boolean language sql immutable set search_path='' as $$
 select case when jsonb_typeof(a)='object' then (select count(*) between 1 and 3 and sum(x.value::text::numeric)=$1
 and bool_and(key in ('lpg','stove','logistics') and jsonb_typeof(x.value)='number' and abs(x.value::text::numeric)<100000000000000000 and round(x.value::text::numeric,2)=x.value::text::numeric
 and (x.value::text::numeric=0 or sign(x.value::text::numeric)=sign($1))) from jsonb_each(a)x) else false end;$$;
alter table public.wallet_transactions add check(app_private.valid_business_amounts(amount,business_amounts));

do $$declare s text;begin
 s:=pg_get_functiondef('app_private.wallet_accounting_date()'::regprocedure);
 s:=replace(replace(replace(replace(s,'public.spendings','public.financial_entries'),'s.spending_date','s.occurred_on'),'s.spending_id','s.entry_id'),'new.type in (''business_spending'',''owner_withdrawal'')','new.type=''custom_entry''');execute s;
 s:=pg_get_functiondef('app_private.wallet_dimensions()'::regprocedure);
 s:=replace(s,'new.business_amounts:=(select jsonb_object_agg(business,amount) from app_private.allocate_money(new.amount,new.allocations));',
 'if new.business_amounts is null then new.business_amounts:=(select jsonb_object_agg(business,amount) from app_private.allocate_money(new.amount,new.allocations));end if; if not coalesce(app_private.valid_business_amounts(new.amount,new.business_amounts),false) then raise exception ''Business amounts must equal the wallet movement'';end if;');execute s;
 s:=pg_get_functiondef('app_private.post_wallet_entry()'::regprocedure);
 s:=replace(s,'app_private.allocate_money(new.amount,new.allocations)a', '(select key business,value::numeric amount from jsonb_each_text(new.business_amounts))a');execute s;
end $$;

create or replace function app_private.account_wallet() returns trigger language plpgsql set search_path='' as $$declare
 other text;entity uuid:=new.reference_id;ep public.employee_payments;e public.financial_entries;entries jsonb;begin
 if new.type in ('internal_transport_payment','internal_transport_receipt','internal_transport_return') then return new;end if;
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
 elsif new.type='wallet_transfer' then other:='business_allocation_equity';entity:=new.operation_id;
 elsif new.type='balance_adjustment' then other:='equity_adjustment';
 elsif new.type='owner_capital' then other:='capital';
 elsif new.type='opening_cash' then other:='opening_equity';
 elsif new.type in ('loan_receipt','loan_repayment') then other:='loan_payable';
 elsif new.type in ('asset_purchase','asset_proceeds','asset_disposal_expense') then other:='other_assets';
 elsif new.type='commission_receipt' then other:='supplier_receivable';
 else raise exception 'Wallet entry has no accounting classification: %',new.type;end if;
 if other is null then raise exception 'Wallet source is missing';end if;
 select jsonb_agg(line) into entries from jsonb_each_text(new.business_amounts)b cross join lateral(values
  (app_private.accounting_line('cash',b.value::numeric,b.key,new.wallet_id)||jsonb_build_object('type_id',new.type_id)),
  (app_private.accounting_line(other,-b.value::numeric,b.key,entity,jsonb_build_object('type_name',e.type_name))||jsonb_build_object('type_id',new.type_id)))v(line);
 perform app_private.post_journal(new.tenant_id,'wallet',new.transaction_id,'cash',new.accounting_date,new.description,entries,false,new.type='opening_cash');return new;
end $$;

create function public.record_financial_entry(p_payload jsonb,p_request_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$declare
 t uuid:=app_private.require_permission('finance:manage');prior public.finance_requests;body jsonb:=jsonb_build_object('action','financial_entry','actor',auth.uid(),'body',p_payload);
 ft public.financial_types;original public.financial_entries;asset public.business_assets;w public.wallets;id uuid:=gen_random_uuid();aid uuid;
 a numeric:=app_private.purchase_money((p_payload->>'amount')::numeric);d date:=(p_payload->>'date')::date;cash numeric;alloc jsonb;amounts jsonb;returned numeric;result jsonb;type_name text;account text;revision integer;begin
 if p_request_id is null then raise exception 'Request ID is required';end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from body then raise exception 'Request ID already used with different details';end if;return prior.result;end if;
 if a is null or a<=0 or a<>(p_payload->>'amount')::numeric or d is null or not isfinite(d) or d>(now() at time zone 'Asia/Dhaka')::date or length(trim(coalesce(p_payload->>'description',''))) not between 1 and 1000 then raise exception 'Enter a positive two-decimal amount, date and description';end if;
 if p_payload->>'reversal_of' is not null then
  select * into original from public.financial_entries where tenant_id=t and entry_id=(p_payload->>'reversal_of')::uuid and reversal_of is null for update;
  if not found or d<original.occurred_on then raise exception 'Original entry unavailable or return predates it';end if;
  select coalesce(sum(amount),0) into returned from public.financial_entries where tenant_id=t and reversal_of=original.entry_id;
  if returned+a>original.amount then raise exception 'Return exceeds the original entry';end if;
  select * into ft from public.financial_types where type_id=original.type_id and tenant_id=t;
  alloc:=original.allocations;account:=original.account;type_name:=original.type_name;revision:=original.type_revision;aid:=original.asset_id;
  cash:=case when account in ('other_income','capital') then -a else a end;
  select jsonb_object_agg(x.business,sign(cash)*(x.amount-y.amount)) into amounts from app_private.allocate_money(returned+a,alloc)x join app_private.allocate_money(returned,alloc)y using(business);
 else
  select * into ft from public.financial_types where tenant_id=t and type_id=(p_payload->>'type_id')::uuid and origin='custom' and is_active for share;
  if not found or ft.revision is distinct from (p_payload->>'expected_revision')::integer then raise exception 'Type changed or was deactivated. Reload before recording.';end if;
  alloc:=coalesce(p_payload->'allocations',ft.allocations);account:=ft.account;type_name:=ft.name;revision:=ft.revision;
  if not coalesce(app_private.valid_business_allocation(alloc),false) then raise exception 'Business percentages must total 100';end if;
  cash:=case when account in ('other_income','capital') then a else -a end;
  select jsonb_object_agg(business,amount) into amounts from app_private.allocate_money(cash,alloc);
 end if;
 if account in ('equipment','other_assets') then
  perform app_private.require_owner('finance:manage');
  if aid is null then
   insert into public.business_assets(tenant_id,name,kind,cost,acquired_on,valuation_source,created_by,allocations)
   values(t,type_name||': '||trim(p_payload->>'description'),account,a,d,'verified',auth.uid(),alloc) returning asset_id into aid;
  else
   select * into asset from public.business_assets where tenant_id=t and asset_id=aid for update;
   if asset.status<>'active' or a>asset.cost-asset.accumulated_depreciation then raise exception 'Asset refund exceeds its remaining book value';end if;
   update public.business_assets set cost=cost-a,revision=business_assets.revision+1 where tenant_id=t and asset_id=aid;
  end if;
 end if;
 if account='capital' then perform app_private.require_owner('finance:manage');end if;
 select * into w from public.wallets where tenant_id=t and wallet_id=(p_payload->>'wallet_id')::uuid and is_active for update;
 if not found then raise exception 'Choose an active business wallet';end if;
 insert into public.financial_entries(tenant_id,entry_id,type_id,type_name,type_revision,account,allocations,business_amounts,asset_id,reversal_of,wallet_id,wallet_name,amount,occurred_on,description,created_by)
 values(t,id,ft.type_id,type_name,revision,account,alloc,amounts,aid,original.entry_id,w.wallet_id,w.name,a,d,trim(p_payload->>'description'),auth.uid());
 insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,type_id,reference_id,description,operation_id,accounting_date,allocations,business_amounts)
 values(t,w.wallet_id,cash,'custom_entry',ft.type_id,id,type_name||' · '||trim(p_payload->>'description'),p_request_id,d,alloc,amounts);
 if aid is not null then insert into public.asset_activity(tenant_id,asset_id,action,occurred_on,details,created_by) values(t,aid,case when original.entry_id is null then 'registered' else 'acquisition_refund' end,d,jsonb_build_object('amount',a,'entry_id',id,'type_id',ft.type_id,'allocations',alloc),auth.uid());end if;
 result:=jsonb_build_object('entry_id',id,'asset_id',aid);insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,result,auth.uid());return result;
end $$;

alter table public.financial_type_history owner to postgres;
alter function public.save_financial_type(jsonb) owner to postgres;
alter function public.record_financial_entry(jsonb,uuid) owner to postgres;
revoke all on function public.save_financial_type(jsonb),public.record_financial_entry(jsonb,uuid) from public,anon;
grant execute on function public.save_financial_type(jsonb),public.record_financial_entry(jsonb,uuid) to authenticated;
do $$declare r record;begin for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='app_private' and p.proname in ('initialize_financial_types','financial_types_created','valid_business_amounts') loop
 execute format('alter function %s owner to postgres',r.sig);execute format('revoke all on function %s from public,anon,authenticated',r.sig);end loop;end $$;
