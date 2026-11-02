-- A payroll entry reached a branch whose SQL alias conflicted with a record
-- variable. Keep explicit names; never change PL/pgSQL conflict resolution.
do $$declare s text;begin
 s:=pg_get_functiondef('app_private.financial_source_link(uuid,text,uuid)'::regprocedure);
 s:=replace(s,'e public.operating_cost_events','cost_event public.operating_cost_events');
 s:=replace(s,'into e from public.operating_cost_events','into cost_event from public.operating_cost_events');
 s:=replace(s,'ref:=e.transit_id','ref:=cost_event.transit_id');execute s;
 s:=pg_get_functiondef('public.get_wallet_ledger(jsonb,integer,integer)'::regprocedure);
 s:=replace(s,'($2->>''wallet'')::uuid','nullif($2->>''wallet'','''')::uuid');
 s:=replace(s,'($2->>''type'')::uuid','nullif($2->>''type'','''')::uuid');
 s:=replace(s,'($2->>''min'')::numeric','nullif($2->>''min'','''')::numeric');
 s:=replace(s,'($2->>''max'')::numeric','nullif($2->>''max'','''')::numeric');
 s:=replace(s,'abs(p.amount) end','abs(keys.amount) end');execute s;
 s:=replace(s,chr(92)||chr(92)||'s',chr(92)||'s');execute s;
 -- Custom categories have exactly five choices. Historical source accounts
 -- retain their original journal evidence; an interest type is an Expense.
 s:=pg_get_functiondef('public.save_financial_type(jsonb)'::regprocedure);
 s:=replace(s,'''operating_expense'',''interest_expense'',''withdrawals'',''other_income'',''capital'',''equipment'',''other_assets''',
 '''operating_expense'',''withdrawals'',''other_income'',''capital'',''equipment''');execute s;
 s:=pg_get_functiondef('app_private.initialize_financial_types(uuid)'::regprocedure);
 s:=replace(s,'''interest_expense''','''operating_expense''');execute s;
end $$;
update public.financial_types set account=case account when 'interest_expense' then 'operating_expense' when 'other_assets' then 'equipment' end,revision=revision+1
where origin='custom' and account in ('interest_expense','other_assets');
alter table public.financial_types add constraint fixed_custom_categories check(origin='system' or account in ('withdrawals','operating_expense','capital','other_income','equipment'));

create function app_private.financial_category(account_code text) returns text language sql immutable set search_path='' as $$
 select case when account_code='withdrawals' then 'withdrawal' when account_code in ('operating_expense','interest_expense') then 'expense'
 when account_code='capital' then 'capital' when account_code='other_income' then 'revenue' when account_code in ('equipment','other_assets') then 'equipment' end;$$;
create or replace function public.get_financial_catalog() returns jsonb language plpgsql stable security definer set search_path='' as $$declare
 tenant uuid:=app_private.require_any_permission(array['finance:view','finance:manage','settings:manage','dashboard:view']);begin
 return jsonb_build_object('types',coalesce((select jsonb_agg(to_jsonb(ft)||jsonb_build_object('category',app_private.financial_category(ft.account)) order by ft.origin,ft.name)
 from public.financial_types ft where ft.tenant_id=tenant or ft.origin='system'),'[]'),
 'categories',(select jsonb_agg(jsonb_build_object('code',code,'name',name,'account',account) order by ordinal) from(values
 (1,'withdrawal','Withdrawal','withdrawals'),(2,'expense','Expense','operating_expense'),(3,'capital','Capital','capital'),(4,'revenue','Revenue','other_income'),(5,'equipment','Equipment','equipment'))c(ordinal,code,name,account)));
end $$;
create index financial_entries_page on public.financial_entries(tenant_id,occurred_on desc,created_at desc,entry_id);
create function public.get_financial_entries(p_filters jsonb default '{}',p_offset integer default 0,p_limit integer default 25) returns jsonb
language plpgsql stable security definer set search_path='' as $$declare
 tenant uuid:=app_private.require_any_permission(array['finance:view','finance:manage']);result jsonb;
 search text:=trim(coalesce(p_filters->>'search',''));category text:=nullif(p_filters->>'category','');business text:=nullif(p_filters->>'business','');begin
 if p_filters is null or jsonb_typeof(p_filters)<>'object' or length(search)>500 or p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100
 or category is not null and category not in ('withdrawal','expense','capital','revenue','equipment') or business is not null and business not in ('lpg','stove','logistics')
 or nullif(p_filters->>'from','')::date>nullif(p_filters->>'to','')::date then raise exception 'Invalid financial entry filters';end if;
 with matching as materialized(select e.* from public.financial_entries e where e.tenant_id=tenant
 and (category is null or app_private.financial_category(e.account)=category)
 and (nullif(p_filters->>'type','') is null or e.type_id=nullif(p_filters->>'type','')::uuid)
 and (business is null or e.allocations ? business)
 and (nullif(p_filters->>'from','') is null or e.occurred_on>=nullif(p_filters->>'from','')::date)
 and (nullif(p_filters->>'to','') is null or e.occurred_on<=nullif(p_filters->>'to','')::date)
 and (search='' or position(lower(search) in lower(e.type_name||' '||e.description))>0)),
 page as(select * from matching order by occurred_on desc,created_at desc,entry_id limit p_limit offset p_offset)
 select jsonb_build_object('total',(select count(*) from matching),'entries',coalesce((select jsonb_agg(to_jsonb(p)||jsonb_build_object(
 'category',app_private.financial_category(p.account),'returned',coalesce((select sum(r.amount) from public.financial_entries r where r.tenant_id=tenant and r.reversal_of=p.entry_id),0)) order by p.occurred_on desc,p.created_at desc,p.entry_id) from page p),'[]')) into result;return result;end $$;
alter function app_private.financial_category(text) owner to postgres;
alter function public.get_financial_entries(jsonb,integer,integer) owner to postgres;
revoke all on function app_private.financial_category(text) from public,anon,authenticated;
revoke all on function public.get_financial_entries(jsonb,integer,integer) from public,anon;
grant execute on function public.get_financial_entries(jsonb,integer,integer) to authenticated;

-- An account has one trusted organization. Reject foreign scope IDs and remove
-- the obsolete multi-organization access model from the public reporting path.
create or replace function app_private.analysis_scope(filters jsonb) returns uuid[] language plpgsql stable security definer set search_path='' as $$declare
 tenant uuid:=app_private.require_any_permission(array['finance:view','finance:manage']);begin
 if nullif(filters->>'business_id','') is not null and (filters->>'business_id')::uuid<>tenant then raise exception 'Business access denied' using errcode='42501';end if;
 return array[tenant];end $$;
do $$begin if exists(select 1 from public.business_analysis_access) then raise exception 'Review nonempty cross-organization grants before removing obsolete scope';end if;end $$;
drop function public.get_analysis_businesses();
drop function public.grant_business_analysis_access(uuid,boolean);
drop function app_private.analysis_businesses();
drop table public.business_analysis_access;
