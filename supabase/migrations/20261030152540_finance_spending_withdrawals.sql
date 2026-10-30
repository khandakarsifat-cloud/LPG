create table public.spending_categories (
 tenant_id uuid not null references public.tenants(tenant_id),category_id uuid not null default gen_random_uuid(),
 name text not null check(length(trim(name)) between 1 and 80),classification text not null check(classification in ('cost','withdrawal')),
 is_active boolean not null default true,revision integer not null default 1,primary key(tenant_id,category_id)
);
create unique index spending_category_name on public.spending_categories(tenant_id,lower(name));
create table public.spendings (
 tenant_id uuid not null,spending_id uuid not null default gen_random_uuid(),category_id uuid not null,
 category_name text not null,classification text not null check(classification in ('cost','withdrawal')),
 wallet_id uuid not null,wallet_name text not null,amount numeric(14,2) not null check(amount>0 and amount<10000000000),
 spending_date date not null check(isfinite(spending_date)),description text not null check(length(trim(description)) between 1 and 1000),
 created_at timestamptz not null default clock_timestamp(),created_by uuid not null references auth.users(id),
 primary key(tenant_id,spending_id),foreign key(tenant_id,category_id) references public.spending_categories(tenant_id,category_id),
 foreign key(tenant_id,wallet_id) references public.wallets(tenant_id,wallet_id)
);
create index spending_directory on public.spendings(tenant_id,spending_date desc,created_at desc,spending_id);
create index spending_category_history on public.spendings(tenant_id,category_id,spending_date desc);
alter table public.spending_categories enable row level security;
alter table public.spendings enable row level security;
revoke all on public.spending_categories,public.spendings from public,anon,authenticated;
create trigger immutable_spending before update or delete on public.spendings for each row execute function app_private.immutable_finance_record();
create function app_private.initialize_spending_categories(t uuid) returns void language sql set search_path='' as $$
 insert into public.spending_categories(tenant_id,name,classification) values(t,'Business','cost'),(t,'Logistics','cost'),(t,'Home','withdrawal'),(t,'Others','withdrawal') on conflict do nothing;
$$;
select app_private.initialize_spending_categories(tenant_id) from public.tenants;
create function app_private.spending_categories_created() returns trigger language plpgsql set search_path='' as $$ begin perform app_private.initialize_spending_categories(new.tenant_id);return new;end $$;
create trigger spending_categories_created after insert on public.tenants for each row execute function app_private.spending_categories_created();
create function public.get_spending_categories() returns setof public.spending_categories language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['finance:view','finance:manage','settings:manage']);begin return query select * from public.spending_categories where tenant_id=t order by lower(name),category_id;end $$;
create function public.save_spending_category(p_payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('settings:manage');id uuid:=nullif(p_payload->>'category_id','')::uuid;
begin
 if nullif(trim(p_payload->>'name'),'') is null or length(p_payload->>'name')>80 or (p_payload->>'classification') is null or p_payload->>'classification' not in ('cost','withdrawal') then raise exception 'Name and cost/withdrawal classification are required';end if;
 if id is null then insert into public.spending_categories(tenant_id,name,classification) values(t,trim(p_payload->>'name'),p_payload->>'classification') returning category_id into id;
 else update public.spending_categories set name=trim(p_payload->>'name'),classification=p_payload->>'classification',is_active=coalesce((p_payload->>'is_active')::boolean,true),revision=revision+1 where tenant_id=t and category_id=id and revision=(p_payload->>'revision')::integer;
 if not found then raise exception 'Category changed. Reload before saving.';end if;end if;
 return jsonb_build_object('category_id',id);
end $$;
create function public.record_spending(p_payload jsonb,p_request_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('finance:manage');prior public.finance_requests;body jsonb:=jsonb_build_object('action','spending','actor',auth.uid(),'body',p_payload);
 c public.spending_categories;w public.wallets;id uuid;result jsonb;amount numeric:=app_private.purchase_money((p_payload->>'amount')::numeric);d date:=(p_payload->>'spending_date')::date;
begin
 if p_request_id is null then raise exception 'Request ID is required';end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload<>body then raise exception 'Request ID was already used with different details';end if;return prior.result;end if;
 if amount<=0 or d is null or not isfinite(d) or d>(now() at time zone 'Asia/Dhaka')::date or nullif(trim(p_payload->>'description'),'') is null or length(p_payload->>'description')>1000 then raise exception 'Enter a positive amount, a valid past/current date and a description';end if;
 select * into c from public.spending_categories where tenant_id=t and category_id=(p_payload->>'category_id')::uuid for share;
 if not found or not c.is_active then raise exception 'Choose an active category belonging to this business';end if;
 if p_payload->>'classification' is distinct from c.classification or p_payload->>'category_name' is distinct from c.name then raise exception 'Category changed. Reload before confirming this entry.';end if;
 select * into w from public.wallets where tenant_id=t and wallet_id=(p_payload->>'wallet_id')::uuid for update;
 if not found or not w.is_active then raise exception 'Choose an active wallet belonging to this business';end if;
 insert into public.spendings(tenant_id,category_id,category_name,classification,wallet_id,wallet_name,amount,spending_date,description,created_by)
 values(t,c.category_id,c.name,c.classification,w.wallet_id,w.name,amount,d,trim(p_payload->>'description'),auth.uid()) returning spending_id into id;
 insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description,operation_id)
 values(t,w.wallet_id,-amount,case c.classification when 'cost' then 'business_spending' else 'owner_withdrawal' end,id,c.name||' · '||d::text||' · '||trim(p_payload->>'description'),p_request_id);
 result:=jsonb_build_object('spending_id',id);
 insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,result,auth.uid());return result;
end $$;
create function public.get_spendings(p_filters jsonb default '{}',p_offset integer default 0,p_limit integer default 12) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['finance:view','finance:manage']);result jsonb;begin
 if p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 100 or length(coalesce(p_filters->>'search',''))>500 or coalesce(p_filters->>'classification','') not in ('','cost','withdrawal') or nullif(p_filters->>'from','')::date>nullif(p_filters->>'to','')::date then raise exception 'Invalid spending filters';end if;
 with matching as materialized(select * from public.spendings s where tenant_id=t
 and app_private.finance_search(concat_ws(' ',s.category_name,s.description,s.wallet_name),p_filters->>'search')
 and (nullif(p_filters->>'classification','') is null or s.classification=p_filters->>'classification')
 and (nullif(p_filters->>'category_id','') is null or s.category_id=(p_filters->>'category_id')::uuid)
 and (nullif(p_filters->>'from','') is null or s.spending_date>=(p_filters->>'from')::date) and (nullif(p_filters->>'to','') is null or s.spending_date<=(p_filters->>'to')::date)),
 page as(select * from matching order by spending_date desc,created_at desc,spending_id desc offset p_offset limit p_limit)
 select jsonb_build_object('total',(select count(*) from matching),'costs',(select coalesce(sum(amount),0) from matching where classification='cost'),'withdrawals',(select coalesce(sum(amount),0) from matching where classification='withdrawal'),'entries',coalesce((select jsonb_agg(to_jsonb(p) order by spending_date desc,created_at desc,spending_id desc) from page p),'[]')) into result;return result;
end $$;
create function public.get_vehicle_crew_options(p_role text) returns table(employee_id uuid,name text) language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('logistics:manage');begin
 if p_role not in ('Driver','Helper') or p_role is null then raise exception 'Choose Driver or Helper';end if;
 return query select e.employee_id,e.name::text from public.employees e join public.employee_types et using(tenant_id,employee_type_id)
 where e.tenant_id=t and et.name=p_role and et.is_active and coalesce((select r.is_active from public.employee_terms r where r.tenant_id=t and r.employee_id=e.employee_id and r.effective_from<=(now() at time zone 'Asia/Dhaka')::date order by r.effective_from desc,r.created_at desc,r.term_id desc limit 1),false) order by e.name,e.employee_id;
end $$;
do $$ declare r record;begin
 for r in select p.oid,n.nspname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','app_private') and p.proname in ('initialize_spending_categories','spending_categories_created','get_spending_categories','save_spending_category','record_spending','get_spendings','get_vehicle_crew_options') loop
 execute format('alter function %s owner to postgres',r.oid::regprocedure);execute format('revoke all on function %s from public,anon,authenticated',r.oid::regprocedure);if r.nspname='public' then execute format('grant execute on function %s to authenticated',r.oid::regprocedure);end if;end loop;
end $$;
alter table public.spending_categories owner to postgres;
alter table public.spendings owner to postgres;
notify pgrst,'reload schema';
