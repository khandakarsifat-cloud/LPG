-- One customer projection supports current balances and unfiltered lifetime
-- directory sorts. Date/product scopes continue using indexed canonical rows.
create table app_private.customer_metrics (
 tenant_id uuid not null,customer_id uuid not null,ledger_balance numeric(20,2) not null default 0,
 transactions bigint not null default 0,refill bigint not null default 0,package bigint not null default 0,
 total_sold_amount numeric(20,2) not null default 0,total_due numeric(20,2) not null default 0,last_transaction_at timestamptz,
 primary key(tenant_id,customer_id),foreign key(tenant_id,customer_id) references public.customers(tenant_id,customer_id) on delete cascade
);
insert into app_private.customer_metrics
select c.tenant_id,c.customer_id,coalesce(x.balance,0),coalesce(s.n,0),coalesce(s.refill,0),coalesce(s.package,0),coalesce(s.sold,0),coalesce(s.due,0),s.last_at
from public.customers c left join lateral(select sum(amount) balance from public.customer_transactions x where x.tenant_id=c.tenant_id and x.customer_id=c.customer_id)x on true
left join lateral(select count(*) n,sum(s.total_amount+s.additional_charges) sold,sum(greatest(0,s.total_amount+s.additional_charges-s.paid_amount)) due,max(s.created_at) last_at,
 sum(q.refill) refill,sum(q.package) package from public.sales s left join lateral(select coalesce(sum(quantity) filter(where type='refill'),0) refill,coalesce(sum(quantity) filter(where type='package'),0) package from public.sale_items i where i.tenant_id=s.tenant_id and i.sale_id=s.sale_id)q on true
 where s.tenant_id=c.tenant_id and s.customer_id=c.customer_id and s.status='completed')s on true;

create function app_private.maintain_customer_metrics() returns trigger language plpgsql security definer set search_path='' as $$
declare t uuid:=new.tenant_id;c uuid;old_on integer:=0;new_on integer:=0;dq_refill bigint:=0;dq_package bigint:=0;begin
 if tg_table_name='customers' then
  insert into app_private.customer_metrics(tenant_id,customer_id) values(t,new.customer_id) on conflict do nothing;return new;
 elsif tg_table_name='customer_transactions' then
  insert into app_private.customer_metrics(tenant_id,customer_id,ledger_balance) values(t,new.customer_id,new.amount)
  on conflict(tenant_id,customer_id) do update set ledger_balance=customer_metrics.ledger_balance+excluded.ledger_balance;return new;
 elsif tg_table_name='sale_items' then
  select s.customer_id into c from public.sales s where s.tenant_id=t and s.sale_id=new.sale_id and s.status='completed';
  if c is not null then update app_private.customer_metrics set refill=refill+case when new.type='refill' then new.quantity else 0 end,package=package+case when new.type='package' then new.quantity else 0 end where tenant_id=t and customer_id=c;end if;return new;
 end if;
 c:=new.customer_id;if c is null then return new;end if;
 if tg_op='UPDATE' then
  if old.customer_id is distinct from new.customer_id then raise exception 'A saved sale cannot change customer';end if;
  old_on:=case when old.status='completed' then 1 else 0 end;
 end if;
 new_on:=case when new.status='completed' then 1 else 0 end;
 if tg_op='UPDATE' and old_on<>new_on then select coalesce(sum(quantity) filter(where type='refill'),0)*(new_on-old_on),coalesce(sum(quantity) filter(where type='package'),0)*(new_on-old_on) into dq_refill,dq_package from public.sale_items where tenant_id=t and sale_id=new.sale_id;end if;
 insert into app_private.customer_metrics(tenant_id,customer_id) values(t,c) on conflict do nothing;
 update app_private.customer_metrics set transactions=transactions+new_on-old_on,refill=refill+dq_refill,package=package+dq_package,
 total_sold_amount=total_sold_amount+new_on*(new.total_amount+new.additional_charges)-case when tg_op='UPDATE' then old_on*(old.total_amount+old.additional_charges) else 0 end,
 total_due=total_due+new_on*greatest(0,new.total_amount+new.additional_charges-new.paid_amount)-case when tg_op='UPDATE' then old_on*greatest(0,old.total_amount+old.additional_charges-old.paid_amount) else 0 end,
 last_transaction_at=case when new_on=1 then greatest(last_transaction_at,new.created_at) when old_on=1 and last_transaction_at=old.created_at then (select max(created_at) from public.sales where tenant_id=t and customer_id=c and status='completed') else last_transaction_at end
 where tenant_id=t and customer_id=c;
 return new;end $$;
create trigger maintain_customer_metrics after insert on public.customers for each row execute function app_private.maintain_customer_metrics();
create trigger maintain_customer_metrics after insert on public.customer_transactions for each row execute function app_private.maintain_customer_metrics();
create trigger maintain_customer_metrics after insert on public.sale_items for each row execute function app_private.maintain_customer_metrics();
create trigger maintain_customer_metrics after insert or update of status,total_amount,additional_charges,paid_amount,customer_id on public.sales for each row execute function app_private.maintain_customer_metrics();
create or replace function public.get_customer_balance(p_customer_id uuid) returns numeric language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['finance:view','finance:manage','customers:view','customers:manage']);r numeric;begin
 select -m.ledger_balance into r from public.customers c left join app_private.customer_metrics m using(tenant_id,customer_id) where c.tenant_id=t and c.customer_id=p_customer_id;
 if not found then raise exception 'Customer not found';end if;return coalesce(r,0);end $$;

-- A completed payroll sync is valid for this month until a term is appended.
-- The term trigger runs the same canonical sync and invalidates the marker.
create table app_private.payroll_sync_state(tenant_id uuid primary key references public.tenants(tenant_id),synced_month date not null);
create function app_private.invalidate_payroll_sync() returns trigger language plpgsql security definer set search_path='' as $$begin
 perform pg_advisory_xact_lock(hashtextextended(new.tenant_id::text||':accounting_payroll',0));
 delete from app_private.payroll_sync_state where tenant_id=new.tenant_id;return new;end $$;
create trigger aa_invalidate_payroll_sync after insert on public.employee_terms for each row execute function app_private.invalidate_payroll_sync();

create or replace function app_private.sync_payroll(t uuid,baseline boolean default false) returns void language plpgsql set search_path='' as $$
declare r record;m record;id uuid;amount numeric;lines jsonb;d date:=(now() at time zone 'Asia/Dhaka')::date;begin
 perform pg_advisory_xact_lock(hashtextextended(t::text||':accounting_payroll',0));
 if not baseline and exists(select 1 from app_private.payroll_sync_state where tenant_id=t and synced_month=date_trunc('month',d)::date) then return;end if;
 for r in select e.employee_id,min(et.effective_from) starts from public.employees e join public.employee_terms et using(tenant_id,employee_id) where e.tenant_id=t group by e.employee_id order by e.employee_id loop
  for m in select day::date period from generate_series(date_trunc('month',r.starts::timestamp),date_trunc('month',d::timestamp),'1 month') day loop
   id:=md5(r.employee_id::text||m.period::text)::uuid;amount:=(app_private.employee_month_balance(t,r.employee_id,m.period)->>'salary_amount')::numeric;
   lines:=jsonb_build_array(app_private.accounting_line('employee_expense',amount),app_private.accounting_line('employee_payable',-amount,'shared',r.employee_id));
   if baseline then insert into app_private.accounting_source_state(tenant_id,source,source_id,lines) values(t,'salary_accrual',id,lines) on conflict do nothing;
   else perform app_private.sync_journal(t,'salary_accrual',id,m.period,'Salary for '||m.period,lines,false);end if;
  end loop;
 end loop;
 if not baseline then insert into app_private.payroll_sync_state values(t,date_trunc('month',d)::date) on conflict(tenant_id) do update set synced_month=excluded.synced_month;end if;end $$;
create or replace function public.get_customer_directory(p_filters jsonb default '{}'::jsonb,p_offset integer default 0,p_limit integer default 12,p_customer_id uuid default null) returns jsonb
language plpgsql stable security definer set search_path='' set plan_cache_mode='force_custom_plan' as $$
declare
  t uuid:=app_private.require_any_permission(array['customers:view','customers:manage']);
  ids uuid[]; result jsonb; ordering text:=coalesce(p_filters->>'sort','name_asc');
  from_day date:=nullif(p_filters->>'from','')::date; to_day date:=nullif(p_filters->>'to','')::date;
  activity_filter boolean; page_first boolean;
begin
  perform app_private.validate_customer_filters(p_filters);
  if p_offset is null or p_limit is null or p_offset<0 or p_offset>1000000 or p_limit not between 1 and 100 then raise exception 'Invalid customer page'; end if;
  if jsonb_typeof(p_filters->'item_ids')='array' then select coalesce(array_agg(distinct value::uuid),'{}'::uuid[]) into ids from jsonb_array_elements_text(p_filters->'item_ids'); end if;
  activity_filter:=from_day is not null or to_day is not null or ids is not null
    or exists(select 1 from jsonb_each_text(p_filters) f
      where f.key in ('transactions_min','transactions_max','refill_min','refill_max','package_min','package_max') and nullif(f.value,'') is not null);
  -- Only unscoped name ordering can safely select customers before reading sales.
  -- Both paths share one relational sales scope and response shape.
  page_first:=not activity_filter and ordering in ('name_asc','name_desc');
  with candidates as materialized (
    select c.tenant_id,c.customer_id,c.name,c.phone,c.shop_name,c.address,
      case when c.tier='wholesale' then 'wholesale' else 'retail' end tier,c.created_at,
      coalesce(nullif(case when c.tier='wholesale' then c.shop_name end,''),c.name) display_name
    from public.customers c where c.tenant_id=t and (p_customer_id is null or c.customer_id=p_customer_id)
      and (coalesce(p_filters->>'tier','all')='all' or p_filters->>'tier'=case when c.tier='wholesale' then 'wholesale' else 'retail' end)
      and (not exists(select 1 from regexp_split_to_table(coalesce(p_filters->>'search',''),'\s*,\s*') g where btrim(g)<>'')
        or exists(select 1 from regexp_split_to_table(lower(p_filters->>'search'),'\s*,\s*') g where btrim(g)<>'' and not exists(
          select 1 from regexp_split_to_table(btrim(g),'\s+') token where token<>''
          and position(token in lower(concat_ws(' ',c.name,c.shop_name,c.phone,c.address,c.tier,
            case when c.phone like '08801%' then substring(c.phone from 4) else '088'||c.phone end)))=0)))
  ), scoped_customers as materialized (
    select * from candidates order by
      case when page_first and ordering='name_asc' then lower(display_name) end asc,
      case when page_first and ordering='name_desc' then lower(display_name) end desc,customer_id
    limit case when page_first then p_limit end offset case when page_first then p_offset else 0 end
  ), headers as materialized (
    select s.customer_id,s.sale_id,s.created_at,s.total_amount+s.additional_charges total_amount,
      greatest(0,s.total_amount+s.additional_charges-s.paid_amount) due
    from public.sales s join scoped_customers c on c.customer_id=s.customer_id
    where s.tenant_id=t and s.status='completed' and (from_day is not null or to_day is not null or ids is not null)
      and (from_day is null or s.created_at >= (from_day::timestamp at time zone 'Asia/Dhaka'))
      and (to_day is null or s.created_at < ((to_day+1)::timestamp at time zone 'Asia/Dhaka'))
  ), quantities as (
    select si.sale_id,
      sum(si.quantity) filter(where si.type='refill') refill,
      sum(si.quantity) filter(where si.type='package') package
    from public.sale_items si join headers h on h.sale_id=si.sale_id
    where si.tenant_id=t and si.type in ('refill','package') and (ids is null or si.item_id=any(ids))
    group by si.sale_id
  ), qualifying as (
    select h.*,coalesce(q.refill,0) refill,coalesce(q.package,0) package
    from headers h left join quantities q on q.sale_id=h.sale_id
    where ids is null or q.sale_id is not null
  ), activity as materialized (
    select a.customer_id,count(*) transactions,sum(a.refill) refill,sum(a.package) package,
      sum(a.total_amount) total_sold_amount,sum(a.due) total_due,max(a.created_at) last_transaction_at
    from qualifying a group by a.customer_id
    union all select m.customer_id,m.transactions,m.refill,m.package,m.total_sold_amount,m.total_due,m.last_transaction_at from app_private.customer_metrics m join scoped_customers c on c.customer_id=m.customer_id where m.tenant_id=t and from_day is null and to_day is null and ids is null
  ), filtered as materialized (
    select c.*,coalesce(a.transactions,0) transactions,coalesce(a.refill,0) refill,coalesce(a.package,0) package,
      coalesce(a.refill,0)+coalesce(a.package,0) total_sold,
      coalesce(a.total_sold_amount,0) total_sold_amount,coalesce(a.total_due,0) total_due,a.last_transaction_at
    from scoped_customers c left join activity a on a.customer_id=c.customer_id
    where (not activity_filter or a.transactions>0)
      and coalesce(a.transactions,0)>=coalesce(nullif(p_filters->>'transactions_min','')::bigint,0)
      and (nullif(p_filters->>'transactions_max','') is null or a.transactions<=(p_filters->>'transactions_max')::bigint)
      and coalesce(a.refill,0)>=coalesce(nullif(p_filters->>'refill_min','')::bigint,0)
      and (nullif(p_filters->>'refill_max','') is null or a.refill<=(p_filters->>'refill_max')::bigint)
      and coalesce(a.package,0)>=coalesce(nullif(p_filters->>'package_min','')::bigint,0)
      and (nullif(p_filters->>'package_max','') is null or a.package<=(p_filters->>'package_max')::bigint)
  ), ranked as (
    select f.*,row_number() over(order by
      case when ordering='name_asc' then lower(display_name) end asc,
      case when ordering='name_desc' then lower(display_name) end desc,
      case when ordering='sold_asc' then total_sold_amount end asc,
      case when ordering='sold_desc' then total_sold_amount end desc,
      case when ordering='due_asc' then total_due end asc,
      case when ordering='due_desc' then total_due end desc,
      case when ordering='last_sale_asc' then last_transaction_at end asc nulls last,
      case when ordering='last_sale_desc' then last_transaction_at end desc nulls last,customer_id) ordinal
    from filtered f
  ), page as (
    select * from ranked order by ordinal limit p_limit offset case when page_first then 0 else p_offset end
  ) select jsonb_build_object('total',case when page_first then (select count(*) from candidates) else (select count(*) from filtered) end,
    'entries',coalesce((select jsonb_agg(to_jsonb(p)-'ordinal' order by ordinal) from page p),'[]'::jsonb)) into result;
  return result;
end $$;
-- Durable changed-record queue and append-only diagnostic history. Scheduling
-- never supplies correctness: source writes already maintain their projections.
create table app_private.reconciliation_queue (
 tenant_id uuid not null,kind text not null,entity_id uuid not null,generation bigint not null default 1,
 changed_at timestamptz not null default clock_timestamp(),available_at timestamptz not null,attempts integer not null default 0,
 primary key(tenant_id,kind,entity_id)
);
create index reconciliation_due on app_private.reconciliation_queue(available_at,changed_at);
create table app_private.reconciliation_findings (
 finding_id bigint generated always as identity primary key,tenant_id uuid not null,kind text not null,entity_id uuid not null,
 observed jsonb not null,expected jsonb not null,status text not null check(status in ('repaired','unresolved','error')),
 diagnostic text not null,recorded_at timestamptz not null default clock_timestamp()
);
create index reconciliation_tenant_findings on app_private.reconciliation_findings(tenant_id,recorded_at desc);
create table app_private.reconciliation_runs (
 run_id bigint generated always as identity primary key,started_at timestamptz not null default clock_timestamp(),finished_at timestamptz,
 checked integer not null default 0,discrepancies integer not null default 0,errors integer not null default 0
);
create table app_private.reconciliation_sweeps (
 kind text primary key,last_tenant uuid,last_entity uuid,started_at timestamptz not null default clock_timestamp(),completed_at timestamptz
);
create function app_private.queue_reconciliation(t uuid,k text,id uuid,due timestamptz default null) returns void language sql set search_path='' as $$
 insert into app_private.reconciliation_queue(tenant_id,kind,entity_id,available_at) values(t,k,id,
 coalesce(due,((case when (clock_timestamp() at time zone 'Asia/Dhaka')::time<'03:00'::time then (clock_timestamp() at time zone 'Asia/Dhaka')::date else (clock_timestamp() at time zone 'Asia/Dhaka')::date+1 end+time '03:00') at time zone 'Asia/Dhaka')))
 on conflict(tenant_id,kind,entity_id) do update set generation=reconciliation_queue.generation+1,changed_at=clock_timestamp(),available_at=least(reconciliation_queue.available_at,excluded.available_at),attempts=0;$$;
create function app_private.mark_reconciliation() returns trigger language plpgsql security definer set search_path='' as $$
declare row jsonb:=to_jsonb(new);k text;id uuid;begin
 k:=tg_argv[0];id:=case when k='snapshot' then md5(row->>'month_end')::uuid else (row->>tg_argv[1])::uuid end;
 if id is not null then perform app_private.queue_reconciliation(new.tenant_id,k,id);end if;return new;end $$;
create trigger reconciliation_changed after insert or update on public.wallets for each row execute function app_private.mark_reconciliation('wallet','wallet_id');
create trigger reconciliation_changed after insert or update on public.items for each row execute function app_private.mark_reconciliation('inventory','item_id');
create trigger reconciliation_changed after insert or update on app_private.customer_metrics for each row execute function app_private.mark_reconciliation('customer','customer_id');
create trigger reconciliation_changed after insert or update on public.loans for each row execute function app_private.mark_reconciliation('loan','loan_id');
create trigger reconciliation_changed after insert on public.employee_payments for each row execute function app_private.mark_reconciliation('payroll','employee_id');
create trigger reconciliation_changed after insert on public.employee_terms for each row execute function app_private.mark_reconciliation('payroll','employee_id');
create trigger reconciliation_changed after insert or update on public.finance_obligations for each row execute function app_private.mark_reconciliation('obligation','obligation_id');
create trigger reconciliation_changed after insert or update on public.business_assets for each row execute function app_private.mark_reconciliation('asset','asset_id');
create trigger reconciliation_changed after insert or update on public.supplier_commissions for each row execute function app_private.mark_reconciliation('commission','commission_id');
create trigger reconciliation_source after insert or update of status,total_amount,additional_charges on public.sales for each row execute function app_private.mark_reconciliation('sale','sale_id');
create trigger reconciliation_source after insert or update of status,payable_amount on public.purchases for each row execute function app_private.mark_reconciliation('purchase','purchase_id');
create trigger reconciliation_source after insert or update on public.transits for each row execute function app_private.mark_reconciliation('transit','transit_id');
create trigger reconciliation_source after insert on public.operating_cost_events for each row execute function app_private.mark_reconciliation('transit','transit_id');
-- Immutable journals have a deferred balance constraint on every write. Weekly
-- sweeps verify them again without a redundant changed queue row per journal.
create trigger reconciliation_changed after insert or update on app_private.accounting_snapshots for each row execute function app_private.mark_reconciliation('snapshot','tenant_id');

create function app_private.reconcile_record(t uuid,k text,id uuid) returns boolean language plpgsql set search_path='' as $$
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
  observed:=jsonb_build_object('balance',v);
  expected:=jsonb_build_object('balance',v2);
  if v is distinct from v2 and v2=coalesce((select sum(amount) from public.accounting_lines where tenant_id=t and account='cash' and entity_id=id),0) then update public.wallets set balance=v2 where tenant_id=t and wallet_id=id;safe:=true;end if;
  if v2 is distinct from coalesce((select sum(amount) from public.accounting_lines where tenant_id=t and account='cash' and entity_id=id),0) then expected:=expected||jsonb_build_object('journal_cash',(select sum(amount) from public.accounting_lines where tenant_id=t and account='cash' and entity_id=id));safe:=false;end if;
 elsif k='inventory' then
  -- Never repair physical stock from a financial discrepancy. Cost evidence and
  -- movement coverage must agree before an operator can investigate a count.
  perform 1 from public.items where tenant_id=t and item_id=id for update nowait;
  if not found then return false;end if;
  perform 1 from public.inventory_costs where tenant_id=t and item_id=id for update nowait;
  select jsonb_build_object('filled',i.filled_quantity,'empty',i.empty_quantity,'pool_filled',c.filled_quantity,'pool_empty',c.empty_quantity,'filled_value',c.filled_value,'empty_value',c.empty_value,'journal_value',c.filled_value+c.empty_value,'missing_movements',0) into observed from public.items i join public.inventory_costs c using(tenant_id,item_id) where i.tenant_id=t and i.item_id=id;
  select jsonb_build_object('filled',coalesce(sum(filled_change),0),'empty',coalesce(sum(empty_change),0),'pool_filled',coalesce(sum(filled_change),0),'pool_empty',coalesce(sum(empty_change),0),'filled_value',coalesce(sum(filled_value),0),'empty_value',coalesce(sum(empty_value),0),
   'journal_value',coalesce((select sum(amount) from public.accounting_lines where tenant_id=t and entity_id=id and account in ('inventory_lpg','inventory_stove')),0),
   'missing_movements',(select count(*) from public.inventory_movements m where m.tenant_id=t and m.item_id=id and not exists(select 1 from public.inventory_cost_entries e where e.tenant_id=t and e.movement_id=m.movement_id))) into expected from public.inventory_cost_entries where tenant_id=t and item_id=id;
 elsif k='loan' then
  perform 1 from public.loans where tenant_id=t and loan_id=id for update nowait;
  if not found then return false;end if;
  select jsonb_build_object('outstanding',outstanding) into observed from public.loans where tenant_id=t and loan_id=id;
  select jsonb_build_object('outstanding',principal-coalesce((select sum(amount) from public.loan_activity where tenant_id=t and loan_id=id and action='principal repayment'),0)) into expected from public.loans where tenant_id=t and loan_id=id;
 elsif k='asset' then
  perform 1 from public.business_assets where tenant_id=t and asset_id=id for update nowait;
  if not found then return false;end if;
  select jsonb_build_object('book_value',case when status='active' then cost-accumulated_depreciation else 0 end) into observed from public.business_assets where tenant_id=t and asset_id=id;
  select jsonb_build_object('book_value',coalesce(sum(amount),0)) into expected from public.accounting_lines where tenant_id=t and entity_id=id and account in ('vehicles','equipment','other_assets');
 elsif k='commission' then
  perform 1 from public.supplier_commissions where tenant_id=t and commission_id=id for update nowait;
  if not found then return false;end if;
  select jsonb_build_object('used',used) into observed from public.supplier_commissions where tenant_id=t and commission_id=id;
  select jsonb_build_object('used',coalesce(sum(case when reversal_of is null then amount else -amount end),0)) into expected from public.commission_applications where tenant_id=t and commission_id=id;
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
  with full_history as(select l.account,l.business_category,l.entity_id,sum(l.amount) amount from public.accounting_lines l join public.accounting_journals j using(tenant_id,journal_id) where j.tenant_id=t and j.occurred_on<=d group by 1,2,3),
  diff as(select * from full_history except select account,business_category,entity_id,amount from app_private.accounting_snapshot_lines where tenant_id=t and month_end=d),
  reverse_diff as(select account,business_category,entity_id,amount from app_private.accounting_snapshot_lines where tenant_id=t and month_end=d except select * from full_history)
  select jsonb_build_object('checksum',md5(coalesce((select string_agg(concat_ws(':',account,business_category,entity_id,amount),'|' order by account,business_category,entity_id) from full_history),'')),'difference',(select count(*) from diff)+(select count(*) from reverse_diff)) into expected;
  if observed is distinct from expected then update app_private.accounting_snapshot_state set invalid_from=least(invalid_from,d) where tenant_id=t;note:='Savepoint invalidated; canonical journals remain unchanged';end if;
 else raise exception 'Unknown reconciliation kind';end if;
 if observed is null and expected is null then return false;end if;
 if observed is distinct from expected then
  insert into app_private.reconciliation_findings(tenant_id,kind,entity_id,observed,expected,status,diagnostic) values(t,k,id,coalesce(observed,'null'),coalesce(expected,'null'),case when safe then 'repaired' else 'unresolved' end,note);return true;
 end if;return false;end $$;

create function app_private.start_reconciliation_sweep() returns void language sql set search_path='' as $$
 insert into app_private.reconciliation_sweeps(kind) select unnest(array['customer','wallet','inventory','loan','payroll','obligation','asset','commission','sale','purchase','transit','journal','snapshot'])
 on conflict(kind) do update set last_tenant=null,last_entity=null,started_at=clock_timestamp(),completed_at=null where reconciliation_sweeps.completed_at is not null;$$;

create function app_private.reconciliation_sweep_batch(batch_size integer default 100) returns integer language plpgsql set search_path='' as $$
declare s record;r record;table_name text;key_name text;n integer:=0;query text;begin
 if batch_size not between 1 and 200 then raise exception 'Invalid sweep batch';end if;
 select * into s from app_private.reconciliation_sweeps where completed_at is null order by started_at,kind limit 1;
 if not found then return 0;end if;
 select x.tbl,x.key into table_name,key_name from(values('customer','customers','customer_id'),('wallet','wallets','wallet_id'),('inventory','items','item_id'),('loan','loans','loan_id'),('payroll','employees','employee_id'),('obligation','finance_obligations','obligation_id'),('asset','business_assets','asset_id'),('commission','supplier_commissions','commission_id'),('sale','sales','sale_id'),('purchase','purchases','purchase_id'),('transit','transits','transit_id'),('journal','accounting_journals','journal_id'))x(kind,tbl,key) where x.kind=s.kind;
 if s.kind='snapshot' then query:='select tenant_id,md5(month_end::text)::uuid id from app_private.accounting_snapshots where ($1 is null or (tenant_id,md5(month_end::text)::uuid)>($1,$2)) order by tenant_id,id limit $3';
 else query:=format('select tenant_id,%I id from public.%I where ($1 is null or (tenant_id,%I)>($1,$2)) order by tenant_id,%I limit $3',key_name,table_name,key_name,key_name);end if;
 for r in execute query using s.last_tenant,s.last_entity,batch_size loop
  perform app_private.queue_reconciliation(r.tenant_id,s.kind,r.id,clock_timestamp());n:=n+1;
  update app_private.reconciliation_sweeps set last_tenant=r.tenant_id,last_entity=r.id where kind=s.kind;
 end loop;
 if n<batch_size then update app_private.reconciliation_sweeps set completed_at=clock_timestamp() where kind=s.kind;end if;return n;end $$;

create function app_private.run_accounting_maintenance(batch_size integer default 40) returns jsonb language plpgsql set search_path='' as $$
declare r record;t uuid;n integer:=0;problems integer:=0;errs integer:=0;run bigint;deadline timestamptz:=clock_timestamp()+interval '15 seconds';begin
 if batch_size not between 1 and 100 then raise exception 'Invalid reconciliation batch';end if;
 if not pg_try_advisory_xact_lock(hashtextextended('lpg:accounting:maintenance',0)) then return jsonb_build_object('skipped','already running');end if;
 if not exists(select 1 from app_private.reconciliation_queue where available_at<=clock_timestamp()) and not exists(select 1 from app_private.reconciliation_sweeps where completed_at is null) then return jsonb_build_object('idle',true);end if;
 insert into app_private.reconciliation_runs default values returning run_id into run;
 perform app_private.reconciliation_sweep_batch(100);
 for r in select * from app_private.reconciliation_queue where available_at<=clock_timestamp() order by changed_at limit batch_size loop
  exit when clock_timestamp()>deadline;
  begin
   if r.kind='payroll' then perform app_private.sync_payroll(r.tenant_id);end if;
   if app_private.reconcile_record(r.tenant_id,r.kind,r.entity_id) then problems:=problems+1;end if;
   delete from app_private.reconciliation_queue where tenant_id=r.tenant_id and kind=r.kind and entity_id=r.entity_id and generation=r.generation;
  exception when lock_not_available then
   update app_private.reconciliation_queue set available_at=clock_timestamp()+interval '1 minute' where tenant_id=r.tenant_id and kind=r.kind and entity_id=r.entity_id;
  when others then
   errs:=errs+1;
   insert into app_private.reconciliation_findings(tenant_id,kind,entity_id,observed,expected,status,diagnostic) values(r.tenant_id,r.kind,r.entity_id,'{}','{}','error','Reconciliation failed: '||sqlstate||' · '||left(sqlerrm,500));
   update app_private.reconciliation_queue set attempts=attempts+1,available_at=clock_timestamp()+case when attempts>=4 then interval '1 day' else interval '10 minutes' end where tenant_id=r.tenant_id and kind=r.kind and entity_id=r.entity_id;
  end;n:=n+1;
 end loop;
 update app_private.reconciliation_runs set finished_at=clock_timestamp(),checked=n,discrepancies=problems,errors=errs where run_id=run;
 return jsonb_build_object('checked',n,'discrepancies',problems,'errors',errs);end $$;

-- Snapshot building only takes projection locks. Keep it in its own job so it
-- never holds those locks while requesting an operational record lock.
create function app_private.run_snapshot_maintenance() returns integer language plpgsql set search_path='' as $$declare t uuid;begin
 if not pg_try_advisory_xact_lock(hashtextextended('lpg:accounting:snapshots',0)) then return 0;end if;
 select tenant_id into t from app_private.accounting_snapshot_state where invalid_from<date_trunc('month',now() at time zone 'Asia/Dhaka')::date order by invalid_from,tenant_id limit 1;
 if t is null then return 0;end if;return app_private.build_accounting_snapshots(t,3);end $$;

-- Only trusted, authorized analysis scope can read diagnostics. Global scheduler
-- state and other businesses' findings are never exposed through this RPC.
create function public.get_accounting_health(p_filters jsonb,p_offset integer default 0) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare ids uuid[]:=app_private.analysis_scope(p_filters);r jsonb;begin
 if p_offset is null or p_offset<0 or p_offset>1000000 then raise exception 'Invalid diagnostic page';end if;
 select jsonb_build_object('pending',(select count(*) from app_private.reconciliation_queue where tenant_id=any(ids)),
 'snapshots',(select count(*) from app_private.accounting_snapshots s join app_private.accounting_snapshot_state st using(tenant_id) where s.tenant_id=any(ids) and s.month_end<st.invalid_from),
 'total',(select count(*) from app_private.reconciliation_findings where tenant_id=any(ids)),
 'entries',coalesce((select jsonb_agg(to_jsonb(f) order by finding_id desc) from(select * from app_private.reconciliation_findings where tenant_id=any(ids) order by finding_id desc offset p_offset limit 20)f),'[]')) into r;return r;end $$;
revoke all on function public.get_accounting_health(jsonb,integer) from public,anon;
grant execute on function public.get_accounting_health(jsonb,integer) to authenticated;

-- Current outstanding invoices need only the small unpaid subset.
create index sales_unpaid_directory on public.sales(tenant_id,created_at desc,sale_id) include(customer_id,total_amount,additional_charges,paid_amount)
 where status='completed' and paid_amount<total_amount+additional_charges;

do $$declare n text;f record;begin
 foreach n in array array['customer_metrics','payroll_sync_state','reconciliation_queue','reconciliation_findings','reconciliation_runs','reconciliation_sweeps'] loop
  execute format('alter table app_private.%I enable row level security',n);
  execute format('revoke all on app_private.%I from public,anon,authenticated',n);
 end loop;
 for f in select p.oid::regprocedure signature from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace where ns.nspname='app_private' and p.proname in ('maintain_customer_metrics','invalidate_payroll_sync','queue_reconciliation','mark_reconciliation','reconcile_record','start_reconciliation_sweep','reconciliation_sweep_batch','run_accounting_maintenance','run_snapshot_maintenance') loop
  execute format('revoke all on function %s from public,anon,authenticated',f.signature);
 end loop;
end $$;

-- pg_cron is already preloaded on the VPS. Install only in its configured
-- database; disposable restore tests deliberately do not register live jobs.
do $$begin
 if current_database()=current_setting('cron.database_name',true) then
  create extension if not exists pg_cron;
  perform cron.schedule('lpg-accounting-maintenance','* * * * *','set statement_timeout=''25s''; select app_private.run_accounting_maintenance();');
  perform cron.schedule('lpg-accounting-snapshots','* * * * *','set statement_timeout=''25s''; select app_private.run_snapshot_maintenance();');
  -- cron uses UTC here: 21:00 UTC is 03:00 Asia/Dhaka the following day.
  perform cron.schedule('lpg-accounting-daily','0 21 * * *','select app_private.run_accounting_maintenance(100);');
  perform cron.schedule('lpg-accounting-weekly','0 21 * * 4','select app_private.start_reconciliation_sweep();');
  perform cron.schedule('lpg-accounting-month-end','5 21 * * *','select app_private.start_reconciliation_sweep() where extract(day from now() at time zone ''Asia/Dhaka'')=1;');
 end if;end $$;
select app_private.start_reconciliation_sweep();

do $$declare f record;begin
 alter table app_private.customer_metrics owner to postgres;
 alter table app_private.payroll_sync_state owner to postgres;
 alter table app_private.reconciliation_queue owner to postgres;
 alter table app_private.reconciliation_findings owner to postgres;
 alter table app_private.reconciliation_runs owner to postgres;
 alter table app_private.reconciliation_sweeps owner to postgres;
 for f in select p.oid::regprocedure signature from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace where ns.nspname in ('app_private','public') and p.proname in ('maintain_customer_metrics','invalidate_payroll_sync','queue_reconciliation','mark_reconciliation','reconcile_record','start_reconciliation_sweep','reconciliation_sweep_batch','run_accounting_maintenance','run_snapshot_maintenance','get_accounting_health') loop execute format('alter function %s owner to postgres',f.signature);end loop;
end $$;
