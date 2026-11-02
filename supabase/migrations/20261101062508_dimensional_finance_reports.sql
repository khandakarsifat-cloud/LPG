-- Extend the existing savepoint projection with type and consolidation values.
-- Only private derived rows are rebuilt. Source journals remain authoritative.
delete from app_private.accounting_snapshot_lines;
delete from app_private.accounting_snapshots;
alter table app_private.accounting_snapshot_lines add column type_id uuid not null references public.financial_types(type_id);
alter table app_private.accounting_snapshot_lines add column consolidated_amount numeric(20,2) not null;
do $$declare n text;begin select conname into n from pg_constraint where conrelid='app_private.accounting_snapshot_lines'::regclass and contype='u';execute format('alter table app_private.accounting_snapshot_lines drop constraint %I',n);end $$;
alter table app_private.accounting_snapshot_lines add unique nulls not distinct(tenant_id,month_end,account,business_category,entity_id,type_id);
update app_private.accounting_snapshot_state s set invalid_from=coalesce((select min(occurred_on) from public.accounting_journals where tenant_id=s.tenant_id),(now() at time zone 'Asia/Dhaka')::date);

create function app_private.dimensional_balances(ids uuid[],as_of date,before_day boolean default false,original boolean default false)
returns table(tenant_id uuid,account text,business_category text,entity_id uuid,type_id uuid,amount numeric,consolidated_amount numeric)
language sql stable set search_path='' as $$
 with cut as(select case when before_day then as_of-1 else as_of end d),
 preceding as materialized(select t.id,max(s.month_end) month_end from unnest(ids)t(id) cross join cut
 left join app_private.accounting_snapshot_state st on st.tenant_id=t.id
 left join app_private.accounting_snapshots s on s.tenant_id=t.id and s.month_end<=cut.d and s.month_end<st.invalid_from group by t.id),
 evidence as(
 select l.tenant_id,l.account,l.business_category,l.entity_id,l.type_id,l.amount,l.consolidated_amount from preceding p join app_private.accounting_snapshot_lines l on l.tenant_id=p.id and l.month_end=p.month_end
 union all
 select l.tenant_id,l.account,l.business_category,l.entity_id,l.type_id,l.amount,l.consolidated_amount from preceding p join public.accounting_journals j on j.tenant_id=p.id cross join cut
 join public.accounting_lines l on l.tenant_id=j.tenant_id and l.journal_id=j.journal_id
 where j.occurred_on>coalesce(p.month_end,'-infinity'::date) and (j.occurred_on<=cut.d or original and j.is_opening and j.occurred_on=as_of))
 select e.tenant_id,e.account,e.business_category,e.entity_id,e.type_id,sum(e.amount),sum(e.consolidated_amount) from evidence e group by 1,2,3,4,5;
$$;

create or replace function app_private.build_accounting_snapshots(t uuid,max_months integer default 3) returns integer language plpgsql set search_path='' as $$
declare d date;last_month date:=(date_trunc('month',now() at time zone 'Asia/Dhaka')-interval '1 day')::date;n integer:=0;v bigint;c bigint;hash text;rows jsonb;begin
 if max_months not between 1 and 24 then raise exception 'Invalid snapshot batch';end if;
 select (date_trunc('month',invalid_from)+interval '1 month - 1 day')::date into d from app_private.accounting_snapshot_state where tenant_id=t for update;
 while d<=last_month and n<max_months loop
  select coalesce(jsonb_agg(to_jsonb(b)),'[]') into rows from app_private.dimensional_balances(array[t],d)b;
  select count(*) into c from public.accounting_lines l join public.accounting_journals j using(tenant_id,journal_id) where j.tenant_id=t and j.occurred_on<=d;
  select md5(coalesce(string_agg(concat_ws(':',account,business_category,entity_id,type_id,amount,consolidated_amount),'|' order by account,business_category,entity_id,type_id),'')) into hash from jsonb_to_recordset(rows)b(account text,business_category text,entity_id uuid,type_id uuid,amount numeric,consolidated_amount numeric);
  insert into app_private.accounting_snapshots(tenant_id,month_end,source_count,checksum) values(t,d,c,hash)
   on conflict(tenant_id,month_end) do update set built_at=clock_timestamp(),revision=accounting_snapshots.revision+1,source_count=c,checksum=hash returning revision into v;
  delete from app_private.accounting_snapshot_lines where tenant_id=t and month_end=d;
  insert into app_private.accounting_snapshot_lines(tenant_id,month_end,account,business_category,entity_id,type_id,amount,consolidated_amount)
  select t,d,account,business_category,entity_id,type_id,amount,consolidated_amount from jsonb_to_recordset(rows)b(account text,business_category text,entity_id uuid,type_id uuid,amount numeric,consolidated_amount numeric);
  insert into app_private.accounting_snapshot_audit(tenant_id,month_end,revision,source_count,checksum) values(t,d,v,c,hash);
  update app_private.accounting_snapshot_state set invalid_from=d+1 where tenant_id=t;
  d:=(d+interval '1 month')::date;d:=(date_trunc('month',d)+interval '1 month - 1 day')::date;n:=n+1;
 end loop;return n;end $$;

create function app_private.scoped_position(ids uuid[],d date,business text,before_day boolean default false,original boolean default false) returns jsonb language sql stable set search_path='' as $$
 select app_private.position_from_balances(coalesce(jsonb_agg(jsonb_build_object('tenant_id',b.tenant_id,'account',b.account,'entity_id',b.entity_id,
 'amount',case when business='all' then b.consolidated_amount else b.amount end)),'[]'))
 from app_private.dimensional_balances(ids,d,before_day,original)b where business='all' or b.business_category=business;$$;

do $$declare s text;begin
 s:=pg_get_functiondef('app_private.position_from_balances(jsonb)'::regprocedure);
 s:=replace(s,'account=''equity_adjustment''','account in (''equity_adjustment'',''business_allocation_equity'',''retained_earnings'')');execute s;
 s:=pg_get_functiondef('app_private.finance_analysis_report(jsonb)'::regprocedure);
 s:=replace(s,'''logistics'',''shared''','''logistics''');
 s:=replace(s,'select app_private.position_from_balances(coalesce(jsonb_agg(to_jsonb(b)),''[]'')) into opening from app_private.accounting_balances(ids,f,true,original)b;closing:=app_private.accounting_position(ids,u);',
 'opening:=app_private.scoped_position(ids,f,cat,true,original);closing:=app_private.scoped_position(ids,u,cat);');
 s:=replace(s,'l.account,l.amount,l.business_category', 'l.account,case when cat=''all'' then l.consolidated_amount else l.amount end amount,l.amount business_amount,l.business_category');
 s:=replace(s,'select -sum(l.amount) from public.accounting_journals', 'select -sum(case when cat=''all'' then l.consolidated_amount else l.amount end) from public.accounting_journals');
 s:=replace(s,'''opening_equity'',''equity_adjustment''', '''opening_equity'',''equity_adjustment'',''business_allocation_equity'',''retained_earnings''');
 s:=replace(s,'l.account=''cash'' and l.source=''wallet''', 'l.account=''cash'' and (l.source=''wallet'' or l.source=''internal_transport'')');
 s:=replace(s,'x.transaction_id=l.source_id', 'x.transaction_id=case when l.source=''wallet'' then l.source_id else (select (al.details->>''wallet_transaction_id'')::uuid from public.accounting_lines al where al.tenant_id=l.tenant_id and al.journal_id=l.journal_id and al.account=''cash'' and al.entity_id=l.entity_id and al.amount=l.business_amount limit 1) end');
 s:=replace(s,'when x.type=''wallet_transfer'' then ''transfer''', 'when x.type=''wallet_transfer'' or cat=''all'' and x.type in (''internal_transport_payment'',''internal_transport_receipt'',''internal_transport_return'') then ''transfer''');
 s:=replace(s,'select b.tenant_id,b.account,b.entity_id,date_trunc(grain,f::timestamp)::date period,b.amount', 'select b.tenant_id,b.account,b.entity_id,date_trunc(grain,f::timestamp)::date period,case when cat=''all'' then b.consolidated_amount else b.amount end amount');
 s:=replace(s,'from app_private.accounting_balances(ids,f,true,original)b join public.accounting_accounts a on a.code=b.account where a.kind', 'from app_private.dimensional_balances(ids,f,true,original)b join public.accounting_accounts a on a.code=b.account where (cat=''all'' or b.business_category=cat) and a.kind');
 s:=replace(s,'date_trunc(grain,j.occurred_on)::date,l.amount', 'date_trunc(grain,j.occurred_on)::date,case when cat=''all'' then l.consolidated_amount else l.amount end');
 s:=replace(s,'and a.kind in (''asset'',''liability''))', 'and (cat=''all'' or l.business_category=cat) and a.kind in (''asset'',''liability''))');
 s:=replace(s,'business as(select tenant_id,business_category,coalesce(-sum(amount)', 'business as(select tenant_id,business_category,coalesce(-sum(business_amount)');
 s:=replace(s,'expenses from period_lines', 'expenses from period_lines');
 s:=replace(s,'coalesce(sum(amount) filter(where kind=''expense''),0) expenses from period_lines', 'coalesce(sum(business_amount) filter(where kind=''expense''),0) expenses from period_lines');
 s:=replace(s,'coverage and cat=''all''','coverage');
 execute s;
end $$;

-- Period movements supplement cumulative positions, using identical scope and
-- recognition cutoffs. Acquisitions exclude stock returns and cost transfers.
create function app_private.period_financial_values(p_filters jsonb) returns jsonb language plpgsql stable set search_path='' as $$declare
 ids uuid[]:=app_private.analysis_scope(p_filters);cat text:=coalesce(p_filters->>'category','all');r jsonb;begin
 with lines as(select j.source,l.account,case when cat='all' then l.consolidated_amount else l.amount end amount,t.code
 from public.accounting_journals j join public.accounting_lines l using(tenant_id,journal_id) join public.financial_types t using(type_id)
 where j.tenant_id=any(ids) and j.occurred_on between (p_filters->>'from')::date and (p_filters->>'to')::date and not j.is_opening and (cat='all' or l.business_category=cat))
 select jsonb_build_object(
 'stock_acquisitions',coalesce(sum(amount) filter(where account in ('inventory_lpg','inventory_stove') and code in ('purchase_receipt','internal_inventory') and amount>0),0),
 'stock_change',coalesce(sum(amount) filter(where account in ('inventory_lpg','inventory_stove','inventory_transit','bottle_receivable')),0),
 'equipment_acquisitions',coalesce(sum(amount) filter(where account in ('equipment','vehicles','other_assets') and code in ('asset_register','asset_improve') and amount>0),0),
 'receivable_change',coalesce(sum(amount) filter(where account in ('customer_receivable','transport_receivable','supplier_receivable')),0),
 'payable_change',coalesce(-sum(amount) filter(where account in ('supplier_payable','employee_payable','operating_payable','other_liability','commission_pending')),0),
 'loan_movement',coalesce(-sum(amount) filter(where account='loan_payable'),0),
 'wallet_movement',coalesce(sum(amount) filter(where account='cash'),0)) into r from lines;return r;end $$;

create or replace function public.get_finance_analysis(p_filters jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare ids uuid[]:=app_private.analysis_scope(p_filters);r record;result jsonb;f date:=(p_filters->>'from')::date;u date:=(p_filters->>'to')::date;begin
 if f is null or u is null or not isfinite(f) or not isfinite(u) or f>u or u>(now() at time zone 'Asia/Dhaka')::date then raise exception 'Choose a valid reporting period';end if;
 for r in select unnest(ids) id loop perform app_private.sync_payroll(r.id);end loop;
 result:=app_private.finance_analysis_report(p_filters);
 return result;end $$;

do $$declare s text;begin s:=pg_get_functiondef('app_private.finance_analysis_report(jsonb)'::regprocedure);
 s:=replace(s,'return result;', 'return result||jsonb_build_object(''period_values'',app_private.period_financial_values(p_filters||jsonb_build_object(''from'',result->>''from'')));');execute s;end $$;

create function public.get_financial_catalog() returns jsonb language plpgsql stable security definer set search_path='' as $$declare
 t uuid:=app_private.require_any_permission(array['finance:view','finance:manage','settings:manage','dashboard:view']);r jsonb;begin
 select jsonb_build_object('types',coalesce((select jsonb_agg(to_jsonb(x) order by origin,name) from public.financial_types x where tenant_id=t or origin='system'),'[]'),
 'categories',(select jsonb_agg(jsonb_build_object('code',code,'name',name,'kind',kind) order by kind,name) from public.accounting_accounts)) into r;return r;end $$;

create or replace function public.get_accounting_breakdown(p_filters jsonb,p_group text,p_side text,p_mode text default 'components',p_offset integer default 0,p_limit integer default 20)
returns jsonb language plpgsql stable security definer set search_path='' as $$declare
 ids uuid[]:=app_private.analysis_scope(p_filters);d date:=(p_filters->>'to')::date;f date:=(p_filters->>'from')::date;
 cat text:=coalesce(p_filters->>'category','all');original boolean:=false;before_day boolean:=false;r jsonb;begin
 if p_side not in ('opening','closing','period') or p_mode not in ('components','history') or p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100
 or p_group not in ('assets','liabilities','equity','accumulated_income','cash','inventory','receivables','fixed_assets','other_assets','dues','employees','other_liabilities','capital','revenue','expenses','withdrawals','other_equity')
 or f is null or d is null or not isfinite(f) or not isfinite(d) or f>d or d>(now() at time zone 'Asia/Dhaka')::date or length(coalesce(p_filters->>'search',''))>500 or cat not in ('all','lpg','stove','logistics') then raise exception 'Invalid breakdown filters';end if;
 if coalesce((p_filters->>'all_time')::boolean,false) then select min((started_at at time zone 'Asia/Dhaka')::date) into f from public.accounting_periods where tenant_id=any(ids);f:=least(f,d);end if;
 if p_side='opening' then before_day:=true;d:=f;original:=coalesce((p_filters->>'all_time')::boolean,false);end if;
 with evidence as(select *,1 sign from app_private.dimensional_balances(ids,d,before_day,original) union all select *,-1 from app_private.dimensional_balances(ids,f,true,coalesce((p_filters->>'all_time')::boolean,false)) where p_side='period'),
 balances as materialized(select b.tenant_id,b.account,b.business_category,b.type_id,
 case when a.kind in ('income','expense','equity') then null else b.entity_id end entity_id,a.kind,a.name,
 sum(b.sign*case when cat='all' then b.consolidated_amount else b.amount end) amount
 from evidence b join public.accounting_accounts a on a.code=b.account where cat='all' or b.business_category=cat group by 1,2,3,4,5,6,7),
 classified as(select *,sum(amount) over(partition by tenant_id,account,entity_id) control_total,case when kind='liability' and sum(amount) over(partition by tenant_id,account,entity_id)>0 then 'asset'
 when kind='asset' and sum(amount) over(partition by tenant_id,account,entity_id)<0 then 'liability' else kind end reported_kind from balances),
 selected as materialized(select *,case when p_group='withdrawals' then 1 when p_group in ('equity','accumulated_income') or reported_kind in ('liability','income','equity') then -1 else 1 end sign
 from classified where app_private.analysis_matches(p_group,account,reported_kind)
 and (nullif(p_filters->>'account','') is null or account=p_filters->>'account')
 and (nullif(p_filters->>'type_id','') is null or type_id=(p_filters->>'type_id')::uuid)
 and (nullif(p_filters->>'component_business','') is null or business_category=p_filters->>'component_business')
 and (nullif(p_filters->>'entity_id','') is null or p_filters->>'entity_id'='none' and entity_id is null or entity_id=nullif(nullif(p_filters->>'entity_id',''),'none')::uuid)),
 described as materialized(select s.*,ft.name type_name,app_private.analysis_entity(s.tenant_id,s.account,s.entity_id) entity from selected s join public.financial_types ft using(type_id)),
 components as materialized(select * from described where amount<>0 and (kind in ('income','expense','equity') or control_total<>0) and app_private.finance_search(concat_ws(' ',name,type_name,business_category,entity->>'entity_name'),coalesce(p_filters->>'search',''))),
 component_page as(select * from components order by abs(amount) desc,tenant_id,account,type_id,business_category,entity_id nulls first offset p_offset limit p_limit),
 movements as materialized(select j.tenant_id,j.journal_id,j.entry_no,j.occurred_on,j.description,j.source,j.source_id,j.source_id transaction_reference,j.estimated,l.line_no,l.account,s.name,l.type_id,s.type_name,l.business_category,l.entity_id,
 (case when cat='all' then l.consolidated_amount else l.amount end)*s.sign amount,app_private.analysis_entity(l.tenant_id,l.account,l.entity_id) entity
 from described s join public.accounting_lines l on l.tenant_id=s.tenant_id and l.account=s.account and l.type_id=s.type_id and l.business_category=s.business_category
 and (s.kind in ('income','expense','equity') or l.entity_id is not distinct from s.entity_id)
 join public.accounting_journals j on j.tenant_id=l.tenant_id and j.journal_id=l.journal_id
 where p_mode='history' and (p_side<>'period' or j.occurred_on>=f) and (case when before_day then j.occurred_on<d or original and j.is_opening and j.occurred_on=d else j.occurred_on<=d end)
 and (nullif(p_filters->>'history_from','') is null or j.occurred_on>=(p_filters->>'history_from')::date)
 and (nullif(p_filters->>'source','') is null or j.source=p_filters->>'source')
 and app_private.finance_search(concat_ws(' ',j.description,s.name,s.type_name,s.business_category,s.entity->>'entity_name',j.source,j.source_id),coalesce(p_filters->>'search',''))),
 history_page as(select * from movements order by occurred_on desc,entry_no desc,line_no offset p_offset limit p_limit)
 select jsonb_build_object('cutoff',case when before_day and not original then d-1 else d end,'original_opening',original,
 'balance',coalesce((select sum(amount*sign) from selected),0),
 'total',case when p_mode='components' then (select count(*) from components) else (select count(*) from movements) end,
 'filtered_movement',case when p_mode='history' then (select coalesce(sum(amount),0) from movements) end,
 'entries',case when p_mode='components' then coalesce((select jsonb_agg(jsonb_build_object('tenant_id',tenant_id,'account',account,'name',name,'kind',reported_kind,'entity_id',entity_id,'type_id',type_id,'type_name',type_name,'business_category',business_category,'amount',amount*sign)||entity order by abs(amount) desc,tenant_id,account,type_id,business_category,entity_id nulls first) from component_page),'[]')
 else coalesce((select jsonb_agg((to_jsonb(p)-'entity')||entity order by occurred_on desc,entry_no desc,line_no) from history_page p),'[]') end) into r;return r;end $$;

create or replace function public.get_journal_lines(p_filters jsonb,p_journal_id uuid,p_offset integer default 0,p_limit integer default 25) returns jsonb language plpgsql stable security definer set search_path='' as $$declare
 ids uuid[]:=app_private.analysis_scope(p_filters);t uuid;r jsonb;begin
 if p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid page';end if;
 select tenant_id into t from public.accounting_journals where journal_id=p_journal_id and tenant_id=any(ids);
 if t is null then raise exception 'Journal unavailable' using errcode='42501';end if;
 with page as(select l.line_no,l.account account_code,a.name account,l.amount,l.consolidated_amount,l.business_category,l.type_id,ft.name type_name,l.entity_id,
 app_private.analysis_entity(l.tenant_id,l.account,l.entity_id)->>'entity_name' entity_name
 from public.accounting_lines l join public.accounting_accounts a on a.code=l.account join public.financial_types ft using(type_id)
 where l.tenant_id=t and l.journal_id=p_journal_id order by l.line_no offset p_offset limit p_limit)
 select jsonb_build_object('total',(select count(*) from public.accounting_lines where tenant_id=t and journal_id=p_journal_id),'entries',coalesce((select jsonb_agg(to_jsonb(p) order by line_no) from page p),'[]')) into r;return r;end $$;

alter table public.wallet_transactions add column business_amounts jsonb;
alter table public.wallet_transactions disable trigger immutable_wallet_entry;
update public.wallet_transactions x set business_amounts=(select jsonb_object_agg(business,amount) from app_private.allocate_money(x.amount,x.allocations));
alter table public.wallet_transactions enable trigger immutable_wallet_entry;
alter table public.wallet_transactions alter column business_amounts set not null;

-- Reconciliation checks both the business carrying value and the external
-- consolidated value, plus every type-bearing savepoint row.
do $$declare s text;start_at integer;end_at integer;replacement text;begin
 s:=pg_get_functiondef('app_private.reconcile_record(uuid,text,uuid)'::regprocedure);
 s:=replace(s,'observed:=jsonb_build_object(''balance'',v);',
 'observed:=jsonb_build_object(''balance'',v,''business_balances'',(select business_balances from public.wallets where tenant_id=t and wallet_id=id));');
 s:=replace(s,'expected:=jsonb_build_object(''balance'',v2);',
 'expected:=jsonb_build_object(''balance'',v2,''business_balances'',(select jsonb_object_agg(b,coalesce((select sum(amount) from public.accounting_lines where tenant_id=t and account=''cash'' and entity_id=id and business_category=b),0)) from unnest(array[''lpg'',''stove'',''logistics''])b));');
 s:=replace(s,'update public.wallets set balance=v2 where', 'update public.wallets set balance=v2,business_balances=expected->''business_balances'' where');
 s:=replace(s,'if v is distinct from v2 and v2=', 'if observed is distinct from expected and v2=');
 s:=replace(s,'(select sum(amount) from public.accounting_lines where tenant_id=t and entity_id=id and account in (''inventory_lpg'',''inventory_stove''))',
 '(select sum(consolidated_amount) from public.accounting_lines where tenant_id=t and entity_id=id and account in (''inventory_lpg'',''inventory_stove''))');
 start_at:=strpos(s,'with full_history as(select l.account');end_at:=strpos(substr(s,start_at),'into expected;')+start_at+length('into expected;')-1;
 replacement:='with full_history as(select l.account,l.business_category,l.entity_id,l.type_id,sum(l.amount) amount,sum(l.consolidated_amount) consolidated_amount from public.accounting_lines l join public.accounting_journals j using(tenant_id,journal_id) where j.tenant_id=t and j.occurred_on<=d group by 1,2,3,4),
 diff as(select * from full_history except select account,business_category,entity_id,type_id,amount,consolidated_amount from app_private.accounting_snapshot_lines where tenant_id=t and month_end=d),
 reverse_diff as(select account,business_category,entity_id,type_id,amount,consolidated_amount from app_private.accounting_snapshot_lines where tenant_id=t and month_end=d except select * from full_history)
 select jsonb_build_object(''checksum'',md5(coalesce((select string_agg(concat_ws('':'',account,business_category,entity_id,type_id,amount,consolidated_amount),''|'' order by account,business_category,entity_id,type_id) from full_history),'''')),''difference'',(select count(*) from diff)+(select count(*) from reverse_diff)) into expected;';
 if start_at=0 or end_at<start_at then raise exception 'Reconciliation definition changed';end if;
 s:=overlay(s placing replacement from start_at for end_at-start_at);execute s;
end $$;
do $$declare s text;begin
 s:=pg_get_functiondef('app_private.wallet_dimensions()'::regprocedure);
 s:=replace(s,'return new;', 'new.business_amounts:=(select jsonb_object_agg(business,amount) from app_private.allocate_money(new.amount,new.allocations));return new;');execute s;
 s:=pg_get_functiondef('public.get_wallet_ledger(jsonb,integer,integer)'::regprocedure);
 s:=replace(s,'x.entry_no,x.amount from public.wallet_transactions', 'x.entry_no,case when nullif($2->>''business'','''') is null then x.amount else coalesce((x.business_amounts->>($2->>''business''))::numeric,0) end amount from public.wallet_transactions');
 s:=replace(s,'and (nullif($2->>''type'','''') is null or x.type=$2->>''type'')',
 'and (nullif($2->>''type'','''') is null or x.type_id=($2->>''type'')::uuid) and (nullif($2->>''business'','''') is null or x.business_amounts ? ($2->>''business''))');
 s:=replace(s,'''wallet_name'',coalesce(p.wallet_name_snapshot', '''type_name'',ft.name,''wallet_name'',coalesce(p.wallet_name_snapshot');
 s:=replace(s,'left join public.wallets cw', 'left join public.financial_types ft on ft.type_id=p.type_id left join public.wallets cw');
 execute s;
end $$;

do $$declare r record;begin for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='app_private' and p.proname in ('dimensional_balances','scoped_position','period_financial_values') loop
 execute format('alter function %s owner to postgres',r.sig);execute format('revoke all on function %s from public,anon,authenticated',r.sig);end loop;end $$;
alter function public.get_financial_catalog() owner to postgres;
revoke all on function public.get_financial_catalog() from public,anon;
grant execute on function public.get_financial_catalog() to authenticated;
