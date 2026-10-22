-- Preserve the existing wallet IDs, signed balances and references. Dealership
-- remains the purchase funding key; its user-facing identity is Primary Bank.
alter table public.wallets drop constraint wallets_tenant_id_type_key;
alter table public.wallets alter column type type text using type::text;
alter table public.wallets add column name text, add column kind text,
  add column is_active boolean not null default true,
  add column opening_balance numeric(15,2) not null default 0,
  add column details text not null default '', add column revision integer not null default 1;
update public.wallets w set name=labels.name,kind=labels.kind,
  opening_balance=balance-coalesce((select sum(amount) from public.wallet_transactions x where x.tenant_id=w.tenant_id and x.wallet_id=w.wallet_id),0)
  from (values ('dealership','Primary Bank Account','bank'),('logistics','Logistics','logistics')) labels(type,name,kind) where w.type=labels.type;
alter table public.wallets alter column name set not null, alter column kind set not null;
alter table public.wallets add constraint wallet_type_valid check(type in ('dealership','logistics','cash','bkash','nagad','custom')),
  add constraint wallet_kind_valid check(kind in ('cash','bank','bkash','nagad','other','logistics')),
  add constraint wallet_name_valid check(length(trim(name)) between 1 and 80),
  add constraint wallet_finite check(balance not in ('NaN'::numeric,'Infinity'::numeric,'-Infinity'::numeric)),
  add constraint wallet_system_active check(type='custom' or is_active);
create unique index wallet_system_once on public.wallets(tenant_id,type) where type<>'custom';
create unique index wallet_name_once on public.wallets(tenant_id,lower(trim(name)));

-- A baseline accounts for historical operations which never wrote ledger rows.
-- It is not new income and does not change a balance.
alter table public.wallet_transactions add column balance_after numeric(15,2),
  add column search_document text not null default '',
  add column entry_no bigint generated always as identity,
  add column created_by uuid, add column counterparty_wallet_id uuid,
  add column operation_id uuid, add column payment_id uuid;
with balances as (
 select x.tenant_id,x.transaction_id,w.opening_balance+sum(x.amount) over
   (partition by x.tenant_id,x.wallet_id order by x.created_at,x.transaction_id rows unbounded preceding) balance
 from public.wallet_transactions x join public.wallets w using(tenant_id,wallet_id)
) update public.wallet_transactions x set balance_after=b.balance from balances b
  where x.tenant_id=b.tenant_id and x.transaction_id=b.transaction_id;
alter table public.wallet_transactions alter column balance_after set not null;
update public.wallet_transactions x set search_document=lower(concat_ws(' ',x.description,x.type,x.reference_id,x.transaction_id,w.name))
 from public.wallets w where w.tenant_id=x.tenant_id and w.wallet_id=x.wallet_id;
create extension if not exists pg_trgm with schema extensions;
create index wallet_ledger_search on public.wallet_transactions using gin(search_document extensions.gin_trgm_ops);
alter table public.wallet_transactions add constraint wallet_entry_actor_fk foreign key(tenant_id,created_by) references public.user_profiles(tenant_id,user_id),
  add constraint wallet_entry_counterparty_fk foreign key(tenant_id,counterparty_wallet_id) references public.wallets(tenant_id,wallet_id);
create index wallet_ledger_date on public.wallet_transactions(tenant_id,created_at desc,entry_no desc);
create index wallet_ledger_wallet_date on public.wallet_transactions(tenant_id,wallet_id,created_at desc,entry_no desc);
create index wallet_ledger_type_date on public.wallet_transactions(tenant_id,type,created_at desc,entry_no desc);
create index wallet_ledger_amount on public.wallet_transactions(tenant_id,abs(amount));

create function app_private.initialize_wallets(t uuid) returns void language sql set search_path='' as $$
 insert into public.wallets(tenant_id,type,name,kind,balance) values
 (t,'dealership','Primary Bank Account','bank',0),(t,'cash','Cash Register','cash',0),
 (t,'bkash','bKash','bkash',0),(t,'nagad','Nagad','nagad',0),(t,'logistics','Logistics','logistics',0)
 on conflict (tenant_id,type) where type<>'custom' do nothing;
$$;
select app_private.initialize_wallets(tenant_id) from public.tenants;
create or replace function app_private.ensure_tenant_wallets(p_tenant_id uuid) returns void language plpgsql set search_path='' as $$
begin
 if p_tenant_id is distinct from app_private.current_tenant_id() then raise exception 'Invalid tenant' using errcode='42501'; end if;
 perform app_private.initialize_wallets(p_tenant_id);
end $$;
create function app_private.tenant_wallets_created() returns trigger language plpgsql security definer set search_path='' as $$
begin perform app_private.initialize_wallets(new.tenant_id); return new; end $$;
create trigger tenant_wallets_created after insert on public.tenants for each row execute function app_private.tenant_wallets_created();

-- All future money movement is an append-only ledger insertion. The trigger
-- serializes each wallet and records its true balance even in concurrent sales.
create function app_private.post_wallet_entry() returns trigger language plpgsql set search_path='' as $$
begin
 if new.amount is null or new.amount in ('NaN'::numeric,'Infinity'::numeric,'-Infinity'::numeric) then raise exception 'Invalid wallet amount'; end if;
 new.created_by:=auth.uid();
 update public.wallets set balance=balance+new.amount,updated_at=clock_timestamp()
 where tenant_id=new.tenant_id and wallet_id=new.wallet_id returning balance into new.balance_after;
 if not found then raise exception 'Wallet not found'; end if;
 new.created_at:=clock_timestamp();
 select lower(concat_ws(' ',new.description,new.type,new.reference_id,new.operation_id,new.transaction_id,w.name,sp.reference,c.name,c.phone,c.shop_name))
 into new.search_document from public.wallets w
 left join public.sale_payments sp on sp.tenant_id=new.tenant_id and sp.payment_id=new.payment_id
 left join public.sales s on s.tenant_id=new.tenant_id and s.sale_id=sp.sale_id
 left join public.customers c on c.tenant_id=new.tenant_id and c.customer_id=s.customer_id
 where w.tenant_id=new.tenant_id and w.wallet_id=new.wallet_id;
 return new;
end $$;
create trigger post_wallet_entry before insert on public.wallet_transactions for each row execute function app_private.post_wallet_entry();
create function app_private.immutable_finance_record() returns trigger language plpgsql set search_path='' as $$
begin
 -- Root tenant deletion remains a trusted administrative operation, never a UI action.
 if tg_op='DELETE' and pg_trigger_depth()>1 then return old; end if;
 raise exception 'Financial records are immutable. Record a correction instead.';
end $$;
create trigger immutable_wallet_entry before update or delete on public.wallet_transactions for each row execute function app_private.immutable_finance_record();
create trigger immutable_customer_entry before update or delete on public.customer_transactions for each row execute function app_private.immutable_finance_record();

create table public.finance_requests(
 tenant_id uuid not null references public.tenants(tenant_id) on delete cascade,
 request_id uuid not null, payload jsonb not null, result jsonb not null, created_by uuid not null,
 created_at timestamptz not null default now(), primary key(tenant_id,request_id),
 foreign key(tenant_id,created_by) references public.user_profiles(tenant_id,user_id)
);
alter table public.finance_requests enable row level security;
revoke all on public.finance_requests from public,anon,authenticated;

alter table public.sales add column payment_tracking boolean not null default false,
 add column paid_amount numeric(12,2) not null default 0,
 add column paid_at_checkout numeric(12,2) not null default 0,
 add column checkout_payments jsonb not null default '[]';
-- Legacy sales were recorded as paid in full. No historical wallet credits.
update public.sales set paid_amount=total_amount,paid_at_checkout=total_amount;
alter table public.sales add constraint sale_paid_valid check(paid_amount>=0 and paid_amount<=total_amount);
create index sales_outstanding on public.sales(tenant_id,customer_id,created_at desc) where payment_tracking and paid_amount<total_amount;
create table public.sale_payments(
 tenant_id uuid not null, payment_id uuid not null default gen_random_uuid(), sale_id uuid not null,
 wallet_id uuid not null, wallet_name text not null, method text not null,
 amount numeric(12,2) not null check(amount>0 and amount not in ('NaN'::numeric,'Infinity'::numeric,'-Infinity'::numeric)),
 phase text not null check(phase in ('checkout','collection')), operation_id uuid not null,
 reference text not null default '', created_by uuid not null, created_at timestamptz not null default clock_timestamp(),
 primary key(tenant_id,payment_id),
 foreign key(tenant_id,sale_id) references public.sales(tenant_id,sale_id),
 foreign key(tenant_id,wallet_id) references public.wallets(tenant_id,wallet_id),
 foreign key(tenant_id,created_by) references public.user_profiles(tenant_id,user_id)
);
create index sale_payment_history on public.sale_payments(tenant_id,sale_id,created_at,payment_id);
alter table public.sale_payments enable row level security;
revoke all on public.sale_payments from public,anon,authenticated;
grant select on public.sale_payments to authenticated;
create policy sale_payments_read on public.sale_payments for select to authenticated using
 (tenant_id=(select app_private.current_tenant_id()) and
 (select app_private.has_any_permission(array['finance:view','finance:manage','sales:view','receipts:print','dashboard:view'])));
create trigger immutable_sale_payment before update or delete on public.sale_payments for each row execute function app_private.immutable_finance_record();
alter table public.wallet_transactions add constraint wallet_payment_fk foreign key(tenant_id,payment_id) references public.sale_payments(tenant_id,payment_id);
create unique index wallet_payment_once on public.wallet_transactions(tenant_id,payment_id) where payment_id is not null;
alter table public.customer_transactions add column payment_id uuid,
 add constraint customer_payment_fk foreign key(tenant_id,payment_id) references public.sale_payments(tenant_id,payment_id);
create unique index customer_payment_once on public.customer_transactions(tenant_id,payment_id) where payment_id is not null;
drop index public.pos_sale_income_once;

-- POS gets payment destinations without learning wallet balances or bank details.
create function public.get_payment_wallets() returns table(wallet_id uuid,name text,kind text,type text)
language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['pos:sell','finance:view','finance:manage']);
begin return query select w.wallet_id,w.name,w.kind,w.type from public.wallets w where w.tenant_id=t and w.is_active and w.kind<>'logistics'
 order by case w.type when 'cash' then 0 when 'bkash' then 1 when 'nagad' then 2 when 'dealership' then 3 else 4 end,w.name,w.wallet_id; end $$;

create function app_private.receive_sale_payments(t uuid,sid uuid,entries jsonb,phase text,op uuid) returns numeric
language plpgsql set search_path='' as $$
declare s public.sales; x jsonb; w public.wallets; paid numeric:=0; amount numeric; pid uuid;
begin
 select * into s from public.sales where tenant_id=t and sale_id=sid for update;
 if not found or s.status<>'completed' or not s.payment_tracking then raise exception 'Sale does not support payment collection'; end if;
 if entries is null or jsonb_typeof(entries)<>'array' or jsonb_array_length(entries)>20 then raise exception 'Use up to 20 payment entries'; end if;
 -- Lock only participating wallets, in the same order as purchase funding.
 perform 1 from public.wallets where tenant_id=t and wallet_id in (select (value->>'wallet_id')::uuid from jsonb_array_elements(entries)) order by wallet_id for update;
 for x in select value from jsonb_array_elements(entries) loop
  if jsonb_typeof(x)<>'object' or jsonb_typeof(x->'amount') is distinct from 'number' then raise exception 'Payment amounts must be numbers'; end if;
  amount:=app_private.purchase_money((x->>'amount')::numeric);
  if amount<=0 or amount<>(x->>'amount')::numeric then raise exception 'Payment must be positive with at most two decimal places'; end if;
  select * into w from public.wallets where tenant_id=t and wallet_id=(x->>'wallet_id')::uuid and is_active and kind<>'logistics';
  if not found then raise exception 'Select an active payment wallet belonging to this business'; end if;
  if length(coalesce(x->>'reference',''))>200 then raise exception 'Payment reference is too long'; end if;
  paid:=paid+amount;
  if paid+s.paid_amount>s.total_amount then raise exception 'Payments exceed the remaining sale balance'; end if;
  insert into public.sale_payments(tenant_id,sale_id,wallet_id,wallet_name,method,amount,phase,operation_id,reference,created_by)
   values(t,sid,w.wallet_id,w.name,w.kind,amount,phase,op,coalesce(x->>'reference',''),auth.uid()) returning payment_id into pid;
  insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description,operation_id,payment_id)
   values(t,w.wallet_id,amount,case phase when 'checkout' then 'pos_sale_income' else 'customer_collection' end,sid,
    'Sale #'||left(sid::text,8)||' · '||w.name,op,pid);
  insert into public.customer_transactions(tenant_id,customer_id,type,amount,reference_id,created_by,payment_id)
   values(t,s.customer_id,'payment_receipt',amount,sid,auth.uid(),pid);
 end loop;
 update public.sales set paid_amount=paid_amount+paid where tenant_id=t and sale_id=sid;
 return paid;
end $$;

create function public.collect_sale_payment(p_sale_id uuid,p_payments jsonb,p_request_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('finance:manage'); payload jsonb; prior public.finance_requests; paid numeric; result jsonb;
begin
 if p_request_id is null then raise exception 'Payment request ID is required'; end if;
 payload:=jsonb_build_object('action','collection','sale',p_sale_id,'payments',p_payments,'actor',auth.uid());
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then
  if prior.payload is distinct from payload then raise exception 'Request ID already used with different details'; end if;
  return prior.result;
 end if;
 if p_payments is null or jsonb_typeof(p_payments)<>'array' or jsonb_array_length(p_payments)=0 then raise exception 'Add at least one payment'; end if;
 paid:=app_private.receive_sale_payments(t,p_sale_id,p_payments,'collection',p_request_id);
 select jsonb_build_object('sale_id',sale_id,'received',paid,'paid_amount',paid_amount,'due',total_amount-paid_amount) into result from public.sales where tenant_id=t and sale_id=p_sale_id;
 insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,payload,result,auth.uid());
 return result;
end $$;

create function public.save_finance_wallet(p_payload jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('finance:manage'); id uuid:=(p_payload->>'wallet_id')::uuid; w public.wallets; n text:=trim(p_payload->>'name'); k text:=p_payload->>'kind'; active boolean:=coalesce((p_payload->>'is_active')::boolean,true);
begin
 if n is null or length(n) not between 1 and 80 or length(coalesce(p_payload->>'details',''))>500 then raise exception 'Enter a wallet name (up to 80 characters) and short details'; end if;
 if id is null then
  if k is null or k not in ('cash','bank','bkash','nagad','other') then raise exception 'Invalid wallet category'; end if;
  insert into public.wallets(tenant_id,type,name,kind,details) values(t,'custom',n,k,coalesce(p_payload->>'details','')) returning wallet_id into id;
 else
  select * into w from public.wallets where tenant_id=t and wallet_id=id for update;
  if not found then raise exception 'Wallet not found'; end if;
  if w.revision is distinct from (p_payload->>'revision')::integer then raise exception 'Wallet changed. Reload before saving.' using errcode='40001'; end if;
  if k is distinct from w.kind then raise exception 'Wallet category cannot change after creation'; end if;
  if w.type<>'custom' and not active then raise exception 'Default wallets cannot be archived'; end if;
  if not active and w.balance<>0 then raise exception 'Transfer or adjust the balance to zero before archiving'; end if;
  update public.wallets set name=n,details=coalesce(p_payload->>'details',''),is_active=active,revision=revision+1,updated_at=now() where tenant_id=t and wallet_id=id;
 end if;
 insert into public.audit_logs(tenant_id,table_name,record_id,action,old_data,new_data,performed_by)
 values(t,'wallets',id,'UPDATE',case when w.wallet_id is not null then to_jsonb(w) else null end,p_payload,auth.uid());
 return id;
end $$;

create function app_private.finance_search(document text,query text) returns boolean
language sql immutable set search_path='' as $$
 select coalesce(trim(query),'')='' or exists(select 1 from regexp_split_to_table(lower(query),'\s*,\s*') g
 where trim(g)<>'' and not exists(select 1 from regexp_split_to_table(trim(g),'\s+') token where token<>'' and position(token in lower(document))=0));
$$;
create function public.get_wallet_ledger(p_filters jsonb default '{}',p_offset integer default 0,p_limit integer default 25) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['finance:view','finance:manage']); result jsonb;
 sorting text:=coalesce(p_filters->>'sort','date_desc');
 search_condition text:=''; group_condition text; search_group text; token text;
begin
 if p_filters is null or jsonb_typeof(p_filters)<>'object' or length(coalesce(p_filters->>'search',''))>500
  or sorting not in ('date_desc','date_asc','amount_desc','amount_asc')
  or coalesce(p_filters->>'direction','all') not in ('all','in','out')
  or p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid ledger filters or page'; end if;
 if nullif(p_filters->>'min','') is not null then perform app_private.purchase_money((p_filters->>'min')::numeric); end if;
 if nullif(p_filters->>'max','') is not null then perform app_private.purchase_money((p_filters->>'max')::numeric); end if;
 if nullif(p_filters->>'min','')::numeric> nullif(p_filters->>'max','')::numeric or nullif(p_filters->>'from','')::date>nullif(p_filters->>'to','')::date then raise exception 'Invalid filter range'; end if;

 -- Compile token groups once, quoting every literal. Direct LIKE predicates let
 -- pg_trgm use its index; user '%'/'_'/'\' remain literal substring characters.
 for search_group in select value from regexp_split_to_table(lower(coalesce(p_filters->>'search','')),'\s*,\s*') value loop
  group_condition:='';
  for token in select value from regexp_split_to_table(trim(search_group),'\s+') value where value<>'' loop
   group_condition:=concat_ws(' and ',nullif(group_condition,''),format('x.search_document like %L',
    '%'||replace(replace(replace(token,chr(92),chr(92)||chr(92)),'%',chr(92)||'%'),'_',chr(92)||'_')||'%'));
  end loop;
  if group_condition<>'' then search_condition:=concat_ws(' or ',nullif(search_condition,''),'('||group_condition||')'); end if;
 end loop;
 search_condition:=coalesce(nullif(search_condition,''),'true');
 execute format($ledger$ with matching as materialized (
  select x.transaction_id,x.created_at,x.entry_no,x.amount from public.wallet_transactions x where x.tenant_id=$1
   and (nullif($2->>'wallet','') is null or x.wallet_id=($2->>'wallet')::uuid)
   and (nullif($2->>'type','') is null or x.type=$2->>'type')
   and (coalesce($2->>'direction','all')='all' or ($2->>'direction'='in' and x.amount>0) or ($2->>'direction'='out' and x.amount<0))
   and (nullif($2->>'from','') is null or x.created_at >= (nullif($2->>'from','')::date::timestamp at time zone 'Asia/Dhaka'))
   and (nullif($2->>'to','') is null or x.created_at < ((nullif($2->>'to','')::date+1)::timestamp at time zone 'Asia/Dhaka'))
   and (nullif($2->>'min','') is null or abs(x.amount)>=($2->>'min')::numeric)
   and (nullif($2->>'max','') is null or abs(x.amount)<=($2->>'max')::numeric)
   and (%s)
 ), page as materialized (
  select * from matching order by
   case when $3='date_desc' then created_at end desc,case when $3='date_asc' then created_at end,
   case when $3='amount_desc' then abs(amount) end desc,case when $3='amount_asc' then abs(amount) end,entry_no desc limit $4 offset $5
 ) select jsonb_build_object('total',(select count(*) from matching),
  'received',(select coalesce(sum(amount) filter(where amount>0),0) from matching),
  'paid_out',(select -coalesce(sum(amount) filter(where amount<0),0) from matching),
  'entries',coalesce((select jsonb_agg((to_jsonb(p)-'search_document')||jsonb_build_object('wallet_name',w.name,'counterparty',cw.name,'actor',up.full_name,
   'payment_reference',sp.reference,'customer_name',c.name,'customer_phone',c.phone,'source',case when sp.payment_id is not null then 'sale' when p.type like 'purchase%%' then 'purchase' when p.type like 'transit%%' or p.type like 'transport%%' then 'transit' else null end) order by
   case when $3='date_desc' then p.created_at end desc,case when $3='date_asc' then p.created_at end,
   case when $3='amount_desc' then abs(p.amount) end desc,case when $3='amount_asc' then abs(p.amount) end,p.entry_no desc)
   from page keys join public.wallet_transactions p on p.tenant_id=$1 and p.transaction_id=keys.transaction_id
   join public.wallets w on w.tenant_id=$1 and w.wallet_id=p.wallet_id
   left join public.wallets cw on cw.tenant_id=$1 and cw.wallet_id=p.counterparty_wallet_id
   left join public.user_profiles up on up.tenant_id=$1 and up.user_id=p.created_by
   left join public.sale_payments sp on sp.tenant_id=$1 and sp.payment_id=p.payment_id
   left join public.sales s on s.tenant_id=$1 and s.sale_id=sp.sale_id
   left join public.customers c on c.tenant_id=$1 and c.customer_id=s.customer_id),'[]'))
 $ledger$,search_condition) into result using t,p_filters,sorting,p_limit,p_offset;
 return result;
end $$;

create function public.get_finance_dues(p_search text default '',p_customer_id uuid default null,p_offset integer default 0,p_limit integer default 25) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['finance:view','finance:manage']); result jsonb;
begin
 if p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100 or length(coalesce(p_search,''))>500 then raise exception 'Invalid due page'; end if;
 with matching as materialized (
  select s.sale_id,s.customer_id,s.created_at,s.total_amount,s.paid_amount,s.total_amount-s.paid_amount due,c.name,c.phone,c.shop_name
  from public.sales s join public.customers c on c.tenant_id=t and c.customer_id=s.customer_id
  where s.tenant_id=t and s.payment_tracking and s.status='completed' and s.paid_amount<s.total_amount
   and (p_customer_id is null or s.customer_id=p_customer_id)
   and app_private.finance_search(concat_ws(' ',s.sale_id,c.name,c.phone,c.shop_name),p_search)
 ), page as (select * from matching order by created_at desc,sale_id limit p_limit offset p_offset)
 select jsonb_build_object('total',(select count(*) from matching),'due',(select coalesce(sum(due),0) from matching),
  'entries',coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at desc,p.sale_id) from page p),'[]')) into result;
 return result;
end $$;

create function public.get_sale_settlement(p_sale_id uuid,p_offset integer default 0,p_limit integer default 10) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['finance:view','finance:manage','sales:view','receipts:print','dashboard:view']); s public.sales; result jsonb;
begin
 if p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid payment page'; end if;
 select * into s from public.sales where tenant_id=t and sale_id=p_sale_id;
 if not found then raise exception 'Sale not found'; end if;
 select jsonb_build_object('sale_id',s.sale_id,'tracking',s.payment_tracking,'total',s.total_amount,'paid',s.paid_amount,'due',s.total_amount-s.paid_amount,
  'paid_at_checkout',s.paid_at_checkout,'checkout_payments',s.checkout_payments,
  'payment_count',(select count(*) from public.sale_payments where tenant_id=t and sale_id=p_sale_id),
  'payments',coalesce((select jsonb_agg(to_jsonb(p) order by created_at desc,payment_id) from
   (select * from public.sale_payments where tenant_id=t and sale_id=p_sale_id order by created_at desc,payment_id limit p_limit offset p_offset) p),'[]'),
  'receipt_payments',coalesce((select jsonb_agg(to_jsonb(p) order by phase,wallet_name,method) from
   (select wallet_name,method,phase,sum(amount) amount from public.sale_payments where tenant_id=t and sale_id=p_sale_id group by wallet_name,method,phase) p),'[]')) into result;
 return result;
end $$;

create function public.get_customer_balance(p_customer_id uuid) returns numeric
language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['finance:view','finance:manage','customers:view','customers:manage']); result numeric;
begin
 if not exists(select 1 from public.customers where tenant_id=t and customer_id=p_customer_id) then raise exception 'Customer not found'; end if;
 select -coalesce(sum(amount),0) into result from public.customer_transactions where tenant_id=t and customer_id=p_customer_id;
 return result;
end $$;

create function public.move_wallet_money(p_payload jsonb,p_request_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('finance:manage'); prior public.finance_requests; payload jsonb:=p_payload||jsonb_build_object('actor',auth.uid());
 src uuid:=(p_payload->>'wallet_id')::uuid; dest uuid:=(p_payload->>'destination_id')::uuid; action text:=p_payload->>'action';
 amount numeric; w public.wallets; target public.wallets; reason text:=trim(p_payload->>'reason'); result jsonb;
begin
 if p_request_id is null then raise exception 'Request ID is required'; end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then
  if prior.payload is distinct from payload then raise exception 'Request ID already used with different details'; end if;
  return prior.result;
 end if;
 if action is null or action not in ('transfer','adjustment') or reason is null or length(reason) not between 3 and 500 then raise exception 'Select an action and give a reason (3–500 characters)'; end if;
 if jsonb_typeof(p_payload->'amount') is distinct from 'number' then raise exception 'Enter a finite amount'; end if;
 amount:=(p_payload->>'amount')::numeric;
 if abs(amount)<>app_private.purchase_money(abs(amount)) or amount=0 then raise exception 'Enter a nonzero amount with at most two decimal places'; end if;
 perform 1 from public.wallets where tenant_id=t and wallet_id in (src,dest) order by wallet_id for update;
 select * into w from public.wallets where tenant_id=t and wallet_id=src and is_active;
 if not found then raise exception 'Active source wallet not found'; end if;
 if action='transfer' then
  if amount<0 or dest is null or dest=src then raise exception 'Choose different wallets and a positive transfer amount'; end if;
  select * into target from public.wallets where tenant_id=t and wallet_id=dest and is_active;
  if not found then raise exception 'Active destination wallet not found'; end if;
  if w.balance<amount then raise exception 'Insufficient wallet balance for transfer'; end if;
  insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,description,counterparty_wallet_id,operation_id) values
   (t,src,-amount,'wallet_transfer',reason,dest,p_request_id),(t,dest,amount,'wallet_transfer',reason,src,p_request_id);
 else
  if dest is not null then raise exception 'Adjustments cannot have a destination'; end if;
  insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,description,operation_id) values(t,src,amount,'balance_adjustment',reason,p_request_id);
 end if;
 result:=jsonb_build_object('operation_id',p_request_id);
 insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,payload,result,auth.uid());
 return result;
end $$;

-- Existing purchase policies; balance application now belongs to the ledger.
create or replace function app_private.fund_purchase_transport(t uuid, pid uuid) returns void
language plpgsql set search_path='' as $$
declare p public.purchases; delta numeric; dw uuid; lw uuid;
begin
  select * into p from public.purchases where tenant_id=t and purchase_id=pid;
  delta:=coalesce(p.transport_cost,0)-p.transport_funded;
  if delta=0 then return; end if;
  perform app_private.ensure_tenant_wallets(t);
  perform 1 from public.wallets where tenant_id=t order by wallet_id for update;
  select wallet_id into dw from public.wallets where tenant_id=t and type='dealership';
  select wallet_id into lw from public.wallets where tenant_id=t and type='logistics';
  insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description) values
    (t,dw,-delta,'purchase_transport_funding',pid,'Transport fee transferred to logistics'),
    (t,lw,delta,'purchase_transport_funding',pid,'Transport fee from dealership');
  
  
  update public.purchases set transport_funded=coalesce(transport_cost,0) where tenant_id=t and purchase_id=pid;
end $$;

create or replace function public.pay_purchase(p_purchase_id uuid,p_revision integer) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t uuid := app_private.require_permission('purchases:manage'); p public.purchases; dealership uuid; logistics uuid;
begin
  select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id for update;
  if not found then raise exception 'Purchase not found'; end if;
  if p.status not in ('in_transit','received') then raise exception 'Payment is allowed only after dispatch'; end if;
  if p.payment_status='paid' then return jsonb_build_object('purchase_id',p_purchase_id,'already_paid',true); end if;
  if p_revision is distinct from p.revision then raise exception 'Purchase changed. Reload before payment.' using errcode='40001'; end if;
  if p.total_cost<0 or p.company_payable<0 then raise exception 'Resolve historical financial amounts before payment'; end if;
  perform app_private.ensure_tenant_wallets(t);
  perform 1 from public.wallets where tenant_id=t order by wallet_id for update;
  select wallet_id into dealership from public.wallets where tenant_id=t and type='dealership';
  select wallet_id into logistics from public.wallets where tenant_id=t and type='logistics';
  perform app_private.fund_purchase_transport(t,p_purchase_id);
  p.transport_funded:=coalesce(p.transport_cost,0);
  -- Old credited transport with no dealership debit is charged at payment once.
  insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description) values
    (t,dealership,-p.company_payable,'purchase_company_payment',p_purchase_id,'Company payment after commission'),
    (t,dealership,-(coalesce(p.labour_cost,0)+p.transport_funded
      +coalesce((select sum(amount) from public.wallet_transactions where tenant_id=t and wallet_id=dealership
        and reference_id=p_purchase_id and type='purchase_transport_funding'),0)),
      'purchase_logistics_payment',p_purchase_id,'Labour and any historical transport balance');
  
  update public.purchases set payment_status='paid',paid_at=now(),updated_at=now(),revision=revision+1
    where tenant_id=t and purchase_id=p_purchase_id;
  insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details)
    values(t,p_purchase_id,'paid',auth.uid(),jsonb_build_object('company_payable',p.company_payable,
      'transport_cost',p.transport_cost,'labour_cost',p.labour_cost,'total_cost',p.total_cost));
  return jsonb_build_object('purchase_id',p_purchase_id);
end $$;

create or replace function public.create_custom_transit(p_payload jsonb) returns jsonb
language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('logistics:manage'); truck public.trucks; id uuid; wid uuid;
  fee numeric:=app_private.purchase_money((p_payload->>'fee')::numeric);
begin
  select * into truck from public.trucks where tenant_id=t and truck_id=(p_payload->>'truck_id')::uuid for update;
  if not found or truck.status<>'idle' then raise exception 'Select an idle truck'; end if;
  if nullif(trim(p_payload->>'client_name'),'') is null then raise exception 'Client name is required'; end if;
  insert into public.transits(tenant_id,truck_id,status,transport_fee,client_name,destination,description)
    values(t,truck.truck_id,'active',fee,trim(p_payload->>'client_name'),p_payload->>'destination',p_payload->>'description') returning transit_id into id;
  update public.trucks set status='going',updated_at=now() where tenant_id=t and truck_id=truck.truck_id;
  perform app_private.ensure_tenant_wallets(t);
  select wallet_id into wid from public.wallets where tenant_id=t and type='logistics' for update;
  if fee>0 then
    insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description)
      values(t,wid,fee,'transport_income',id,'Custom transit client fee');
    
  end if;
  return jsonb_build_object('transit_id',id);
end $$;

create or replace function public.transition_transit(p_transit_id uuid,p_action text,p_revision integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('logistics:manage'); tr public.transits; pid uuid; wid uuid; refund numeric;
begin
  select purchase_id into pid from public.transits where tenant_id=t and transit_id=p_transit_id;
  if pid is not null then perform 1 from public.purchases where tenant_id=t and purchase_id=pid for update; end if;
  select * into tr from public.transits where tenant_id=t and transit_id=p_transit_id;
  if not found then raise exception 'Transit not found'; end if;
  perform 1 from public.trucks where tenant_id=t and truck_id=tr.truck_id for update;
  select * into tr from public.transits where tenant_id=t and transit_id=p_transit_id for update;
  if p_action not in ('complete','cancel','close') or p_action is null then raise exception 'Invalid transit action'; end if;
  if p_action='close' and tr.closed_at is not null or p_action='complete' and tr.status='completed'
    or p_action='cancel' and tr.status='cancelled' then return jsonb_build_object('already_applied',true); end if;
  if tr.closed_at is not null then raise exception 'Transit is closed'; end if;
  if p_revision is distinct from tr.revision then raise exception 'Transit changed. Reload before continuing.' using errcode='40001'; end if;
  if p_action in ('complete','cancel') and pid is not null then raise exception 'Purchase transits follow the purchase. Receive or cancel it in Purchases.'; end if;
  if p_action='complete' and tr.status<>'active' then raise exception 'Only an active transit can be completed'; end if;
  if p_action='close' and tr.status='active' then raise exception 'Complete the transit before closing its costs'; end if;
  perform app_private.ensure_tenant_wallets(t);
  select wallet_id into wid from public.wallets where tenant_id=t and type='logistics' for update;
  if p_action='cancel' then
    select coalesce(sum(amount),0) into refund from public.wallet_transactions where tenant_id=t and wallet_id=wid
      and reference_id=p_transit_id and type='transport_income';
    if refund>0 then
      insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description)
        values(t,wid,-refund,'transit_client_refund',p_transit_id,'Full transport fee refunded to client');
      
    end if;
    update public.transits set status='cancelled',revision=revision+1,updated_at=now() where tenant_id=t and transit_id=p_transit_id;
  elsif p_action='complete' then
    update public.transits set status='completed',revision=revision+1,updated_at=now() where tenant_id=t and transit_id=p_transit_id;
  else
    if tr.total_cost>0 then
      insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description)
        values(t,wid,-tr.total_cost,'transit_close_cost',p_transit_id,'Transit operating costs on closure');
      
    end if;
    update public.transits set closed_at=now(),revision=revision+1,updated_at=now() where tenant_id=t and transit_id=p_transit_id;
  end if;
  if not exists(select 1 from public.transits where tenant_id=t and truck_id=tr.truck_id and status='active')
    and not exists(select 1 from public.purchases where tenant_id=t and truck_id=tr.truck_id and status='in_transit') then
    update public.trucks set status='idle',updated_at=now() where tenant_id=t and truck_id=tr.truck_id;
  end if;
  if pid is not null then insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details)
    values(t,pid,'transit_closed',auth.uid(),jsonb_build_object('operating_cost',tr.total_cost)); end if;
  return jsonb_build_object('transit_id',p_transit_id);
end $$;

create or replace function public.cancel_purchase(p_purchase_id uuid,p_revision integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('purchases:manage'); p public.purchases; r record; dw uuid; lw uuid; refund numeric;
begin
  select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id for update;
  if not found then raise exception 'Purchase not found'; end if;
  if p.status='cancelled' then return jsonb_build_object('already_cancelled',true); end if;
  if p_revision is distinct from p.revision then raise exception 'Purchase changed. Reload before cancellation.' using errcode='40001'; end if;
  perform 1 from public.trucks where tenant_id=t and truck_id=p.truck_id for update;
  perform 1 from public.transits where tenant_id=t and purchase_id=p_purchase_id order by transit_id for update;
  -- Reverse recorded movements, including precisely identified historical notes.
  for r in select m.item_id,sum(m.filled_quantity_change) filled,sum(m.empty_quantity_change) empties
    from public.inventory_movements m where m.tenant_id=t and
      (m.reference_id=p_purchase_id and m.reference_type in ('purchase_dispatch','purchase_receipt_refill','purchase_receipt_new')
      or p.legacy_record and m.reference_id is null and m.notes in
        ('Empty bottles sent for refill (Purchase '||p_purchase_id||')','Received goods from Purchase '||p_purchase_id,
         'Quantity adjustment for Purchase '||p_purchase_id))
    group by m.item_id order by m.item_id loop
    perform 1 from public.items where tenant_id=t and item_id=r.item_id for update;
    if exists(select 1 from public.items where tenant_id=t and item_id=r.item_id
      and (filled_quantity-r.filled<0 or empty_quantity-r.empties<0)) then
      raise exception 'Cannot cancel: received cylinders are no longer available in stock. Restore the stock before cancelling.'; end if;
    insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,filled_quantity_change,empty_quantity_change,notes,created_by)
      values(t,r.item_id,'purchase_adjustment','purchase_cancellation',p_purchase_id,-r.filled,-r.empties,'Purchase cancelled: stock reversed',auth.uid());
  end loop;
  perform app_private.ensure_tenant_wallets(t);
  perform 1 from public.wallets where tenant_id=t order by wallet_id for update;
  select wallet_id into dw from public.wallets where tenant_id=t and type='dealership';
  select wallet_id into lw from public.wallets where tenant_id=t and type='logistics';
  select -coalesce(sum(amount),0) into refund from public.wallet_transactions where tenant_id=t and wallet_id=dw
    and reference_id=p_purchase_id and type in ('purchase_expense','purchase_company_payment','purchase_logistics_payment','purchase_transport_funding');
  if refund<>0 then
    insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description)
      values(t,dw,refund,'purchase_cancel_refund',p_purchase_id,'Cancelled purchase payments refunded');
    
  end if;
  select coalesce(sum(amount),0) into refund from public.wallet_transactions where tenant_id=t and wallet_id=lw
    and reference_id=p_purchase_id and type in ('transport_income','transport_income_adj','purchase_transport_settlement','purchase_transport_funding');
  if refund<>0 then
    insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description)
      values(t,lw,-refund,'purchase_transport_refund',p_purchase_id,'Cancelled purchase transport fee returned');
    
  end if;
  update public.transits set status='cancelled',revision=revision+1,updated_at=now() where tenant_id=t and purchase_id=p_purchase_id;
  update public.purchases set status='cancelled',cancelled_at=now(),updated_at=now(),revision=revision+1 where tenant_id=t and purchase_id=p_purchase_id;
  if not exists(select 1 from public.transits where tenant_id=t and truck_id=p.truck_id and status='active')
    and not exists(select 1 from public.purchases where tenant_id=t and truck_id=p.truck_id and status='in_transit') then
    update public.trucks set status='idle',updated_at=now() where tenant_id=t and truck_id=p.truck_id;
  end if;
  insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details)
    values(t,p_purchase_id,'cancelled',auth.uid(),jsonb_build_object('previous_status',p.status,'notes','Stock and recorded payments reversed; incurred transit costs retained'));
  return jsonb_build_object('purchase_id',p_purchase_id);
end $$;

drop function public.create_pos_sale(varchar,varchar,varchar,text,varchar,numeric,numeric,text,jsonb,uuid,uuid);
create function public.create_pos_sale(
  p_customer_phone varchar,p_customer_name varchar,p_customer_shop_name varchar,p_customer_address text,
  p_customer_tier varchar,p_discount_amount numeric,p_exchange_fee numeric,p_notes text,p_items jsonb,
  p_customer_id uuid default null,p_request_id uuid default null,p_payments jsonb default null
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  t uuid:=app_private.require_permission('pos:sell'); actor uuid:=auth.uid();
  tier text:=coalesce(p_customer_tier,'retail'); payload jsonb; saved public.sales;
  customer public.customers; sale uuid; x jsonb; stock record; qty integer; price numeric;
  expected numeric; subtotal numeric:=0; discount numeric; fee numeric; total numeric;
  refills bigint:=0; empties bigint:=0; filled_delta integer; empty_delta integer;
  wallet uuid; result jsonb; payments jsonb; paid numeric;
begin
  if p_request_id is null then raise exception 'Checkout request ID is required. Refresh the application.'; end if;
  payload:=jsonb_build_object('actor',actor,'customer_id',p_customer_id,'phone',trim(p_customer_phone),
    'name',p_customer_name,'shop',p_customer_shop_name,'address',p_customer_address,'tier',tier,
    'discount',coalesce(p_discount_amount,0),'fee',coalesce(p_exchange_fee,0),'notes',p_notes,'items',p_items,'payments',p_payments);
  perform pg_advisory_xact_lock(hashtextextended(t::text||':pos:'||p_request_id::text,0));
  select * into saved from public.sales where tenant_id=t and checkout_request_id=p_request_id;
  if found then
    if (saved.checkout_payload||jsonb_build_object('payments',saved.checkout_payload->'payments')) is distinct from payload then
      raise exception 'Checkout request ID was already used with different sale details';
    end if;
    return saved.checkout_result;
  end if;
  if tier not in ('retail','wholesale') then raise exception 'Invalid sale tier'; end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then
    raise exception 'Cart must be a nonempty array';
  end if;
  discount:=app_private.purchase_money(coalesce(p_discount_amount,0));
  fee:=app_private.purchase_money(coalesce(p_exchange_fee,0));
  if nullif(trim(p_customer_phone),'') is null then raise exception 'Customer phone number is required to complete a sale'; end if;

  -- Every participating item is locked before any stock write, in the same order
  -- as purchases and inventory price saves. Price saves also lock the item first.
  for stock in select i.item_id from public.items i where i.tenant_id=t and i.item_id in
    (select (value->>'item_id')::uuid from jsonb_array_elements(p_items)) order by i.item_id for update
  loop null; end loop;
  for x in select value from jsonb_array_elements(p_items) loop
    if jsonb_typeof(x)<>'object' or x->>'type' is null or x->>'type' not in ('refill','package','empty_return') then
      raise exception 'Invalid sale line';
    end if;
    qty:=app_private.purchase_integer(x->'quantity');
    if qty=0 then raise exception 'Sale quantities must be positive whole numbers'; end if;
    if jsonb_typeof(x->'unit_price') is distinct from 'number' then raise exception 'Sale prices must be finite numbers'; end if;
    price:=app_private.purchase_money((x->>'unit_price')::numeric);
    if not exists(select 1 from public.items where tenant_id=t and item_id=(x->>'item_id')::uuid) then
      raise exception 'Item not found';
    end if;
    if x->>'type'='empty_return' then
      if price<>0 then raise exception 'Empty returns must have a zero price'; end if;
      empties:=empties+qty;
    else
      select pb.price into expected from public.price_books pb
        where pb.tenant_id=t and pb.item_id=(x->>'item_id')::uuid and pb.price_type=x->>'type'
          and pb.customer_tier in (tier,'retail') and pb.effective_from<=statement_timestamp()
          and (pb.effective_to is null or pb.effective_to>statement_timestamp())
        order by (pb.customer_tier=tier) desc,pb.effective_from desc limit 1;
      if not found then raise exception 'No active selling price. Set the product price before checkout.'; end if;
      expected:=app_private.purchase_money(expected);
      if price<>expected then raise exception 'Selling price changed or does not match the price book. Refresh prices and review the cart.'; end if;
      if x->>'type'='refill' then refills:=refills+qty; end if;
    end if;
    subtotal:=subtotal+qty*price;
  end loop;
  if refills<>empties then raise exception 'Refill count (%) must equal empty bottle return count (%)',refills,empties; end if;
  subtotal:=app_private.purchase_money(subtotal);
  if discount>subtotal then raise exception 'Discount cannot exceed the product subtotal'; end if;
  total:=app_private.purchase_money(subtotal-discount+fee);
  -- Validate net stock across the complete cart, independently of line order.
  for stock in select i.item_id,i.filled_quantity,i.empty_quantity,
    sum(case when l.value->>'type' in ('refill','package') then -(l.value->>'quantity')::numeric else 0 end) filled,
    sum(case when l.value->>'type'='package' then -(l.value->>'quantity')::numeric
      when l.value->>'type'='empty_return' then (l.value->>'quantity')::numeric else 0 end) empty
    from jsonb_array_elements(p_items) l join public.items i on i.tenant_id=t and i.item_id=(l.value->>'item_id')::uuid
    group by i.tenant_id,i.item_id order by i.item_id loop
    if stock.filled_quantity+stock.filled<0 or stock.empty_quantity+stock.empty<0 then raise exception 'Insufficient stock'; end if;
  end loop;
  if p_customer_id is not null then
    select * into customer from public.customers where tenant_id=t and customer_id=p_customer_id;
    if not found then raise exception 'Selected customer was not found'; end if;
  else
    if exists(select 1 from public.customers where tenant_id=t and phone=trim(p_customer_phone)) then
      raise exception 'This phone number belongs to a saved customer. Select the saved customer before completing the sale.';
    end if;
    insert into public.customers(tenant_id,name,phone,shop_name,address,tier)
      values(t,coalesce(nullif(trim(p_customer_name),''),'Unknown'),trim(p_customer_phone),
        nullif(trim(p_customer_shop_name),''),nullif(trim(p_customer_address),''),tier) returning * into customer;
  end if;
  insert into public.sales(tenant_id,customer_id,sale_tier,status,subtotal,discount_amount,exchange_fee,total_amount,
    notes,created_by,checkout_request_id,checkout_payload,payment_tracking)
    values(t,customer.customer_id,tier,'completed',subtotal,discount,fee,total,p_notes,actor,p_request_id,payload,true) returning sale_id into sale;
  for x in select value from jsonb_array_elements(p_items) loop
    qty:=app_private.purchase_integer(x->'quantity'); price:=(x->>'unit_price')::numeric;
    filled_delta:=0; empty_delta:=0;
    if x->>'type'='refill' then filled_delta:=-qty;
    elsif x->>'type'='package' then filled_delta:=-qty; empty_delta:=-qty;
    else empty_delta:=qty; end if;
    insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,
      filled_quantity_change,empty_quantity_change,notes,created_by)
      values(t,(x->>'item_id')::uuid,'sale','sale',sale,filled_delta,empty_delta,'POS Sale #'||left(sale::text,8),actor);
    insert into public.sale_items(tenant_id,sale_id,item_id,type,quantity,unit_price,line_total)
      values(t,sale,(x->>'item_id')::uuid,(x->>'type')::public.sale_item_type,qty,price,qty*price);
  end loop;
  insert into public.customer_transactions(tenant_id,customer_id,type,amount,reference_id,created_by)
    values(t,customer.customer_id,'invoice_charge',-total,sale,actor);
  select wallet_id into wallet from public.wallets where tenant_id=t and type='cash';
  payments:=coalesce(p_payments,case when total=0 then '[]'::jsonb else jsonb_build_array(jsonb_build_object('wallet_id',wallet,'amount',total)) end);
  paid:=app_private.receive_sale_payments(t,sale,payments,'checkout',p_request_id);
  update public.sales set paid_at_checkout=paid,checkout_payments=coalesce((select jsonb_agg(jsonb_build_object('wallet_id',wallet_id,'wallet_name',wallet_name,'method',method,'amount',amount,'reference',reference) order by created_at,payment_id)
    from public.sale_payments where tenant_id=t and sale_id=sale),'[]') where tenant_id=t and sale_id=sale;
  result:=jsonb_build_object('sale_id',sale,'sale_tier',tier,'customer_id',customer.customer_id,'subtotal',subtotal,
    'total_amount',total,'paid_amount',paid,'due',total-paid,'customer_phone',customer.phone,'customer_name',coalesce(nullif(trim(customer.name),''),'Unknown'));
  update public.sales set checkout_result=result where tenant_id=t and sale_id=sale;
  return result;
end $$;

-- Explicit ownership/grants for this migration, including private helpers.
alter function app_private.initialize_wallets(uuid) owner to postgres;
alter function app_private.tenant_wallets_created() owner to postgres;
alter function app_private.post_wallet_entry() owner to postgres;
alter function app_private.immutable_finance_record() owner to postgres;
alter function app_private.receive_sale_payments(uuid,uuid,jsonb,text,uuid) owner to postgres;
alter function app_private.finance_search(text,text) owner to postgres;
revoke all on function app_private.initialize_wallets(uuid),app_private.tenant_wallets_created(),app_private.post_wallet_entry(),app_private.immutable_finance_record(),app_private.receive_sale_payments(uuid,uuid,jsonb,text,uuid),app_private.finance_search(text,text) from public,anon,authenticated;
alter table public.sale_payments owner to postgres;
alter table public.finance_requests owner to postgres;
alter function public.get_payment_wallets() owner to postgres;
alter function public.collect_sale_payment(uuid,jsonb,uuid) owner to postgres;
alter function public.save_finance_wallet(jsonb) owner to postgres;
alter function public.move_wallet_money(jsonb,uuid) owner to postgres;
alter function public.get_wallet_ledger(jsonb,integer,integer) owner to postgres;
alter function public.get_finance_dues(text,uuid,integer,integer) owner to postgres;
alter function public.get_sale_settlement(uuid,integer,integer) owner to postgres;
alter function public.get_customer_balance(uuid) owner to postgres;
alter function public.create_pos_sale(varchar,varchar,varchar,text,varchar,numeric,numeric,text,jsonb,uuid,uuid,jsonb) owner to postgres;
revoke all on function public.get_payment_wallets(),public.collect_sale_payment(uuid,jsonb,uuid),public.save_finance_wallet(jsonb),public.move_wallet_money(jsonb,uuid),public.get_wallet_ledger(jsonb,integer,integer),public.get_finance_dues(text,uuid,integer,integer),public.get_sale_settlement(uuid,integer,integer),public.get_customer_balance(uuid),public.create_pos_sale(varchar,varchar,varchar,text,varchar,numeric,numeric,text,jsonb,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.get_payment_wallets(),public.collect_sale_payment(uuid,jsonb,uuid),public.save_finance_wallet(jsonb),public.move_wallet_money(jsonb,uuid),public.get_wallet_ledger(jsonb,integer,integer),public.get_finance_dues(text,uuid,integer,integer),public.get_sale_settlement(uuid,integer,integer),public.get_customer_balance(uuid),public.create_pos_sale(varchar,varchar,varchar,text,varchar,numeric,numeric,text,jsonb,uuid,uuid,jsonb) to authenticated;
notify pgrst,'reload schema';
