create table public.loans (
 tenant_id uuid not null references public.tenants(tenant_id),loan_id uuid not null default gen_random_uuid(),lender text not null check(length(trim(lender)) between 1 and 150),
 description text not null,principal numeric(16,2) not null check(principal>0 and principal<1000000000000),outstanding numeric(16,2) not null check(outstanding>=0),
 received_on date not null,opening boolean not null default false,created_at timestamptz not null default clock_timestamp(),created_by uuid,
 primary key(tenant_id,loan_id),check(outstanding<=principal)
);
create table public.loan_activity (
 tenant_id uuid not null,activity_id uuid not null default gen_random_uuid(),loan_id uuid not null,action text not null,amount numeric(16,2) not null,
 wallet_id uuid,occurred_on date not null,created_at timestamptz not null default clock_timestamp(),created_by uuid,
 primary key(tenant_id,activity_id),foreign key(tenant_id,loan_id) references public.loans(tenant_id,loan_id),foreign key(tenant_id,wallet_id) references public.wallets(tenant_id,wallet_id)
);
create index loan_activity_parent on public.loan_activity(tenant_id,loan_id,created_at desc);
create index loan_activity_wallet on public.loan_activity(tenant_id,wallet_id);
create table public.supplier_commissions (
 tenant_id uuid not null references public.tenants(tenant_id),commission_id uuid not null default gen_random_uuid(),supplier_name text not null,
 amount numeric(16,2) not null check(amount>0 and amount<1000000000000),used numeric(16,2) not null default 0 check(used>=0),earned_on date not null,
 business_category text not null check(business_category in ('lpg','stove')),description text not null,created_at timestamptz not null default clock_timestamp(),created_by uuid,
 primary key(tenant_id,commission_id),check(used<=amount)
);
create table public.commission_applications (
 tenant_id uuid not null,application_id uuid not null default gen_random_uuid(),commission_id uuid not null,purchase_id uuid not null,amount numeric(16,2) not null check(amount>0),
 reversal_of uuid,created_at timestamptz not null default clock_timestamp(),created_by uuid,primary key(tenant_id,application_id),unique(tenant_id,reversal_of),
 foreign key(tenant_id,commission_id) references public.supplier_commissions(tenant_id,commission_id),foreign key(tenant_id,purchase_id) references public.purchases(tenant_id,purchase_id),
 foreign key(tenant_id,reversal_of) references public.commission_applications(tenant_id,application_id)
);
create index commission_purchase on public.commission_applications(tenant_id,purchase_id);
create index commission_source on public.commission_applications(tenant_id,commission_id);
alter table public.vehicles add column availability text not null default 'active' check(availability in ('active','out_of_service','retired'));
create table public.vehicle_lifecycle (
 tenant_id uuid not null,activity_id uuid not null default gen_random_uuid(),vehicle_id uuid not null,previous_status text not null,new_status text not null,reason text not null,
 created_at timestamptz not null default clock_timestamp(),created_by uuid,primary key(tenant_id,activity_id),foreign key(tenant_id,vehicle_id) references public.vehicles(tenant_id,vehicle_id)
);
create index vehicle_lifecycle_parent on public.vehicle_lifecycle(tenant_id,vehicle_id,created_at desc);
create function app_private.require_vehicle_available() returns trigger language plpgsql set search_path='' as $$begin
 perform 1 from public.vehicles where tenant_id=new.tenant_id and vehicle_id=new.vehicle_id and availability='active' for update;
 if not found then raise exception 'Vehicle is out of service or permanently retired';end if;return new;end $$;
create trigger aa_vehicle_available before insert on public.transits for each row execute function app_private.require_vehicle_available();
create function app_private.guard_vehicle_retirement() returns trigger language plpgsql set search_path='' as $$begin
 if old.availability='retired' and new.availability<>'retired' then raise exception 'Retired vehicles cannot be restored';end if;return new;end $$;
create trigger aa_vehicle_retired before update on public.vehicles for each row execute function app_private.guard_vehicle_retirement();
create function public.set_vehicle_availability(p_vehicle_id uuid,p_available boolean,p_reason text,p_request_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_owner('logistics:manage');v public.vehicles;prior public.finance_requests;body jsonb:=jsonb_build_object('action','vehicle_availability','actor',auth.uid(),'vehicle',p_vehicle_id,'available',p_available,'reason',p_reason);result jsonb;begin
 if p_request_id is null or p_available is null or nullif(trim(p_reason),'') is null or length(p_reason)>1000 then raise exception 'Request ID and reason are required';end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from body then raise exception 'Request ID already used';end if;return prior.result;end if;
 select * into v from public.vehicles where tenant_id=t and vehicle_id=p_vehicle_id for update;
 if not found or v.availability='retired' then raise exception 'Vehicle not found or permanently retired';end if;
 update public.vehicles set availability=case when p_available then 'active' else 'out_of_service' end,revision=revision+1 where tenant_id=t and vehicle_id=p_vehicle_id;
 insert into public.vehicle_lifecycle(tenant_id,vehicle_id,previous_status,new_status,reason,created_by) values(t,p_vehicle_id,v.availability,case when p_available then 'active' else 'out_of_service' end,trim(p_reason),auth.uid());
 result:=jsonb_build_object('vehicle_id',p_vehicle_id);insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,result,auth.uid());return result;end $$;
-- A single owner operation contract uses the existing finance request and wallet
-- infrastructure. Interest remains an ordinary paid expense, never principal.
create function public.accounting_operation(p_payload jsonb,p_request_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
<<accounting_op>>
declare t uuid:=app_private.require_owner('finance:manage');action text:=p_payload->>'action';d date:=(p_payload->>'date')::date;
 body jsonb:=jsonb_build_object('action','accounting_operation','actor',auth.uid(),'body',p_payload);prior public.finance_requests;result jsonb;id uuid;amount numeric;
 wallet uuid:=(p_payload->>'wallet_id')::uuid;w public.wallets;loan public.loans;asset public.business_assets;commission public.supplier_commissions;p public.purchases;
 entries jsonb:='[]';note text:=trim(p_payload->>'description');account text;counter text;proceeds numeric;expense numeric;book numeric;category text:=coalesce(p_payload->>'business_category','shared');begin
 if p_request_id is null or d is null or not isfinite(d) or d>(now() at time zone 'Asia/Dhaka')::date or nullif(note,'') is null or length(note)>1000 then raise exception 'Request ID, date and description are required';end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from body then raise exception 'Request ID already used with different details';end if;return prior.result;end if;
 if category not in ('lpg','stove','logistics','shared') then raise exception 'Invalid business category';end if;
 amount:=app_private.purchase_money(coalesce((p_payload->>'amount')::numeric,0));
 if action in ('loan_repay','capital','opening_cash') or action='loan_create' and not coalesce((p_payload->>'opening')::boolean,false) or action='asset_register' and p_payload->>'funding'='wallet' or action='asset_dispose' then
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
 elsif action in ('capital','opening_cash') then
  if amount<=0 then raise exception 'Enter a positive amount';end if;id:=p_request_id;
  insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,operation_id,description,accounting_date) values(t,wallet,amount,case when action='opening_cash' then 'opening_cash' else 'owner_capital' end,id,p_request_id,note,d);

 elsif action='opening_entry' then
  account:=p_payload->>'account';id:=coalesce((p_payload->>'entity_id')::uuid,p_request_id);
  if amount<=0 or account is null or account not in ('customer_receivable','supplier_payable','other_assets','other_liability','equipment','supplier_receivable','operating_payable','employee_payable') then raise exception 'Choose an opening asset / liability and positive value';end if;
  if account='customer_receivable' then
   if not exists(select 1 from public.customers where tenant_id=t and customer_id=id) then raise exception 'Choose an existing business customer';end if;
   insert into public.customer_transactions(tenant_id,customer_id,type,amount,reference_id,created_by) values(t,id,'invoice_charge',-amount,p_request_id,auth.uid());
  end if;
  amount:=case when account in ('supplier_payable','other_liability','operating_payable','employee_payable') then -amount else amount end;
  entries:=jsonb_build_array(app_private.accounting_line(account,amount,category,id),app_private.accounting_line('opening_equity',-amount));
 elsif action='asset_register' then
  account:=p_payload->>'kind';counter:=case p_payload->>'funding' when 'wallet' then 'other_assets' when 'opening' then 'opening_equity' when 'capital' then 'capital' end;
  if p_payload->>'amount' is null or amount<0 or account is null or account not in ('vehicles','equipment','other_assets') or counter is null or nullif(trim(p_payload->>'name'),'') is null then raise exception 'Enter an asset name, book value, type and funding';end if;
  if (p_payload->>'vehicle_id')::uuid is not null and (account<>'vehicles' or not exists(select 1 from public.vehicles where tenant_id=t and vehicle_id=(p_payload->>'vehicle_id')::uuid)) then raise exception 'Vehicle not found';end if;
  insert into public.business_assets(tenant_id,vehicle_id,name,kind,cost,acquired_on,valuation_source,created_by) values(t,(p_payload->>'vehicle_id')::uuid,trim(p_payload->>'name'),account,amount,d,'verified',auth.uid()) returning asset_id into id;
  if counter='other_assets' and amount>0 then insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,operation_id,description,accounting_date) values(t,wallet,-amount,'asset_purchase',id,p_request_id,note,d);end if;
  entries:=jsonb_build_array(app_private.accounting_line(account,amount,'shared',id),app_private.accounting_line(counter,-amount,'shared',case when counter='other_assets' then id end));
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
create function app_private.reverse_purchase_commissions() returns trigger language plpgsql set search_path='' as $$declare r record;begin
 if new.status='cancelled' and old.status<>'cancelled' then
  for r in select a.* from public.commission_applications a where a.tenant_id=new.tenant_id and a.purchase_id=new.purchase_id and a.reversal_of is null and not exists(select 1 from public.commission_applications b where b.tenant_id=a.tenant_id and b.reversal_of=a.application_id) order by a.commission_id for update loop
   update public.supplier_commissions set used=used-r.amount where tenant_id=new.tenant_id and commission_id=r.commission_id;
   insert into public.commission_applications(tenant_id,commission_id,purchase_id,amount,reversal_of,created_by) values(r.tenant_id,r.commission_id,r.purchase_id,r.amount,r.application_id,auth.uid());
   perform app_private.post_journal(r.tenant_id,'commission_reversal',r.application_id,'cancel',(now() at time zone 'Asia/Dhaka')::date,'Return applied supplier commission after cancellation',jsonb_build_array(
   app_private.accounting_line('supplier_payable',-r.amount,new.business_category,new.purchase_id),app_private.accounting_line('supplier_receivable',r.amount,new.business_category,r.commission_id)));
  end loop;
 end if;return new;end $$;
create trigger reverse_purchase_commissions after update of status on public.purchases for each row execute function app_private.reverse_purchase_commissions();
create function public.get_accounting_register(p_kind text,p_offset integer default 0) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['finance:view','finance:manage']);r jsonb;begin
 if p_offset is null or p_offset<0 then raise exception 'Invalid page';end if;
 if p_kind='loans' then select jsonb_build_object('total',count(*),'entries',coalesce((select jsonb_agg(to_jsonb(p)) from(select * from public.loans where tenant_id=t order by created_at desc,loan_id offset p_offset limit 20)p),'[]')) into r from public.loans where tenant_id=t;
 elsif p_kind='assets' then select jsonb_build_object('total',count(*),'entries',coalesce((select jsonb_agg(to_jsonb(p)) from(select * from public.business_assets where tenant_id=t order by created_at desc,asset_id offset p_offset limit 20)p),'[]')) into r from public.business_assets where tenant_id=t;
 elsif p_kind='commissions' then select jsonb_build_object('total',count(*),'entries',coalesce((select jsonb_agg(to_jsonb(p)) from(select * from public.supplier_commissions where tenant_id=t order by created_at desc,commission_id offset p_offset limit 20)p),'[]')) into r from public.supplier_commissions where tenant_id=t;
 else raise exception 'Invalid register';end if;return r;end $$;
create function public.get_accounting_history(p_kind text,p_id uuid,p_offset integer default 0) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['finance:view','finance:manage','logistics:view','logistics:manage']);r jsonb;begin
 if p_offset is null or p_offset<0 then raise exception 'Invalid page';end if;
 if p_kind<>'vehicle' then perform app_private.require_any_permission(array['finance:view','finance:manage']);end if;
 with matching as(select to_jsonb(l) entry,l.created_at from public.loan_activity l where p_kind='loan' and l.tenant_id=t and l.loan_id=p_id
 union all select to_jsonb(a),a.created_at from public.asset_activity a where p_kind='asset' and a.tenant_id=t and a.asset_id=p_id
 union all select to_jsonb(v),v.created_at from public.vehicle_lifecycle v where p_kind='vehicle' and v.tenant_id=t and v.vehicle_id=p_id),page as(select * from matching order by created_at desc offset p_offset limit 20)
 select jsonb_build_object('total',(select count(*) from matching),'entries',coalesce((select jsonb_agg(entry) from page),'[]')) into r;return r;end $$;
-- Interest is always a paid cost. No accrued/unpaid interest is inferred.
insert into public.spending_categories(tenant_id,name,classification) select tenant_id,'Interest','cost' from public.tenants on conflict do nothing;
alter table public.spending_categories add constraint interest_is_expense check(lower(trim(name))<>'interest' or classification='cost');
do $$declare n text;begin foreach n in array array['loans','loan_activity','supplier_commissions','commission_applications','vehicle_lifecycle'] loop
 execute format('alter table public.%I enable row level security',n);execute format('revoke all on public.%I from public,anon,authenticated',n);
 if n in ('loan_activity','commission_applications','vehicle_lifecycle') then execute format('create trigger accounting_immutable before update or delete on public.%I for each row execute function app_private.immutable_finance_record()',n);end if;
end loop;end $$;
revoke all on function public.accounting_operation(jsonb,uuid),public.get_accounting_register(text,integer),public.get_accounting_history(text,uuid,integer),public.set_vehicle_availability(uuid,boolean,text,uuid) from public,anon;
grant execute on function public.accounting_operation(jsonb,uuid),public.get_accounting_register(text,integer),public.get_accounting_history(text,uuid,integer),public.set_vehicle_availability(uuid,boolean,text,uuid) to authenticated;
