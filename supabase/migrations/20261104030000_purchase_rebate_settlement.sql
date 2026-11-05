-- Confirmed company rebates are noncash settlement and separate income under
-- the explicitly selected management-accounting policy. No inventory discount.
alter table public.purchases add column rebate_amount numeric(14,2) not null default 0
 check(rebate_amount>=0 and rebate_amount<'Infinity'::numeric);

insert into public.financial_types(type_id,code,name,origin,allocations)
values(md5('lpg:type:purchase_rebate')::uuid,'purchase_rebate','Company rebate','system','{"lpg":100}');

create table app_private.purchase_rebate_accounts(
 account_id uuid primary key default gen_random_uuid(),
 tenant_id uuid not null references public.tenants(tenant_id) on delete cascade,
 company_key text not null,company_name text not null,
 business_category text not null check(business_category in ('lpg','stove')),
 unique(tenant_id,company_key),unique(tenant_id,account_id)
);
create table app_private.purchase_rebate_events(
 event_id uuid primary key default gen_random_uuid(),
 tenant_id uuid not null references public.tenants(tenant_id) on delete cascade,
 account_id uuid not null,purchase_id uuid not null,
 applied_delta numeric(14,2) not null,income_delta numeric(14,2) not null,
 occurred_on date not null,created_at timestamptz not null default clock_timestamp(),
 created_by uuid references auth.users(id),
 foreign key(tenant_id,account_id) references app_private.purchase_rebate_accounts(tenant_id,account_id),
 foreign key(tenant_id,purchase_id) references public.purchases(tenant_id,purchase_id) on delete cascade,
 check(applied_delta<>0 or income_delta<>0),
 check(abs(applied_delta)<'Infinity'::numeric and abs(income_delta)<'Infinity'::numeric)
);
create index purchase_rebate_purchase on app_private.purchase_rebate_events(tenant_id,purchase_id);
create index purchase_rebate_company on app_private.purchase_rebate_events(tenant_id,account_id);
alter table app_private.purchase_rebate_accounts enable row level security;
alter table app_private.purchase_rebate_events enable row level security;
revoke all on app_private.purchase_rebate_accounts,app_private.purchase_rebate_events from public,anon,authenticated;
create trigger immutable_purchase_rebate before update or delete on app_private.purchase_rebate_events
 for each row execute function app_private.immutable_finance_record();

create function app_private.rebate_money(value jsonb) returns numeric
language plpgsql immutable set search_path='' as $$
declare a numeric;
begin
 if value is null then return 0;end if;
 if jsonb_typeof(value)<>'number' then raise exception 'Commission rebate must be a number';end if;
 a:=value::text::numeric;
 if a<0 or a>9999999999.99 or round(a,2)<>a then raise exception 'Enter a nonnegative commission rebate with at most two decimals';end if;
 return a;
end $$;

create function app_private.rebate_company_key(p public.purchases) returns text
language sql immutable set search_path='' as $$
 select case when p.business_category='lpg' then 'lpg:'||p.brand_id::text
 else 'stove:'||lower(regexp_replace(trim(p.supplier_name),'\s+',' ','g')) end;
$$;

create function app_private.guard_purchase_rebate() returns trigger
language plpgsql set search_path='' as $$
begin
 if new.rebate_amount>new.subtotal then raise exception 'Commission rebate cannot exceed the company product invoice';end if;
 if new.status<>'cancelled' and new.paid_amount+new.rebate_amount>(new.subtotal+new.labour_cost) then raise exception 'Commission rebate and wallet payments exceed the purchase balance';end if;
 if new.status in ('in_transit','received') or new.status='created' and new.paid_amount>0 then
  new.payment_status:=case when new.paid_amount+new.rebate_amount>=(new.subtotal+new.labour_cost) then 'paid' when new.paid_amount+new.rebate_amount>0 then 'partial' else 'unpaid' end;
  new.paid_at:=case when new.payment_status='paid' then coalesce(new.paid_at,clock_timestamp()) else null end;
 end if;
 return new;
end $$;
create trigger guard_purchase_rebate before insert or update of rebate_amount,status,paid_amount on public.purchases
 for each row execute function app_private.guard_purchase_rebate();

create function app_private.post_purchase_rebate() returns trigger
language plpgsql set search_path='' as $$
declare prior numeric;target numeric;delta numeric;income numeric;available numeric;earned numeric;
 a app_private.purchase_rebate_accounts;eid uuid;d date;label text;entries jsonb;
begin
 target:=case when new.status in ('in_transit','received') then new.rebate_amount else 0 end;
 if target=0 and not exists(select 1 from app_private.purchase_rebate_events where tenant_id=new.tenant_id and purchase_id=new.purchase_id) then return new;end if;
 -- Match the existing journal/snapshot lock order before serializing company credit.
 insert into app_private.accounting_snapshot_state(tenant_id,invalid_from)
 values(new.tenant_id,(clock_timestamp() at time zone 'Asia/Dhaka')::date) on conflict do nothing;
 perform 1 from app_private.accounting_snapshot_state where tenant_id=new.tenant_id for update;
 select coalesce(b.brand_name,new.supplier_name,'Supplier') into label from public.purchases p
 left join public.lpg_brands b on b.tenant_id=p.tenant_id and b.brand_id=p.brand_id
 where p.tenant_id=new.tenant_id and p.purchase_id=new.purchase_id;
 insert into app_private.purchase_rebate_accounts(tenant_id,company_key,company_name,business_category)
 values(new.tenant_id,app_private.rebate_company_key(new),label,new.business_category) on conflict do nothing;
 select * into strict a from app_private.purchase_rebate_accounts where tenant_id=new.tenant_id and company_key=app_private.rebate_company_key(new) for update;
 select coalesce(sum(applied_delta),0),coalesce(sum(income_delta),0) into prior,earned
 from app_private.purchase_rebate_events where tenant_id=new.tenant_id and purchase_id=new.purchase_id;
 delta:=target-prior;if delta=0 then return new;end if;
 select coalesce(sum(income_delta-applied_delta),0) into available from app_private.purchase_rebate_events where tenant_id=new.tenant_id and account_id=a.account_id;
 if available<0 then raise exception 'Company rebate credit is inconsistent';end if;
 if delta>0 then income:=greatest(0,delta-available);
 elsif new.status='cancelled' then income:=0;
 else income:=-least(-delta,earned);end if;
 d:=case when prior=0 and tg_op='UPDATE' and old.status='created' and new.status in ('in_transit','received')
 then (coalesce(new.dispatched_at,new.received_at,clock_timestamp()) at time zone 'Asia/Dhaka')::date
 else (clock_timestamp() at time zone 'Asia/Dhaka')::date end;
 insert into app_private.purchase_rebate_events(tenant_id,account_id,purchase_id,applied_delta,income_delta,occurred_on,created_by)
 values(new.tenant_id,a.account_id,new.purchase_id,delta,income,d,auth.uid()) returning event_id into eid;
 entries:=jsonb_build_array(
  app_private.accounting_line('supplier_payable',delta,new.business_category,new.purchase_id),
  app_private.accounting_line('supplier_receivable',income-delta,new.business_category,a.account_id),
  app_private.accounting_line('other_income',-income,new.business_category,new.purchase_id));
 perform app_private.post_journal(new.tenant_id,'purchase_rebate',new.purchase_id,eid::text,d,'Company rebate · '||label,entries);
 insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details)
 values(new.tenant_id,new.purchase_id,'rebate_settled',auth.uid(),jsonb_build_object('previous_rebate',prior,'rebate_amount',target,
 'rebate_delta',delta,'rebate_income',income,'company_credit_change',income-delta,'company',label,'event_id',eid));
 return new;
end $$;
create trigger zz_purchase_rebate after update of rebate_amount,status on public.purchases
 for each row execute function app_private.post_purchase_rebate();

create function public.set_purchase_rebate(p_purchase_id uuid,p_payload jsonb,p_request_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_owner('purchases:edit');p public.purchases;prior public.finance_requests;body jsonb;result jsonb;a numeric;
begin
 perform app_private.require_permission('purchases:manage');perform app_private.require_permission('purchases:pay');
 if p_request_id is null then raise exception 'Rebate request ID is required';end if;
 if jsonb_typeof(p_payload) is distinct from 'object' or p_payload-array['amount','revision','notes']<>'{}'::jsonb or not(p_payload ? 'amount') then raise exception 'Enter a rebate amount and purchase revision';end if;
 a:=app_private.rebate_money(p_payload->'amount');
 body:=jsonb_build_object('action','purchase_rebate','purchase',p_purchase_id,'body',p_payload,'actor',auth.uid());
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from body then raise exception 'Request ID already used with different details';end if;return prior.result;end if;
 select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id for update;
 if not found then raise exception 'Purchase not found';end if;
 if p.status='cancelled' then raise exception 'Cancelled purchase rebates are locked; released credit belongs to the company';end if;
 if (p_payload->>'revision')::integer is distinct from p.revision then raise exception 'Purchase changed. Reload before saving the rebate';end if;
 if p.status='received' and p.payment_status='paid' and p_payload ? 'notes' and coalesce(p_payload->>'notes','') is distinct from coalesce(p.notes,'') then raise exception 'Completed purchase notes are locked';end if;
 if length(coalesce(p_payload->>'notes',''))>4000 then raise exception 'Purchase notes are too long';end if;
 update public.purchases set rebate_amount=a,notes=case when p.status='received' and p.payment_status='paid' then p.notes when p_payload ? 'notes' then p_payload->>'notes' else notes end,
 revision=revision+1,updated_at=clock_timestamp() where tenant_id=t and purchase_id=p_purchase_id;
 result:=jsonb_build_object('purchase_id',p_purchase_id,'rebate_amount',a,'due',p.payable_amount-a-p.paid_amount);
 insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,result,auth.uid());
 return result;
end $$;

CREATE OR REPLACE FUNCTION public.create_purchase(p_payload jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid := app_private.require_permission('purchases:manage'); id uuid; b uuid; request uuid; plant uuid; original jsonb;
begin perform app_private.require_permission('purchases:create');
  if p_payload - array['request_id','business_category','supplier_name','plant_id','vehicle_id','transport_cost','labour_cost','notes','items','rebate_amount'] <> '{}'::jsonb then raise exception 'Unsupported purchase fields';end if;
  if app_private.rebate_money(p_payload->'rebate_amount')>0 then perform app_private.require_owner('purchases:create');end if;
  request := (p_payload->>'request_id')::uuid;
  if request is null then raise exception 'Creation request ID is required'; end if;
  -- Transaction lock makes repeated creation requests return the same result.
  perform pg_advisory_xact_lock(hashtextextended(t::text || request::text,0));
  select purchase_id into id from public.purchases where tenant_id=t and request_id=request;
  if found then
    select request_payload into original from public.purchases where tenant_id=t and purchase_id=id;
    if original is not null and original is distinct from (p_payload-'request_id') then
      raise exception 'Purchase request ID was already used with different purchase details';
    end if;
    return jsonb_build_object('purchase_id',id);
  end if;
  if coalesce(p_payload->>'business_category','lpg') not in ('lpg','stove') then raise exception 'Invalid business category';end if;
  if p_payload->>'business_category'='stove' then
    insert into public.purchases(tenant_id,business_category,supplier_name,vehicle_id,status,transport_cost,labour_cost,notes,created_by,request_id,request_payload)
    values(t,'stove',trim(p_payload->>'supplier_name'),(p_payload->>'vehicle_id')::uuid,'created',app_private.purchase_money(coalesce((p_payload->>'transport_cost')::numeric,0)),app_private.purchase_money(coalesce((p_payload->>'labour_cost')::numeric,0)),p_payload->>'notes',auth.uid(),request,p_payload-'request_id') returning purchase_id into id;
    perform app_private.save_purchase_lines(t,id,p_payload->'items');perform app_private.recalculate_purchase(t,id);
    update public.purchases set rebate_amount=app_private.rebate_money(p_payload->'rebate_amount') where tenant_id=t and purchase_id=id;
    insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details) values(t,id,'created',auth.uid(),jsonb_build_object('business_category','stove','supplier_name',p_payload->>'supplier_name'));
    return jsonb_build_object('purchase_id',id);
  end if;
  plant := (p_payload->>'plant_id')::uuid;
  select gp.brand_id into b from public.gas_plants gp join public.lpg_brands lb
    on lb.tenant_id=gp.tenant_id and lb.brand_id=gp.brand_id
    where gp.tenant_id=t and gp.plant_id=plant and gp.is_active and lb.is_active for share of gp,lb;
  if b is null then raise exception 'Select an active plant with an active company'; end if;
  if p_payload->>'vehicle_id' is not null and not exists(select 1 from public.vehicles where tenant_id=t and vehicle_id=(p_payload->>'vehicle_id')::uuid) then
    raise exception 'Vehicle not found'; end if;
  insert into public.purchases(tenant_id,plant_id,brand_id,vehicle_id,status,transport_cost,labour_cost,notes,created_by,request_id,request_payload)
  values(t,plant,b,(p_payload->>'vehicle_id')::uuid,'created',
    app_private.purchase_money(coalesce((p_payload->>'transport_cost')::numeric,0)),
    app_private.purchase_money(coalesce((p_payload->>'labour_cost')::numeric,0)),
    p_payload->>'notes',auth.uid(),request,p_payload-'request_id')
  returning purchase_id into id;
  perform app_private.save_purchase_lines(t,id,coalesce(p_payload->'items','[]'::jsonb));
  perform app_private.recalculate_purchase(t,id);
    update public.purchases set rebate_amount=app_private.rebate_money(p_payload->'rebate_amount') where tenant_id=t and purchase_id=id;
  insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details)
    values(t,id,'created',auth.uid(),jsonb_build_object('plant_id',plant,'company_id',b));
  return jsonb_build_object('purchase_id',id);
end $function$;

CREATE OR REPLACE FUNCTION public.update_purchase(p_purchase_id uuid, p_payload jsonb, p_revision integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid := app_private.require_permission('purchases:manage'); p public.purchases; truck uuid; before_items jsonb;
begin perform app_private.require_permission('purchases:edit');
  if p_payload - array['vehicle_id','transport_cost','labour_cost','notes','items','rebate_amount'] <> '{}'::jsonb then raise exception 'Unsupported purchase fields';end if;
  select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id for update;
  if not found then raise exception 'Purchase not found'; end if;
  if p_payload ? 'rebate_amount' and app_private.rebate_money(p_payload->'rebate_amount')<>p.rebate_amount then perform app_private.require_owner('purchases:edit');end if;
  if p_revision is distinct from p.revision then raise exception 'Purchase changed. Reload it before saving.' using errcode='P0001'; end if;
  if p.status='received' and p_payload ?| array['items','transport_cost','labour_cost'] then raise exception 'Received purchase costs and quantities are immutable';end if;
  if p.status='cancelled' or (p.status='received' and p.payment_status='paid') then raise exception 'Purchase is completed and locked'; end if;
  if p_payload ? 'plant_id' and (p_payload->>'plant_id')::uuid is distinct from p.plant_id
    or p_payload ? 'brand_id' and (p_payload->>'brand_id')::uuid is distinct from p.brand_id then
    raise exception 'Plant and company cannot change'; end if;
  if p.status<>'created' and p_payload ? 'transport_cost' and (p_payload->>'transport_cost')::numeric is distinct from p.transport_cost then raise exception 'Transport fee is fixed at dispatch';end if;
  select jsonb_agg(to_jsonb(pi)) into before_items from public.purchase_items pi where tenant_id=t and purchase_id=p_purchase_id;
  truck := case when p_payload ? 'vehicle_id' then (p_payload->>'vehicle_id')::uuid else p.vehicle_id end;
  if p.status<>'created' and truck is distinct from p.vehicle_id then raise exception 'Vehicle is locked after dispatch'; end if;
  if truck is not null and not exists(select 1 from public.vehicles where tenant_id=t and vehicle_id=truck) then raise exception 'Vehicle not found'; end if;
  if p.paid_amount>0 or p.payment_status='paid' or exists(select 1 from public.wallet_transactions where tenant_id=t and reference_id=p_purchase_id and amount<0 and type in ('purchase_expense','purchase_company_payment','purchase_logistics_payment','purchase_payment_company','purchase_payment_labour','purchase_payment_transport','purchase_payment')) then
    if p_payload ? 'items' or p_payload ? 'transport_cost' or p_payload ? 'labour_cost' then
      raise exception 'Financial values lock after the first payment'; end if;
  else
    update public.purchases set vehicle_id=truck where tenant_id=t and purchase_id=p_purchase_id;
    if p_payload ?| array['items','transport_cost','labour_cost'] then
    if p.status<>'created' then
      perform 1 from public.vehicles where tenant_id=t and vehicle_id=p.vehicle_id for update;
      perform 1 from public.transits where tenant_id=t and purchase_id=p_purchase_id order by transit_id for update;
    end if;
    if p_payload ? 'items' then perform app_private.save_purchase_lines(t,p_purchase_id,p_payload->'items'); end if;
    update public.purchases set vehicle_id=truck,
      transport_cost=app_private.purchase_money(coalesce((p_payload->>'transport_cost')::numeric,transport_cost,0)),
      labour_cost=app_private.purchase_money(coalesce((p_payload->>'labour_cost')::numeric,labour_cost,0))
      where tenant_id=t and purchase_id=p_purchase_id;
    perform app_private.recalculate_purchase(t,p_purchase_id);
    if exists(select 1 from public.transits where tenant_id=t and purchase_id=p_purchase_id and closed_at is not null)
      and (select transport_cost from public.purchases where tenant_id=t and purchase_id=p_purchase_id) is distinct from p.transport_cost then
      raise exception 'Transport fee is locked because the transit is closed'; end if;
    update public.transits set transport_fee=(select transport_cost from public.purchases where tenant_id=t and purchase_id=p_purchase_id)
      where tenant_id=t and purchase_id=p_purchase_id;

    end if;
  end if;
 update public.purchases set rebate_amount=case when p_payload ? 'rebate_amount' then app_private.rebate_money(p_payload->'rebate_amount') else rebate_amount end,payment_status=case when status='created' then payment_status when paid_amount>=payable_amount then 'paid' when paid_amount>0 then 'partial' else 'unpaid' end,
    paid_at=case when status<>'created' and paid_amount>=payable_amount then coalesce(paid_at,now()) else paid_at end,notes=case when p_payload ? 'notes' then p_payload->>'notes' else notes end,
    updated_at=now(),revision=revision+1 where tenant_id=t and purchase_id=p_purchase_id;
  insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details)
    values(t,p_purchase_id,'updated',auth.uid(),jsonb_build_object('before',to_jsonb(p),'before_items',before_items,
      'after',(select to_jsonb(h) from public.purchases h where h.tenant_id=t and h.purchase_id=p_purchase_id),
      'items',(select jsonb_agg(to_jsonb(pi)) from public.purchase_items pi where pi.tenant_id=t and pi.purchase_id=p_purchase_id)));
  return jsonb_build_object('purchase_id',p_purchase_id);
end $function$;

CREATE OR REPLACE FUNCTION public.record_purchase_payment(p_purchase_id uuid, p_payments jsonb, p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_permission('purchases:manage'); p public.purchases; payload jsonb; prior public.finance_requests; result jsonb;
 x jsonb; w public.wallets; a numeric; part numeric; remaining numeric; company_left numeric; labour_left numeric; component text; id uuid; paid numeric:=0; detail jsonb:='[]';
begin perform app_private.require_permission('purchases:pay');
 if p_request_id is null then raise exception 'Payment request ID is required'; end if;
 payload:=jsonb_build_object('action','purchase_payment','purchase',p_purchase_id,'payments',p_payments,'actor',auth.uid());
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from payload then raise exception 'Request ID already used with different details'; end if; return prior.result; end if;
 select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id for update;
 if not found then raise exception 'Purchase not found'; end if;
 if p.status not in ('in_transit','received') and not (p.business_category='stove' and p.status='created') then raise exception 'Payments require a dispatched, non-cancelled purchase'; end if;
 if p.payment_status='paid' or p.payable_amount-p.rebate_amount<=p.paid_amount then raise exception 'Purchase is already fully paid'; end if;
 if p_payments is null or jsonb_typeof(p_payments)<>'array' or jsonb_array_length(p_payments) not between 1 and 20 then raise exception 'Add between 1 and 20 payment entries'; end if;
 perform 1 from public.wallets where tenant_id=t and wallet_id in(select (value->>'wallet_id')::uuid from jsonb_array_elements(p_payments)) order by wallet_id for update;
 for x in select value from jsonb_array_elements(p_payments) loop
  if jsonb_typeof(x)<>'object' or jsonb_typeof(x->'amount') is distinct from 'number' then raise exception 'Payment amounts must be numbers'; end if;
  a:=app_private.purchase_money((x->>'amount')::numeric);
  if a<=0 or a<>(x->>'amount')::numeric then raise exception 'Enter a positive amount with at most two decimals'; end if;
  select * into w from public.wallets where tenant_id=t and wallet_id=(x->>'wallet_id')::uuid and is_active ;
  if not found then raise exception 'Select an active payment wallet belonging to this business'; end if;
  if length(coalesce(x->>'reference',''))>200 then raise exception 'Payment reference is too long'; end if;
  paid:=paid+a; if p.paid_amount+paid>p.payable_amount-p.rebate_amount then raise exception 'Payments exceed the remaining purchase balance'; end if;
  insert into public.purchase_payments(tenant_id,purchase_id,wallet_id,wallet_name,method,amount,kind,component,operation_id,reference,created_by)
   values(t,p_purchase_id,w.wallet_id,w.name,w.kind,a,'payment','purchase',p_request_id,coalesce(x->>'reference',''),auth.uid()) returning payment_id into id;
  insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description,operation_id,purchase_payment_id)
   values(t,w.wallet_id,-a,'purchase_payment',p_purchase_id,'Purchase payment · '||w.name||' · '||coalesce(x->>'reference',''),p_request_id,id);
  detail:=detail||jsonb_build_array(jsonb_build_object('payment_id',id,'wallet_id',w.wallet_id,'wallet_name',w.name,'method',w.kind,'amount',a,'component','purchase'));
 end loop;
 update public.purchases set paid_amount=paid_amount+paid,payment_status=case when paid_amount+paid>=payable_amount then 'paid' else 'partial' end,
 paid_at=case when paid_amount+paid>=payable_amount then now() else null end,revision=revision+1,updated_at=now() where tenant_id=t and purchase_id=p_purchase_id;
 result:=jsonb_build_object('purchase_id',p_purchase_id,'paid',paid,'paid_amount',p.paid_amount+paid,'due',p.payable_amount-p.rebate_amount-p.paid_amount-paid);
 insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details) values(t,p_purchase_id,'payment_recorded',auth.uid(),result||jsonb_build_object('payments',detail,'operation_id',p_request_id));
 insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,payload,result,auth.uid());
 return result;
end $function$;

CREATE OR REPLACE FUNCTION public.get_purchase_settlement(p_purchase_id uuid, p_offset integer DEFAULT 0, p_limit integer DEFAULT 10)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_any_permission(array['purchases:view','purchases:manage']); p public.purchases; result jsonb;
begin
 if p_offset is null or p_limit is null or p_offset<0 or p_limit not between 1 and 100 then raise exception 'Invalid payment page'; end if;
 select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id;
 if not found then raise exception 'Purchase not found'; end if;
 select jsonb_build_object('total',p.payable_amount,'rebate_amount',p.rebate_amount,'rebate_applied',case when p.status in ('in_transit','received') then p.rebate_amount else 0 end,'company_credit',coalesce((select sum(e.income_delta-e.applied_delta) from app_private.purchase_rebate_events e join app_private.purchase_rebate_accounts a using(tenant_id,account_id) where e.tenant_id=t and a.company_key=app_private.rebate_company_key(p)),0),'can_rebate',app_private.is_owner() and app_private.has_permission('purchases:pay'),'allocated_transport',p.transport_cost,'paid',p.paid_amount,'due',case when p.status='cancelled' then 0 else greatest(0,p.payable_amount-p.rebate_amount-p.paid_amount) end,
 'refund_due',p.refund_due,'refunded',p.refunded_amount,'financial_closed_at',p.financial_closed_at,'can_cancel',public.can_cancel_purchases(),
 'financial_locked',p.paid_amount>0 or p.status='received' or p.payment_status='paid' or exists(select 1 from public.wallet_transactions where tenant_id=t and reference_id=p_purchase_id and amount<0 and type in ('purchase_expense','purchase_company_payment','purchase_logistics_payment','purchase_payment_company','purchase_payment_labour','purchase_payment_transport','purchase_payment')),
 'obligations',coalesce((select jsonb_agg(to_jsonb(o)||jsonb_build_object('refunded',coalesce(q.amount,0),'remaining',o.amount-coalesce(q.amount,0)) order by o.component)
 from public.purchase_refund_obligations o left join lateral(select sum(amount) amount from public.purchase_payments where tenant_id=t and obligation_id=o.obligation_id) q on true where o.tenant_id=t and o.purchase_id=p_purchase_id),'[]'),
 'payment_count',(select count(*) from public.wallet_transactions where tenant_id=t and reference_id=p_purchase_id),
 'payments',coalesce((select jsonb_agg(to_jsonb(e) order by e.entry_no) from (select x.transaction_id,x.purchase_payment_id,x.wallet_name_snapshot wallet_name,x.wallet_method_snapshot method,x.amount,x.type,x.created_at,x.entry_no,x.operation_id,x.description,x.counterparty_wallet_id,pp.reference,pp.component,pp.obligation_id,up.full_name actor
  from public.wallet_transactions x left join public.purchase_payments pp on pp.tenant_id=t and pp.payment_id=x.purchase_payment_id
  left join app_private.tenant_actors up on up.tenant_id=t and up.user_id=x.created_by
  where x.tenant_id=t and x.reference_id=p_purchase_id order by x.entry_no limit p_limit offset p_offset) e),'[]')) into result;
 return result;
end $function$;

CREATE OR REPLACE FUNCTION public.get_purchase_overview(p_category text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_any_permission(array['purchases:view','purchases:manage']); result jsonb;
begin
 select jsonb_build_object('total',count(*),'created',count(*) filter(where status='created'),'in_transit',count(*) filter(where status='in_transit'),
 'unpaid',count(*) filter(where payment_status<>'paid' and status not in ('created','cancelled')),
 'company_payable',coalesce(sum(company_payable) filter(where payment_status<>'paid' and status not in ('created','cancelled')),0),
 'outstanding',coalesce(sum(greatest(0,payable_amount-rebate_amount-paid_amount)) filter(where status not in ('created','cancelled')),0),
 'refund_due',coalesce(sum(refund_due),0),'pending_refunds',count(*) filter(where status='cancelled' and financial_closed_at is null)) into result from public.purchases where tenant_id=t and (p_category is null or business_category=p_category);
 return result;
end $function$;

CREATE OR REPLACE FUNCTION public.get_purchase_directory(p_filters jsonb DEFAULT '{}'::jsonb, p_offset integer DEFAULT 0, p_limit integer DEFAULT 6)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_any_permission(array['purchases:view','purchases:manage']); result jsonb;
  ordering text:=coalesce(p_filters->>'sort','date_desc'); searching boolean:=false;
begin
  if p_filters is null or jsonb_typeof(p_filters)<>'object' or length(coalesce(p_filters->>'search',''))>500
    or coalesce(p_filters->>'status','all') not in ('all','created','in_transit','received','cancelled','pending_refund','closed')
    or coalesce(p_filters->>'payment','all') not in ('all','unpaid','partial','paid')
    or coalesce(p_filters->>'business_category','all') not in ('all','lpg','stove')
    or ordering not in ('date_desc','date_asc','amount_desc','amount_asc','due_asc','due_desc','supplier_asc','supplier_desc') then raise exception 'Invalid purchase filters'; end if;
  if p_offset is null or p_limit is null or p_offset<0 or p_offset>1000000 or p_limit not between 1 and 100 then raise exception 'Invalid purchase page'; end if;
  searching:=exists(select 1 from regexp_split_to_table(coalesce(p_filters->>'search',''),'\s*,\s*') g where btrim(g)<>'');
  with matching as materialized (
    select p.purchase_id,p.created_at,p.total_cost,case when p.status='cancelled' then 0 else greatest(0,p.payable_amount-p.rebate_amount-p.paid_amount) end due,lower(coalesce(b.brand_name,p.supplier_name,'')) supplier from public.purchases p
    left join public.vehicles tr on tr.tenant_id=t and tr.vehicle_id=p.vehicle_id
    left join public.gas_plants gp on gp.tenant_id=t and gp.plant_id=p.plant_id
    left join public.lpg_brands b on b.tenant_id=t and b.brand_id=p.brand_id
    where p.tenant_id=t and (coalesce(p_filters->>'business_category','all')='all' or p.business_category=p_filters->>'business_category')
      and (coalesce(p_filters->>'status','all')='all' or p.status::text=p_filters->>'status' or p_filters->>'status'='pending_refund' and p.status='cancelled' and p.financial_closed_at is null or p_filters->>'status'='closed' and p.status='cancelled' and p.financial_closed_at is not null)
      and (coalesce(p_filters->>'payment','all')='all' or p.payment_status=p_filters->>'payment')
      and (nullif(p_filters->>'from','') is null or p.created_at >= (nullif(p_filters->>'from','')::date::timestamp at time zone 'Asia/Dhaka'))
      and (nullif(p_filters->>'to','') is null or p.created_at < ((nullif(p_filters->>'to','')::date+1)::timestamp at time zone 'Asia/Dhaka'))
      and (not searching or exists(
        select 1 from (select lower(concat_ws(' ',p.purchase_id,p.supplier_name,b.brand_name,gp.plant_name,tr.name,p.notes,p.receipt_notes,p.status,p.payment_status,
          (select string_agg(concat_ws(' ',i.product_name,lb.brand_name,trim_scale(i.size_kg)||'kg',trim_scale(i.size_kg)||' kg',i.mouth_size,
            case when pi.bottle_quantity>0 then 'gas bottle' else 'gas' end),' ')
          from public.purchase_items pi join public.items i on i.tenant_id=pi.tenant_id and i.item_id=pi.item_id
          left join public.lpg_brands lb on lb.tenant_id=i.tenant_id and lb.brand_id=i.brand_id where pi.tenant_id=t and pi.purchase_id=p.purchase_id))) text) document
        where exists(select 1 from regexp_split_to_table(lower(p_filters->>'search'),'\s*,\s*') g where btrim(g)<>'' and not exists(
          select 1 from regexp_split_to_table(btrim(g),'\s+') token where token<>'' and position(token in document.text)=0))))
  ), page as materialized (
    select * from matching order by
      case when ordering='date_desc' then created_at end desc,case when ordering='date_asc' then created_at end asc,
      case when ordering='amount_desc' then total_cost end desc,case when ordering='amount_asc' then total_cost end asc,
      case when ordering='due_asc' then due end asc,case when ordering='due_desc' then due end desc,
      case when ordering='supplier_asc' then supplier end asc,case when ordering='supplier_desc' then supplier end desc,purchase_id
    limit p_limit offset p_offset
  ), details as (
    select r.* from app_private.purchase_rows(t,coalesce((select array_agg(purchase_id) from page),'{}'::uuid[])) r
  ) select jsonb_build_object('total',(select count(*) from matching),'entries',coalesce((select jsonb_agg(d.r order by
    case when ordering='date_desc' then p.created_at end desc,case when ordering='date_asc' then p.created_at end asc,
    case when ordering='amount_desc' then p.total_cost end desc,case when ordering='amount_asc' then p.total_cost end asc,
    case when ordering='due_asc' then p.due end asc,case when ordering='due_desc' then p.due end desc,
    case when ordering='supplier_asc' then p.supplier end asc,case when ordering='supplier_desc' then p.supplier end desc,p.purchase_id)
    from details d(r) join page p on p.purchase_id=(d.r->>'purchase_id')::uuid),'[]'::jsonb)) into result;
  return result;
end $function$;

CREATE OR REPLACE FUNCTION app_private.analysis_entity(t uuid, code text, id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare label text;k text;ref uuid:=id;begin
 if id is null and code='cash' then label:='Pooled business cash';
 elsif id is null then select a.name into label from public.accounting_accounts a where a.code=analysis_entity.code;
 elsif code='cash' then select name,'wallet' into label,k from public.wallets where tenant_id=t and wallet_id=id;
 elsif code in ('inventory_lpg','inventory_stove') then
  select coalesce(i.product_name,concat_ws(' ',b.brand_name,i.size_kg||' kg',i.mouth_size)),'product' into label,k from public.items i left join public.lpg_brands b using(tenant_id,brand_id) where i.tenant_id=t and i.item_id=id;
 elsif code='customer_receivable' then select coalesce(nullif(shop_name,''),name),'customer' into label,k from public.customers where tenant_id=t and customer_id=id;
 elsif code='loan_payable' then select lender,'loan' into label,k from public.loans where tenant_id=t and loan_id=id;
 elsif code in ('vehicles','equipment','other_assets') then select name,'asset' into label,k from public.business_assets where tenant_id=t and asset_id=id;
 elsif code in ('supplier_payable','inventory_transit') then select coalesce(supplier_name,'Supplier')||' · Purchase #'||left(id::text,8),'purchase' into label,k from public.purchases where tenant_id=t and purchase_id=id;
 elsif code='other_income' and exists(select 1 from public.purchases where tenant_id=t and purchase_id=id) then select coalesce(supplier_name,'Company')||' · Purchase #'||left(id::text,8),'purchase' into label,k from public.purchases where tenant_id=t and purchase_id=id;
 elsif code='bottle_receivable' then select 'Cylinders · Sale #'||left(id::text,8),'sale' into label,k from public.sales where tenant_id=t and sale_id=id;
 elsif code='supplier_receivable' and exists(select 1 from app_private.purchase_rebate_accounts where tenant_id=t and account_id=id) then select company_name||' · Company rebate credit' into label from app_private.purchase_rebate_accounts where tenant_id=t and account_id=id;
 elsif code='supplier_receivable' then select brand_name||' · Supplier advance/refund' into label from public.lpg_brands where tenant_id=t and brand_id=id; 
 elsif code='employee_payable' then select name,'employee' into label,k from public.employees where tenant_id=t and employee_id=id;
 end if;
 if label is null then select description,'obligation' into label,k from public.finance_obligations where tenant_id=t and obligation_id=id;end if;
 if label is null then select 'Journey · '||destination||' #'||left(id::text,8),'transit' into label,k from public.transits where tenant_id=t and transit_id=id;end if;
 if label is null then select a.name into label from public.accounting_accounts a where a.code=analysis_entity.code;end if;
 return jsonb_build_object('entity_name',label,'record_kind',k,'record_id',ref);end $function$;

CREATE OR REPLACE FUNCTION public.get_financial_activity(p_filters jsonb DEFAULT '{}'::jsonb, p_offset integer DEFAULT 0, p_limit integer DEFAULT 12)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.require_any_permission(array['finance:view','finance:manage']);r jsonb;begin
 if p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100 or length(coalesce(p_filters->>'search',''))>500 or nullif(p_filters->>'from','')::date>nullif(p_filters->>'to','')::date then raise exception 'Invalid activity filters';end if;
 with parents as(
 select p.purchase_id id,'purchase' source,p.created_at,coalesce(p.supplier_name,b.brand_name,'Purchase')||' · '||coalesce(g.plant_name,'') title,
 p.status::text status,p.payable_amount cost,0::numeric revenue,p.paid_amount paid,p.transport_cost internal_allocation,
 jsonb_build_object('Company payable',p.company_payable,'Commission rebate applied',case when p.status in ('in_transit','received') then p.rebate_amount else 0 end,'Labour',p.labour_cost,'Transport allocation',p.transport_cost) breakdown
 from public.purchases p left join public.lpg_brands b on b.tenant_id=t and b.brand_id=p.brand_id left join public.gas_plants g on g.tenant_id=t and g.plant_id=p.plant_id where p.tenant_id=t and p.status<>'created'
 union all select s.service_trip_id,'service_trip',s.created_at,s.title,case when s.finalized_at is null then 'open' else 'finalized' end,s.total_cost,0,app_private.service_paid(t,s.service_trip_id),0,jsonb_build_object('Expenses',s.expenses)
 from public.vehicle_service_trips s where s.tenant_id=t
 union all select tr.transit_id,'transit',tr.created_at,coalesce(tr.client_name,'Transit')||' · '||coalesce(tr.destination,''),tr.status::text,tr.total_cost,0::numeric,
 app_private.transit_employee_paid(t,tr.transit_id,null)+app_private.transit_operating_paid(t,tr.transit_id),case when tr.purchase_id is null then 0 else tr.transport_fee end,
 jsonb_build_object('Driver earnings',tr.driver_cost,'Helper earnings',tr.helper_cost,'Oil',tr.oil_cost,'Other costs',tr.others_cost,'Additional costs',tr.additional_costs)
 from public.transits tr where tr.tenant_id=t
 ),matching as materialized(select * from parents p where app_private.finance_search(concat_ws(' ',p.title,p.id,p.source,p.status),coalesce(p_filters->>'search',''))
 and (nullif(p_filters->>'source','') is null or source=p_filters->>'source')
 and (nullif(p_filters->>'from','') is null or created_at>=(p_filters->>'from')::date::timestamp at time zone 'Asia/Dhaka')
 and (nullif(p_filters->>'to','') is null or created_at<((p_filters->>'to')::date+1)::timestamp at time zone 'Asia/Dhaka')),
 page as(select * from matching order by created_at desc,id desc offset p_offset limit p_limit)
 select jsonb_build_object('total',(select count(*) from matching),'entries',coalesce((select jsonb_agg(to_jsonb(p)||case when p.source='transit' then jsonb_build_object('revenue',(app_private.logistics_result(t,array[p.id])->>'revenue')::numeric) else '{}'::jsonb end order by created_at desc,id desc) from page p),'[]')) into r;return r;
end $function$;


-- All purchase fields and existing source journals remain gross. Rebate sources
-- use their own immutable dated journal; normal wallet payments stay cash-only.
alter table app_private.purchase_rebate_accounts owner to postgres;
alter table app_private.purchase_rebate_events owner to postgres;
alter function app_private.rebate_money(jsonb) owner to postgres;
alter function app_private.rebate_company_key(public.purchases) owner to postgres;
alter function app_private.guard_purchase_rebate() owner to postgres;
alter function app_private.post_purchase_rebate() owner to postgres;
alter function public.set_purchase_rebate(uuid,jsonb,uuid) owner to postgres;
revoke all on function app_private.rebate_money(jsonb),app_private.rebate_company_key(public.purchases),
 app_private.guard_purchase_rebate(),app_private.post_purchase_rebate() from public,anon,authenticated;
revoke all on function public.set_purchase_rebate(uuid,jsonb,uuid) from public,anon;
grant execute on function public.set_purchase_rebate(uuid,jsonb,uuid) to authenticated;
notify pgrst,'reload schema';
