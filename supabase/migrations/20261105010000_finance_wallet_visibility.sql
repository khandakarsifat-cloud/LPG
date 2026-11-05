-- Finance visibility and independent per-wallet operation scopes. No financial recognition changes.


insert into public.permissions(permission_id,module,label,description,owner_only,dependencies) values
 ('wallets:use','Wallets','Use wallets','Select a wallet for an independently authorized business operation; does not reveal balances.',false,'{}'),
 ('wallets:balances','Wallets','View wallet balances','Default balance visibility; individual wallet overrides apply.',false,'{}'),
 ('wallets:ledger','Wallets','View wallet history','Default history visibility; individual wallet overrides apply.',false,array['finance:view']),
 ('finance:entries:view','Finance','View own financial entries','Read financial entries created by this account.',false,array['finance:view']),
 ('finance:entries:all','Finance','View all financial entries','Read other staff financial entries as well.',false,array['finance:entries:view']),
 ('finance:activity','Finance','View accounting activity','Detailed journal history; requires visibility of every wallet balance.',false,array['finance:view']),
 ('finance:loans','Finance','View loans and lending','Read loan balances and their activity; writes remain owner-only.',false,array['finance:view']),
 ('finance:stock','Finance','View product performance and FIFO','Received purchase/sales quantities and historical acquisition costs and margins.',false,array['finance:view']);
-- Preserve existing role/custom access explicitly. New accounts inherit their role defaults.
insert into public.role_permissions(tenant_id,role_id,permission_id)
select r.tenant_id,r.role_id,p.permission_id from public.roles r cross join public.permissions p
where (r.name='MANAGER' and p.permission_id in ('wallets:use','wallets:balances','wallets:ledger','finance:entries:view','finance:entries:all','finance:activity','finance:loans','finance:stock'))
or (r.name='SALESMAN' and p.permission_id='wallets:use') on conflict do nothing;
update app_private.user_permission_sets s set permissions=(select array_agg(distinct p) from unnest(s.permissions ||
 case when s.permissions && array['finance:view','finance:manage'] then array['wallets:balances','wallets:ledger','finance:entries:view','finance:entries:all','finance:loans'] else '{}'::text[] end ||
 case when s.permissions && array['reports:view'] then array['finance:activity','finance:stock'] else '{}'::text[] end ||
 case when s.permissions && array['pos:sell','finance:manage','purchases:manage','payroll:pay','logistics:manage'] then array['wallets:use'] else '{}'::text[] end) p);
update public.permissions set dependencies=array['finance:manage','finance:entries:view'] where permission_id='finance:returns';
create table app_private.user_wallet_access (
 tenant_id uuid not null, user_id uuid not null, wallet_id uuid not null,
 can_use boolean not null, can_balance boolean not null, can_history boolean not null,
 primary key(tenant_id,user_id,wallet_id),
 foreign key(tenant_id,wallet_id) references public.wallets(tenant_id,wallet_id) on delete cascade,
 foreign key(user_id) references auth.users(id) on delete cascade
);
alter table app_private.user_wallet_access enable row level security;
alter table app_private.user_wallet_access owner to postgres;
revoke all on app_private.user_wallet_access from public,anon,authenticated;
create function app_private.wallet_allowed(w uuid, capability text) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.wallets x where x.tenant_id=app_private.current_tenant_id() and x.wallet_id=w)
 and (app_private.is_owner() or coalesce((select case capability when 'use' then a.can_use when 'balance' then a.can_balance when 'history' then a.can_history else false end
 from app_private.user_wallet_access a where a.tenant_id=app_private.current_tenant_id() and a.user_id=auth.uid() and a.wallet_id=w),
 case capability when 'use' then app_private.has_permission('wallets:use') when 'balance' then app_private.has_permission('wallets:balances') when 'history' then app_private.has_permission('wallets:ledger') else false end));
$$;
create function app_private.all_wallet_balances_visible() returns boolean language sql stable security definer set search_path='' as $$
 select not exists(select 1 from public.wallets w where w.tenant_id=app_private.current_tenant_id() and not app_private.wallet_allowed(w.wallet_id,'balance'));
$$;
alter function app_private.wallet_allowed(uuid,text) owner to postgres;
alter function app_private.all_wallet_balances_visible() owner to postgres;
revoke all on function app_private.wallet_allowed(uuid,text),app_private.all_wallet_balances_visible() from public,anon,authenticated;


CREATE OR REPLACE FUNCTION public.get_access_context()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare u uuid:=auth.uid(); valid boolean:=app_private.session_valid(u,app_private.session_id());
 admin boolean; t uuid; p public.user_profiles; result jsonb;
begin
 if not valid then raise insufficient_privilege using message='Session expired. Sign in again.';end if;
 select exists(select 1 from app_private.platform_superadmins where user_id=u and is_active) into admin;
 select * into p from public.user_profiles where user_id=u;
 t:=app_private.current_tenant_id();
 select jsonb_build_object('is_superadmin',admin,'must_change_password',coalesce(s.must_change_password,false),
 'reset_pending',coalesce(s.reset_pending,false),'tenant_id',t,'business_name',(select business_name from public.tenants where tenant_id=t),
 'full_name',coalesce(p.full_name,case when admin then 'Platform administrator' else '' end),'email',a.email,
 'role',case when admin then 'SUPERADMIN' else (select r.name from public.user_roles ur join public.roles r using(tenant_id,role_id)
 where ur.user_id=u and ur.tenant_id=p.tenant_id order by case r.name when 'OWNER' then 0 when 'MANAGER' then 1 else 2 end limit 1) end,
 'access_status',case when admin then 'active' when p.user_id is null then 'unassigned' when not p.is_active then 'disabled'
 when (select status from public.tenants where tenant_id=p.tenant_id)<>'active' then 'suspended' else 'active' end,
 'access_revision',coalesce(p.revision,0),'permissions',public.get_my_permissions()) into result from auth.users a left join app_private.account_security s on s.user_id=a.id where a.id=u;
 return result;
end $function$
;

CREATE OR REPLACE FUNCTION app_private.has_any_permission(p_permissions text[])
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
 select app_private.current_tenant_id() is not null and exists(
 select 1 from public.permissions p where p.permission_id=any(p_permissions) and case when p.permission_id in ('reports:view','finance:activity','audit:view') then app_private.all_wallet_balances_visible() else true end and (
 app_private.is_owner() or (not p.owner_only and case when exists(
 select 1 from app_private.user_permission_sets x where x.tenant_id=app_private.current_tenant_id() and x.user_id=auth.uid())
 then exists(select 1 from app_private.user_permission_sets x where x.tenant_id=app_private.current_tenant_id()
 and x.user_id=auth.uid() and p.permission_id=any(x.permissions))
 else exists(select 1 from public.user_roles u join public.roles r using(tenant_id,role_id)
 join public.role_permissions rp using(tenant_id,role_id) where u.tenant_id=app_private.current_tenant_id()
 and u.user_id=auth.uid() and rp.permission_id=p.permission_id) end)))
$function$
;

CREATE OR REPLACE FUNCTION app_private.post_wallet_entry()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
 if auth.uid() is not null and not app_private.wallet_allowed(new.wallet_id,'use') then raise insufficient_privilege using message='You cannot use this wallet';end if;
 if new.amount is null or new.amount in ('NaN'::numeric,'Infinity'::numeric,'-Infinity'::numeric) then raise exception 'Invalid wallet amount'; end if;
 select name,kind into new.wallet_name_snapshot,new.wallet_method_snapshot from public.wallets where tenant_id=new.tenant_id and wallet_id=new.wallet_id;
 new.created_by:=auth.uid();
 update public.wallets set balance=balance+new.amount,updated_at=clock_timestamp() where tenant_id=new.tenant_id and wallet_id=new.wallet_id and is_active returning balance into new.balance_after;
 if not found then raise exception 'Wallet not found'; end if;
 new.created_at:=clock_timestamp();
 select lower(concat_ws(' ',new.description,new.type,new.reference_id,new.operation_id,new.transaction_id,w.name,sp.reference,c.name,c.phone,c.shop_name))
 into new.search_document from public.wallets w
 left join public.sale_payments sp on sp.tenant_id=new.tenant_id and sp.payment_id=new.payment_id
 left join public.sales s on s.tenant_id=new.tenant_id and s.sale_id=case when new.type='sale_bottle_expense' then new.reference_id else sp.sale_id end
 left join public.customers c on c.tenant_id=new.tenant_id and c.customer_id=s.customer_id
 where w.tenant_id=new.tenant_id and w.wallet_id=new.wallet_id;
 return new;
end $function$
;

CREATE OR REPLACE FUNCTION public.get_payment_wallets()
 RETURNS TABLE(wallet_id uuid, name text, kind text, type text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_any_permission(array['pos:sell','finance:view','finance:manage','purchases:manage','payroll:pay','logistics:manage']);
begin return query select w.wallet_id,w.name,w.kind,w.type from public.wallets w where w.tenant_id=t and w.is_active and app_private.wallet_allowed(w.wallet_id,'use') 
 order by case w.type when 'cash' then 0 when 'bkash' then 1 when 'nagad' then 2 when 'dealership' then 3 else 4 end,w.name,w.wallet_id; end $function$
;

CREATE OR REPLACE FUNCTION public.get_trip_payment_wallets(p_transit_id uuid)
 RETURNS TABLE(wallet_id uuid, name text, kind text, type text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_permission('payroll:pay');
begin
 perform app_private.require_permission('logistics:manage');
 if not exists(select 1 from public.transits where tenant_id=t and transit_id=p_transit_id and closed_at is null) then raise exception 'Select a trip with open costs'; end if;
 return query select w.wallet_id,w.name,w.kind,w.type from public.wallets w where w.tenant_id=t and w.is_active and app_private.wallet_allowed(w.wallet_id,'use') order by w.name,w.wallet_id;
end $function$
;


-- Raw wallet records include hidden balances. All browser reads use these scoped RPCs.
revoke select on public.wallets,public.wallet_transactions from anon,authenticated;
create function public.get_finance_wallets() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['finance:view','finance:manage','wallets:use','wallets:balances','wallets:ledger']);begin
 return coalesce((select jsonb_agg((to_jsonb(w)-'balance'-'opening_balance') || jsonb_build_object(
 'balance',case when app_private.wallet_allowed(w.wallet_id,'balance') then w.balance end,
 'opening_balance',case when app_private.wallet_allowed(w.wallet_id,'balance') then w.opening_balance end,
 'can_use',app_private.wallet_allowed(w.wallet_id,'use'),'can_balance',app_private.wallet_allowed(w.wallet_id,'balance'),'can_history',app_private.wallet_allowed(w.wallet_id,'history')) order by w.created_at,w.wallet_id)
 from public.wallets w where w.tenant_id=t and (app_private.wallet_allowed(w.wallet_id,'use') or app_private.wallet_allowed(w.wallet_id,'balance') or app_private.wallet_allowed(w.wallet_id,'history') or app_private.has_permission('wallets:manage'))),'[]');end$$;
create function public.get_business_wallet_access(p_user_id uuid,p_tenant_id uuid default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=coalesce(p_tenant_id,app_private.current_tenant_id());begin perform app_private.manage_accounts(t);
 if not exists(select 1 from public.user_profiles where tenant_id=t and user_id=p_user_id) then raise insufficient_privilege;end if;
 return coalesce((select jsonb_agg(jsonb_build_object('wallet_id',w.wallet_id,'name',w.name,'can_use',a.can_use,'can_balance',a.can_balance,'can_history',a.can_history) order by w.created_at,w.wallet_id)
 from public.wallets w left join app_private.user_wallet_access a on a.tenant_id=t and a.user_id=p_user_id and a.wallet_id=w.wallet_id where w.tenant_id=t),'[]');end$$;


CREATE OR REPLACE FUNCTION public.complete_account_operation(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare op app_private.account_operations;u auth.users;t uuid;role_name text;v_result jsonb;
begin
 select * into op from app_private.account_operations where request_id=p_request_id for update;
 if not found or not app_private.actor_can_manage(op.actor_id,op.session_id,op.tenant_id) then raise insufficient_privilege;end if;
 if op.state='complete' then return op.result;end if;
 if op.state<>'pending' then raise exception 'This reset was superseded. Start a new reset request.';end if;
 select * into u from auth.users where id=op.target_user_id for update;
 if not found or u.is_anonymous is true then raise exception 'Auth provisioning has not completed';end if;
 t:=op.tenant_id;
 if op.kind<>'reset' then
  if lower(u.email)<>lower(trim(op.payload->>'email')) or exists(select 1 from public.user_profiles where user_id=u.id)
  or exists(select 1 from app_private.platform_superadmins where user_id=u.id)
  or u.raw_app_meta_data->>'lpg_provisioning_request' is distinct from p_request_id::text then raise insufficient_privilege;end if;
  if op.kind='business' then
   if not exists(select 1 from app_private.platform_superadmins where user_id=op.actor_id and is_active) then raise insufficient_privilege;end if;
   insert into public.tenants(business_name,status) values(trim(op.payload->>'business_name'),'active') returning tenant_id into t;
   insert into public.roles(tenant_id,name) values(t,'OWNER'),(t,'MANAGER'),(t,'SALESMAN');
   insert into public.role_permissions(tenant_id,role_id,permission_id)
   select t,r.role_id,p.permission_id from public.roles r cross join public.permissions p where r.tenant_id=t
   and (r.name='OWNER' or r.name='MANAGER' and not p.owner_only or r.name='SALESMAN' and p.permission_id in ('dashboard:view','pos:sell','sales:view','receipts:print','preferences:manage','wallets:use'));
   role_name:='OWNER';
  else role_name:=op.payload->>'role';end if;
  insert into public.user_profiles(user_id,tenant_id,email,full_name) values(u.id,t,u.email,trim(op.payload->>'name'));
  insert into public.user_roles(tenant_id,user_id,role_id) select t,u.id,role_id from public.roles where tenant_id=t and name=role_name;
 else
  if not exists(select 1 from public.user_profiles where user_id=u.id and tenant_id=t)
  or not exists(select 1 from app_private.account_security where user_id=u.id and reset_pending and reset_request_id=p_request_id and last_reset_write_id=p_request_id) then raise insufficient_privilege;end if;
 end if;
 insert into app_private.account_security(user_id,must_change_password,reset_pending) values(u.id,true,false)
 on conflict(user_id) do update set must_change_password=true,reset_pending=false,reset_request_id=null,
  self_change_nonce=null,self_change_expires_at=null,revision=app_private.account_security.revision+1;
 delete from auth.sessions where user_id=u.id;
 v_result:=jsonb_build_object('user_id',u.id,'tenant_id',t,'must_change_password',true);
 update app_private.account_operations set state='complete',tenant_id=t,result=v_result where request_id=p_request_id;
 insert into app_private.access_audit(tenant_id,actor_id,target_user_id,action,details)
 values(t,op.actor_id,u.id,'account_'||op.kind||'_completed',jsonb_build_object('request_id',p_request_id,'role',role_name));
 return v_result;
end $function$
;

drop function public.manage_business_user(uuid,text,text,boolean,integer,text[],uuid);

CREATE OR REPLACE FUNCTION public.manage_business_user(p_user_id uuid, p_name text, p_role text, p_active boolean, p_expected_revision integer, p_permissions text[] DEFAULT NULL::text[], p_tenant_id uuid DEFAULT NULL::uuid, p_wallet_access jsonb DEFAULT NULL::jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=coalesce(p_tenant_id,app_private.current_tenant_id());p public.user_profiles;old_role text;
begin
 perform app_private.manage_accounts(t);
 perform 1 from public.tenants where tenant_id=t for update;
 select * into p from public.user_profiles where tenant_id=t and user_id=p_user_id for update;
 if not found or p.revision is distinct from p_expected_revision then raise exception 'Account changed. Reload before saving.';end if;
 select r.name into old_role from public.user_roles u join public.roles r using(tenant_id,role_id) where u.tenant_id=t and u.user_id=p_user_id order by case r.name when 'OWNER' then 0 else 1 end limit 1;
 if p_user_id=auth.uid() or old_role='OWNER' and (not app_private.is_superadmin() or p_role<>'OWNER' or p_permissions is not null)
 or old_role<>'OWNER' and p_role not in ('MANAGER','SALESMAN') then raise insufficient_privilege using message='This account or role is protected';end if;
 if nullif(trim(p_name),'') is null or length(trim(p_name))>255 or p_active is null or p_role is null then raise exception 'Enter a valid account name, role and status';end if;
 if old_role='OWNER' and not p_active and not exists(select 1 from public.user_profiles q join public.user_roles ur using(tenant_id,user_id) join public.roles r using(tenant_id,role_id)
 where q.tenant_id=t and q.user_id<>p_user_id and q.is_active and r.name='OWNER') then raise exception 'Keep at least one active OWNER. Suspend the business to block all access.';end if;
 perform app_private.validate_permission_set(p_permissions);
 if p_wallet_access is not null then
  if old_role='OWNER' or jsonb_typeof(p_wallet_access)<>'array' or jsonb_array_length(p_wallet_access)>1000 then raise exception 'Invalid wallet access';end if;
  if exists(select 1 from jsonb_array_elements(p_wallet_access) x where jsonb_typeof(x)<>'object' or x-array['wallet_id','can_use','can_balance','can_history']<>'{}'::jsonb
   or not exists(select 1 from public.wallets w where w.tenant_id=t and w.wallet_id=(x->>'wallet_id')::uuid)
   or jsonb_typeof(x->'can_use') is distinct from 'boolean' or jsonb_typeof(x->'can_balance') is distinct from 'boolean' or jsonb_typeof(x->'can_history') is distinct from 'boolean')
   or (select count(distinct x->>'wallet_id')<>count(*) from jsonb_array_elements(p_wallet_access)x) then raise exception 'Invalid wallet access';end if;
  delete from app_private.user_wallet_access where tenant_id=t and user_id=p_user_id;
  insert into app_private.user_wallet_access select t,p_user_id,(x->>'wallet_id')::uuid,(x->>'can_use')::boolean,(x->>'can_balance')::boolean,(x->>'can_history')::boolean from jsonb_array_elements(p_wallet_access)x;
 end if;
 update public.user_profiles set full_name=trim(p_name),is_active=p_active,revision=revision+1 where user_id=p_user_id;
 delete from public.user_roles where tenant_id=t and user_id=p_user_id;
 insert into public.user_roles(tenant_id,user_id,role_id) select t,p_user_id,role_id from public.roles where tenant_id=t and name=p_role;
 delete from app_private.user_permission_sets where tenant_id=t and user_id=p_user_id;
 if p_permissions is not null then insert into app_private.user_permission_sets values(t,p_user_id,p_permissions);end if;
 if not p_active then delete from auth.sessions where user_id=p_user_id;end if;
 insert into app_private.access_audit(tenant_id,actor_id,target_user_id,action,details)
 values(t,auth.uid(),p_user_id,'user_updated',jsonb_build_object('previous_role',old_role,'role',p_role,'active',p_active,'permissions',p_permissions,'name',trim(p_name),'wallet_access',p_wallet_access));
end $function$
;

CREATE OR REPLACE FUNCTION public.get_wallet_ledger(p_filters jsonb DEFAULT '{}'::jsonb, p_offset integer DEFAULT 0, p_limit integer DEFAULT 25)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_any_permission(array['wallets:ledger','finance:view']); result jsonb;
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
  select x.transaction_id,x.created_at,x.entry_no,case when nullif($2->>'business','') is null then x.amount else coalesce((x.business_amounts->>($2->>'business'))::numeric,0) end amount from public.wallet_transactions x where x.tenant_id=$1 and app_private.wallet_allowed(x.wallet_id,'history')
   and (nullif($2->>'wallet','') is null or x.wallet_id=nullif($2->>'wallet','')::uuid)
   and (nullif($2->>'type','') is null or x.type_id=nullif($2->>'type','')::uuid) and (nullif($2->>'business','') is null or coalesce((x.business_amounts->>($2->>'business'))::numeric,0)<>0)
   and (coalesce($2->>'direction','all')='all' or ($2->>'direction'='in' and (case when nullif($2->>'business','') is null then x.amount else (x.business_amounts->>($2->>'business'))::numeric end)>0) or ($2->>'direction'='out' and (case when nullif($2->>'business','') is null then x.amount else (x.business_amounts->>($2->>'business'))::numeric end)<0))
   and (nullif($2->>'from','') is null or x.created_at >= (nullif($2->>'from','')::date::timestamp at time zone 'Asia/Dhaka'))
   and (nullif($2->>'to','') is null or x.created_at < ((nullif($2->>'to','')::date+1)::timestamp at time zone 'Asia/Dhaka'))
   and (nullif($2->>'min','') is null or abs(case when nullif($2->>'business','') is null then x.amount else (x.business_amounts->>($2->>'business'))::numeric end)>=nullif($2->>'min','')::numeric)
   and (nullif($2->>'max','') is null or abs(case when nullif($2->>'business','') is null then x.amount else (x.business_amounts->>($2->>'business'))::numeric end)<=nullif($2->>'max','')::numeric)
   and (%s)
 ), page as materialized (
  select * from matching order by
   case when $3='date_desc' then created_at end desc,case when $3='date_asc' then created_at end,
   case when $3='amount_desc' then abs(amount) end desc,case when $3='amount_asc' then abs(amount) end,entry_no desc limit $4 offset $5
 ) select jsonb_build_object('total',(select count(*) from matching),
  'received',(select coalesce(sum(amount) filter(where amount>0),0) from matching),
  'paid_out',(select -coalesce(sum(amount) filter(where amount<0),0) from matching),
  'entries',coalesce((select jsonb_agg((to_jsonb(p)-'search_document')||app_private.financial_source_link(p.tenant_id,'wallet',p.transaction_id)||jsonb_build_object('amount',keys.amount,'total_amount',p.amount,'balance_after',case when app_private.wallet_allowed(p.wallet_id,'balance') then p.balance_after end,'type_name',coalesce((select e.type_name from public.financial_entries e where e.tenant_id=p.tenant_id and e.entry_id=p.reference_id),ft.name),'wallet_name',coalesce(p.wallet_name_snapshot,w.name),'counterparty',cw.name,'actor',up.full_name,
   'payment_reference',coalesce(sp.reference,pp.reference),'customer_name',c.name,'customer_phone',c.phone,'source',case when sp.payment_id is not null or p.type='sale_bottle_expense' then 'sale' when p.type like 'purchase%%' then 'purchase' when p.type like 'transit%%' or p.type like 'transport%%' then 'transit' else null end) order by
   case when $3='date_desc' then p.created_at end desc,case when $3='date_asc' then p.created_at end,
   case when $3='amount_desc' then abs(keys.amount) end desc,case when $3='amount_asc' then abs(keys.amount) end,p.entry_no desc)
   from page keys join public.wallet_transactions p on p.tenant_id=$1 and p.transaction_id=keys.transaction_id
   join public.wallets w on w.tenant_id=$1 and w.wallet_id=p.wallet_id
   left join public.financial_types ft on ft.type_id=p.type_id left join public.wallets cw on cw.tenant_id=$1 and cw.wallet_id=p.counterparty_wallet_id
   left join app_private.tenant_actors up on up.tenant_id=$1 and up.user_id=p.created_by
   left join public.sale_payments sp on sp.tenant_id=$1 and sp.payment_id=p.payment_id
   left join public.purchase_payments pp on pp.tenant_id=$1 and pp.payment_id=p.purchase_payment_id
   left join public.sales s on s.tenant_id=$1 and s.sale_id=case when p.type='sale_bottle_expense' then p.reference_id else sp.sale_id end
   left join public.customers c on c.tenant_id=$1 and c.customer_id=s.customer_id),'[]'))
 $ledger$,search_condition) into result using t,p_filters,sorting,p_limit,p_offset;
 return result;
end $function$
;

CREATE OR REPLACE FUNCTION public.get_financial_entries(p_filters jsonb DEFAULT '{}'::jsonb, p_offset integer DEFAULT 0, p_limit integer DEFAULT 25)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$declare
 tenant uuid:=app_private.require_any_permission(array['finance:entries:view']);result jsonb;
 search text:=trim(coalesce(p_filters->>'search',''));category text:=nullif(p_filters->>'category','');business text:=nullif(p_filters->>'business','');begin
 if p_filters is null or jsonb_typeof(p_filters)<>'object' or length(search)>500 or p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100
 or category is not null and category not in ('withdrawal','expense','capital','revenue','equipment') or business is not null and business not in ('lpg','stove','logistics')
 or nullif(p_filters->>'from','')::date>nullif(p_filters->>'to','')::date then raise exception 'Invalid financial entry filters';end if;
 with matching as materialized(select e.* from public.financial_entries e where e.tenant_id=tenant and (e.created_by=auth.uid() or app_private.has_permission('finance:entries:all'))
 and (category is null or app_private.financial_category(e.account)=category)
 and (nullif(p_filters->>'type','') is null or e.type_id=nullif(p_filters->>'type','')::uuid)
 and (business is null or e.allocations ? business)
 and (nullif(p_filters->>'from','') is null or e.occurred_on>=nullif(p_filters->>'from','')::date)
 and (nullif(p_filters->>'to','') is null or e.occurred_on<=nullif(p_filters->>'to','')::date)
 and (search='' or position(lower(search) in lower(e.type_name||' '||e.description))>0)),
 page as(select * from matching order by occurred_on desc,created_at desc,entry_id limit p_limit offset p_offset)
 select jsonb_build_object('total',(select count(*) from matching),'entries',coalesce((select jsonb_agg(to_jsonb(p)||jsonb_build_object(
 'category',app_private.financial_category(p.account),'returned',coalesce((select sum(r.amount) from public.financial_entries r where r.tenant_id=tenant and r.reversal_of=p.entry_id),0)) order by p.occurred_on desc,p.created_at desc,p.entry_id) from page p),'[]')) into result;return result;end $function$
;

CREATE OR REPLACE FUNCTION public.get_financial_entry(p_entry_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$declare
 t uuid:=app_private.require_any_permission(array['finance:entries:view']);result jsonb;begin
 select to_jsonb(e)||jsonb_build_object('returned',coalesce((select sum(amount) from public.financial_entries r where r.tenant_id=t and r.reversal_of=e.entry_id),0)) into result from public.financial_entries e where e.tenant_id=t and e.entry_id=p_entry_id and (e.created_by=auth.uid() or app_private.has_permission('finance:entries:all'));
 if result is null then raise exception 'Financial entry unavailable' using errcode='42501';end if;return result;end $function$
;

CREATE OR REPLACE FUNCTION public.record_financial_entry(p_payload jsonb, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$declare
 t uuid:=app_private.require_permission('finance:manage');prior public.finance_requests;body jsonb:=jsonb_build_object('action','financial_entry','actor',auth.uid(),'body',p_payload);
 ft public.financial_types;original public.financial_entries;asset public.business_assets;w public.wallets;id uuid:=gen_random_uuid();aid uuid;
 a numeric:=app_private.purchase_money((p_payload->>'amount')::numeric);d date:=(p_payload->>'date')::date;cash numeric;alloc jsonb;amounts jsonb;returned numeric;result jsonb;type_name text;account text;revision integer;begin perform app_private.require_permission(case when p_payload->>'reversal_of' is not null then 'finance:returns' else 'finance:entries' end);
 if p_request_id is null then raise exception 'Request ID is required';end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from body then raise exception 'Request ID already used with different details';end if;return prior.result;end if;
 if a is null or a<=0 or a<>(p_payload->>'amount')::numeric or d is null or not isfinite(d) or d>(now() at time zone 'Asia/Dhaka')::date or length(trim(coalesce(p_payload->>'description',''))) not between 1 and 1000 then raise exception 'Enter a positive two-decimal amount, date and description';end if;
 if p_payload->>'reversal_of' is not null then
  select * into original from public.financial_entries where tenant_id=t and entry_id=(p_payload->>'reversal_of')::uuid and reversal_of is null for update;
  if found and original.created_by is distinct from auth.uid() and not app_private.has_permission('finance:entries:all') then raise insufficient_privilege;end if;
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
end $function$
;

CREATE OR REPLACE FUNCTION public.get_accounting_register(p_kind text, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_any_permission(array['finance:view','finance:manage']);r jsonb;begin
 if p_kind in ('loans','lending') then perform app_private.require_permission('finance:loans');else perform app_private.require_owner('finance:manage');end if;
 if p_offset is null or p_offset<0 then raise exception 'Invalid page';end if;
 if p_kind in ('loans','lending') then select jsonb_build_object('total',count(*),'entries',coalesce((select jsonb_agg(to_jsonb(p)) from(select * from public.loans where tenant_id=t and direction=case when p_kind='lending' then 'lent' else 'borrowed' end order by created_at desc,loan_id offset p_offset limit 20)p),'[]')) into r from public.loans where tenant_id=t and direction=case when p_kind='lending' then 'lent' else 'borrowed' end;
 elsif p_kind='assets' then select jsonb_build_object('total',count(*),'entries',coalesce((select jsonb_agg(to_jsonb(p)) from(select * from public.business_assets where tenant_id=t order by created_at desc,asset_id offset p_offset limit 20)p),'[]')) into r from public.business_assets where tenant_id=t;
 elsif p_kind in ('opening','obligations') then select jsonb_build_object('total',count(*),'entries',coalesce((select jsonb_agg(to_jsonb(p)) from(select * from public.finance_obligations where tenant_id=t and origin=case when p_kind='opening' then 'opening' else 'incurred' end order by created_at desc,obligation_id offset p_offset limit 20)p),'[]')) into r from public.finance_obligations where tenant_id=t and origin=case when p_kind='opening' then 'opening' else 'incurred' end;
 else raise exception 'Invalid register';end if;return r;end $function$
;

CREATE OR REPLACE FUNCTION public.get_accounting_history(p_kind text, p_id uuid, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_any_permission(array['finance:view','finance:manage','logistics:view','logistics:manage']);r jsonb;begin
 if p_offset is null or p_offset<0 then raise exception 'Invalid page';end if;
 if p_kind='loan' then perform app_private.require_permission('finance:loans');elsif p_kind<>'vehicle' then perform app_private.require_owner('finance:manage');end if;
 with matching as(select to_jsonb(l) entry,l.created_at from public.loan_activity l where p_kind='loan' and l.tenant_id=t and l.loan_id=p_id
 union all select to_jsonb(a),a.created_at from public.asset_activity a where p_kind='asset' and a.tenant_id=t and a.asset_id=p_id
 union all select to_jsonb(v),v.created_at from public.vehicle_lifecycle v where p_kind='vehicle' and v.tenant_id=t and v.vehicle_id=p_id),page as(select * from matching order by created_at desc offset p_offset limit 20)
 select jsonb_build_object('total',(select count(*) from matching),'entries',coalesce((select jsonb_agg(entry) from page),'[]')) into r;return r;end $function$
;

CREATE OR REPLACE FUNCTION public.get_financial_activity_wallets(p_source text, p_id uuid, p_offset integer DEFAULT 0, p_limit integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_any_permission(array['finance:activity']);r jsonb;begin
 if p_source not in ('purchase','transit','service_trip') or p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid wallet audit page';end if;
 with entries as materialized(select x.transaction_id,x.wallet_name_snapshot wallet_name,x.amount,x.description,x.created_at,x.entry_no
 from public.wallet_transactions x where x.tenant_id=t and (x.reference_id=p_id or p_source='transit' and exists(select 1 from public.employee_payments ep where ep.tenant_id=t and ep.transit_id=p_id and ep.payment_id=x.reference_id))),
 page as(select * from entries order by entry_no desc offset p_offset limit p_limit)
 select jsonb_build_object('total',(select count(*) from entries),'entries',coalesce((select jsonb_agg(to_jsonb(p) order by entry_no desc) from page p),'[]')) into r;return r;
end $function$
;

CREATE OR REPLACE FUNCTION app_private.analysis_scope(filters jsonb)
 RETURNS uuid[]
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$declare
 tenant uuid:=app_private.require_any_permission(array['finance:view','finance:manage']);begin perform app_private.require_any_permission(array['reports:view','finance:activity']);
 if nullif(filters->>'business_id','') is not null and (filters->>'business_id')::uuid<>tenant then raise exception 'Business access denied' using errcode='42501';end if;
 return array[tenant];end $function$
;

CREATE OR REPLACE FUNCTION public.get_finance_analysis(p_filters jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare ids uuid[]:=app_private.analysis_scope(p_filters);r record;result jsonb;f date:=(p_filters->>'from')::date;u date:=(p_filters->>'to')::date;begin perform app_private.require_permission('reports:view');
 if f is null or u is null or not isfinite(f) or not isfinite(u) or f>u or u>(now() at time zone 'Asia/Dhaka')::date then raise exception 'Choose a valid reporting period';end if;
 for r in select unnest(ids) id loop perform app_private.sync_payroll(r.id);end loop;
 result:=app_private.finance_analysis_report(p_filters);
 return result;end $function$
;

CREATE OR REPLACE FUNCTION public.get_accounting_health(p_filters jsonb, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare ids uuid[]:=app_private.analysis_scope(p_filters);r jsonb;begin perform app_private.require_permission('reports:view');
 if p_offset is null or p_offset<0 or p_offset>1000000 then raise exception 'Invalid diagnostic page';end if;
 select jsonb_build_object('pending',(select count(*) from app_private.reconciliation_queue where tenant_id=any(ids)),
 'snapshots',(select count(*) from app_private.accounting_snapshots s join app_private.accounting_snapshot_state st using(tenant_id) where s.tenant_id=any(ids) and s.month_end<st.invalid_from),
 'total',(select count(*) from app_private.reconciliation_findings where tenant_id=any(ids)),
 'entries',coalesce((select jsonb_agg(to_jsonb(f) order by finding_id desc) from(select * from app_private.reconciliation_findings where tenant_id=any(ids) order by finding_id desc offset p_offset limit 20)f),'[]')) into r;return r;end $function$
;

CREATE OR REPLACE FUNCTION public.get_analysis_details(p_filters jsonb, p_metric text, p_category text DEFAULT NULL::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 12)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare ids uuid[]:=app_private.analysis_scope(p_filters);r jsonb;f date:=(p_filters->>'from')::date;u date:=(p_filters->>'to')::date;begin perform app_private.require_permission('reports:view');
 if p_metric is distinct from 'journal' or p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 100 or f is null or u is null or not isfinite(f) or not isfinite(u) or f>u or length(coalesce(p_filters->>'search',''))>500 then raise exception 'Invalid journal filters';end if;
 with matching as materialized(select j.* from public.accounting_journals j where j.tenant_id=any(ids) and j.occurred_on between f and u
 and (nullif(p_filters->>'source','') is null or j.source=p_filters->>'source')
 and app_private.finance_search(concat_ws(' ',j.description,j.source,j.source_id,j.entry_no),coalesce(p_filters->>'search',''))
 and (coalesce(p_filters->>'category','all')='all' or exists(select 1 from public.accounting_lines l where l.tenant_id=j.tenant_id and l.journal_id=j.journal_id and l.business_category=p_filters->>'category'))
 and (p_category is null or exists(select 1 from public.accounting_lines l where l.tenant_id=j.tenant_id and l.journal_id=j.journal_id and l.account=p_category))),
 page as materialized(select * from matching order by occurred_on desc,entry_no desc offset p_offset limit p_limit),
 details as(select p.*,(select count(*) from public.accounting_lines l where l.tenant_id=p.tenant_id and l.journal_id=p.journal_id) line_count,
 coalesce((select sum(greatest(0,l.amount)) from public.accounting_lines l where l.tenant_id=p.tenant_id and l.journal_id=p.journal_id),0) total_debit,
 case p.source when 'wallet' then (select x.reference_id from public.wallet_transactions x where x.tenant_id=p.tenant_id and x.transaction_id=p.source_id)
 when 'inventory' then (select m.reference_id from public.inventory_movements m where m.tenant_id=p.tenant_id and m.movement_id=p.source_id) else p.source_id end transaction_reference from page p)
 select jsonb_build_object('total',(select count(*) from matching),'entries',coalesce((select jsonb_agg(to_jsonb(p) order by occurred_on desc,entry_no desc) from details p),'[]'),
 'sources',coalesce((select jsonb_agg(source order by source) from(select distinct source from public.accounting_journals where tenant_id=any(ids) and occurred_on between f and u)s),'[]')) into r;return r;end $function$
;

CREATE OR REPLACE FUNCTION public.get_accounting_breakdown(p_filters jsonb, p_group text, p_side text, p_mode text DEFAULT 'components'::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$declare
 ids uuid[]:=app_private.analysis_scope(p_filters);d date:=(p_filters->>'to')::date;f date:=(p_filters->>'from')::date;
 cat text:=coalesce(p_filters->>'category','all');original boolean:=false;before_day boolean:=false;r jsonb;begin
 perform app_private.require_any_permission(array['reports:view','finance:activity']);
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
 sum(b.sign*b.amount) amount
 from evidence b join public.accounting_accounts a on a.code=b.account where cat='all' or b.business_category=cat group by 1,2,3,4,5,6,7),
 classified as(select *,sum(amount) over(partition by tenant_id,account,entity_id,business_category) control_total,case when kind='liability' and sum(amount) over(partition by tenant_id,account,entity_id,business_category)>0 then 'asset'
 when kind='asset' and account<>'cash' and sum(amount) over(partition by tenant_id,account,entity_id,business_category)<0 then 'liability' else kind end reported_kind from balances),
 selected as materialized(select *,case when p_group='withdrawals' or p_group='all' and account='withdrawals' then 1 when p_group in ('equity','accumulated_income') or reported_kind in ('liability','income','equity') then -1 else 1 end sign
 from classified where (p_group='all' or app_private.analysis_matches(p_group,account,reported_kind))
 and (nullif(p_filters->>'account','') is null or account=p_filters->>'account')
 and (nullif(p_filters->>'type_id','') is null or type_id=(p_filters->>'type_id')::uuid)
 and (nullif(p_filters->>'component_business','') is null or business_category=p_filters->>'component_business')
 and (nullif(p_filters->>'entity_id','') is null or p_filters->>'entity_id'='none' and entity_id is null or entity_id=nullif(nullif(p_filters->>'entity_id',''),'none')::uuid)),
 described as materialized(select s.*,case ft.code when 'internal_inventory' then 'Transport in Supplies' when 'internal_cogs' then 'Transport COGS' when 'internal_transport' then 'Purchase transport' else ft.name end type_name,app_private.analysis_entity(s.tenant_id,s.account,s.entity_id) entity from selected s join public.financial_types ft using(type_id)),
 components as materialized(select * from described where
 (nullif(p_filters->>'min','') is null or abs(amount)>=(p_filters->>'min')::numeric)
 and (nullif(p_filters->>'max','') is null or abs(amount)<=(p_filters->>'max')::numeric)
 and (coalesce(p_filters->>'direction','all')='all' or p_filters->>'direction'='increase' and amount*sign>0 or p_filters->>'direction'='decrease' and amount*sign<0) and amount<>0 and (kind in ('income','expense','equity') or control_total<>0) and app_private.finance_search(concat_ws(' ',name,type_name,business_category,entity->>'entity_name'),coalesce(p_filters->>'search',''))),
 component_page as(select * from components order by abs(amount) desc,tenant_id,account,type_id,business_category,entity_id nulls first offset p_offset limit p_limit),
 movements as materialized(select j.tenant_id,j.journal_id,j.entry_no,j.occurred_on,j.description,j.source,j.source_id,j.source_id transaction_reference,j.estimated,l.line_no,l.account,s.name,l.type_id,s.type_name,l.business_category,l.entity_id,
 (l.amount)*s.sign amount,app_private.analysis_entity(l.tenant_id,l.account,l.entity_id)||app_private.financial_source_link(j.tenant_id,j.source,j.source_id) entity
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
 else coalesce((select jsonb_agg((to_jsonb(p)-'entity')||entity order by case when p_filters->>'sort'='oldest' then occurred_on end asc,case when p_filters->>'sort'='largest' then abs(amount) end desc,case when p_filters->>'sort'='smallest' then abs(amount) end asc,occurred_on desc,entry_no desc,line_no) from history_page p),'[]') end) into r;return r;end $function$
;


-- A wallet manager must see the balance to avoid balance-dependent errors disclosing hidden data.


CREATE OR REPLACE FUNCTION public.save_finance_wallet(p_payload jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_permission('finance:manage'); id uuid:=(p_payload->>'wallet_id')::uuid; w public.wallets; n text:=trim(p_payload->>'name'); k text:=p_payload->>'kind'; active boolean:=coalesce((p_payload->>'is_active')::boolean,true);
begin perform app_private.require_permission('wallets:manage');
 if id is not null and not app_private.wallet_allowed(id,'balance') then raise insufficient_privilege using message='Balance visibility is required to manage this wallet';end if;
 if n is null or length(n) not between 1 and 80 or length(coalesce(p_payload->>'details',''))>500 then raise exception 'Enter a wallet name (up to 80 characters) and short details'; end if;
 if id is null then
  if k is null or k not in ('cash','bank','bkash','nagad','other') then raise exception 'Invalid wallet category'; end if;
  insert into public.wallets(tenant_id,type,name,kind,details) values(t,'custom',n,k,coalesce(p_payload->>'details','')) returning wallet_id into id;
 else
  select * into w from public.wallets where tenant_id=t and wallet_id=id for update;
  if not found then raise exception 'Wallet not found'; end if;
  if w.revision is distinct from (p_payload->>'revision')::integer then raise exception 'Wallet changed. Reload before saving.' using errcode='P0001'; end if;
  if k is distinct from w.kind then raise exception 'Wallet category cannot change after creation'; end if;
  if w.type<>'custom' and not active then raise exception 'Default wallets cannot be archived'; end if;
  if not active and w.balance<>0 then raise exception 'Transfer or adjust the balance to zero before archiving'; end if;
  update public.wallets set name=n,details=coalesce(p_payload->>'details',''),is_active=active,revision=revision+1,updated_at=now() where tenant_id=t and wallet_id=id;
 end if;
 insert into public.audit_logs(tenant_id,table_name,record_id,action,old_data,new_data,performed_by)
 values(t,'wallets',id,'UPDATE',case when w.wallet_id is not null then to_jsonb(w) else null end,p_payload,auth.uid());
 return id;
end $function$
;


revoke all on function public.get_finance_wallets(),public.get_business_wallet_access(uuid,uuid),public.manage_business_user(uuid,text,text,boolean,integer,text[],uuid,jsonb) from public,anon;
grant execute on function public.get_finance_wallets(),public.get_business_wallet_access(uuid,uuid),public.manage_business_user(uuid,text,text,boolean,integer,text[],uuid,jsonb) to authenticated;
notify pgrst,'reload schema';
