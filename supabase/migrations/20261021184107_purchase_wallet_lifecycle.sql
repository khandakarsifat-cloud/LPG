-- Purchase settlement extends the existing Finance ledger and request registry.
-- No historical stock, ledger entry or wallet balance is changed.
alter table public.purchases drop constraint purchases_payment_status_check;
alter table public.purchases add column paid_amount numeric(12,2) not null default 0,
 add column refund_due numeric(12,2) not null default 0,
 add column refunded_amount numeric(12,2) not null default 0,
 add column financial_closed_at timestamptz;
alter table public.purchases add constraint purchases_payment_status_check check(payment_status in ('unpaid','partial','paid'));
update public.purchases p set paid_amount=greatest(0,coalesce((select -sum(x.amount) from public.wallet_transactions x join public.wallets w using(tenant_id,wallet_id)
 where x.tenant_id=p.tenant_id and x.reference_id=p.purchase_id and w.type<>'logistics'
 and x.type in ('purchase_expense','purchase_company_payment','purchase_logistics_payment','purchase_transport_funding')),0)) where payment_status<>'paid';
update public.purchases set paid_amount=total_cost where payment_status='paid';
update public.purchases set financial_closed_at=coalesce(cancelled_at,updated_at) where status='cancelled';
-- Legacy statuses retain their meaning; the new summary exposes funding separately.
alter table public.purchases add constraint purchase_refund_totals_valid check(refund_due>=0 and refunded_amount>=0);

alter table public.wallet_transactions add column wallet_name_snapshot text, add column wallet_method_snapshot text;
alter table public.wallet_transactions disable trigger immutable_wallet_entry;
update public.wallet_transactions x set wallet_name_snapshot=w.name,wallet_method_snapshot=w.kind
 from public.wallets w where w.tenant_id=x.tenant_id and w.wallet_id=x.wallet_id;
alter table public.wallet_transactions enable trigger immutable_wallet_entry;
create or replace function app_private.post_wallet_entry() returns trigger language plpgsql set search_path='' as $$
begin
 if new.amount is null or new.amount in ('NaN'::numeric,'Infinity'::numeric,'-Infinity'::numeric) then raise exception 'Invalid wallet amount'; end if;
 select name,kind into new.wallet_name_snapshot,new.wallet_method_snapshot from public.wallets where tenant_id=new.tenant_id and wallet_id=new.wallet_id;
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
create table public.purchase_refund_obligations(
 tenant_id uuid not null, obligation_id uuid not null default gen_random_uuid(), purchase_id uuid not null,
 component text not null check(component in ('company','labour','transport','legacy','transport_income')),
 amount numeric(12,2) not null check(amount>0), logistics_amount numeric(12,2) not null default 0 check(logistics_amount>=0 and logistics_amount<=amount),
 credit_business boolean not null default true, sources jsonb not null,
 created_at timestamptz not null default clock_timestamp(), created_by uuid not null,
 primary key(tenant_id,obligation_id), unique(tenant_id,purchase_id,component),
 foreign key(tenant_id,purchase_id) references public.purchases(tenant_id,purchase_id),
 foreign key(tenant_id,created_by) references public.user_profiles(tenant_id,user_id)
);
create table public.purchase_payments(
 tenant_id uuid not null, payment_id uuid not null default gen_random_uuid(), purchase_id uuid not null,
 wallet_id uuid not null, wallet_name text not null, method text not null,
 amount numeric(12,2) not null check(amount>0 and amount not in ('NaN'::numeric,'Infinity'::numeric,'-Infinity'::numeric)),
 kind text not null check(kind in ('payment','refund')), component text not null,
 obligation_id uuid, operation_id uuid not null, reference text not null default '',
 created_at timestamptz not null default clock_timestamp(), created_by uuid not null,
 primary key(tenant_id,payment_id),
 foreign key(tenant_id,purchase_id) references public.purchases(tenant_id,purchase_id),
 foreign key(tenant_id,wallet_id) references public.wallets(tenant_id,wallet_id),
 foreign key(tenant_id,obligation_id) references public.purchase_refund_obligations(tenant_id,obligation_id),
 foreign key(tenant_id,created_by) references public.user_profiles(tenant_id,user_id),
 check((kind='refund')=(obligation_id is not null))
);
create index purchase_payments_history on public.purchase_payments(tenant_id,purchase_id,created_at,payment_id);
create index purchase_refund_allocation on public.purchase_payments(tenant_id,obligation_id) where obligation_id is not null;
alter table public.wallet_transactions add column purchase_payment_id uuid,
 add constraint wallet_purchase_payment_fk foreign key(tenant_id,purchase_payment_id) references public.purchase_payments(tenant_id,payment_id);
create unique index purchase_wallet_entry_once on public.wallet_transactions(tenant_id,purchase_payment_id,wallet_id) where purchase_payment_id is not null;
alter table public.purchase_payments enable row level security;
alter table public.purchase_refund_obligations enable row level security;
revoke all on public.purchase_payments,public.purchase_refund_obligations from public,anon,authenticated;
-- Read through bounded, permission-gated RPCs. No browser writes.
create trigger immutable_purchase_payment before update or delete on public.purchase_payments for each row execute function app_private.immutable_finance_record();
create trigger immutable_purchase_refund before update or delete on public.purchase_refund_obligations for each row execute function app_private.immutable_finance_record();

create function public.can_cancel_purchases() returns boolean language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['purchases:view','purchases:manage']);
begin return app_private.has_permission('purchases:manage') and exists(select 1 from public.user_roles ur join public.roles r using(tenant_id,role_id) where ur.tenant_id=t and ur.user_id=auth.uid() and r.name='OWNER'); end $$;
create or replace function public.get_payment_wallets() returns table(wallet_id uuid,name text,kind text,type text)
language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['pos:sell','finance:view','finance:manage','purchases:manage']);
begin return query select w.wallet_id,w.name,w.kind,w.type from public.wallets w where w.tenant_id=t and w.is_active and w.kind<>'logistics'
 order by case w.type when 'cash' then 0 when 'bkash' then 1 when 'nagad' then 2 when 'dealership' then 3 else 4 end,w.name,w.wallet_id; end $$;

create or replace function app_private.fund_purchase_transport(t uuid,pid uuid) returns void language plpgsql set search_path='' as $$
declare p public.purchases; delta numeric; bank_delta numeric; funded_debit numeric; dw uuid; lw uuid; op uuid:=gen_random_uuid();
begin
 select * into p from public.purchases where tenant_id=t and purchase_id=pid;
 delta:=coalesce(p.transport_cost,0)-p.transport_funded;
 if delta=0 then return; end if;
 perform 1 from public.wallets where tenant_id=t order by wallet_id for update;
 select wallet_id into dw from public.wallets where tenant_id=t and type='dealership';
 select wallet_id into lw from public.wallets where tenant_id=t and type='logistics';
 -- Older Logistics funding could lack its matching bank debit. Returning a fee
 -- must never credit more purchasing money than was actually funded.
 bank_delta:=delta;
 if delta<0 then
  select greatest(0,coalesce(-sum(amount),0)) into funded_debit from public.wallet_transactions
   where tenant_id=t and wallet_id=dw and reference_id=pid and type='purchase_transport_funding';
  bank_delta:=-least(-delta,funded_debit);
 end if;
 if bank_delta<>0 then
  insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description,operation_id,counterparty_wallet_id)
   values(t,dw,-bank_delta,'purchase_transport_funding',pid,'Purchase transport funding · Primary Bank / Logistics',op,lw);
 end if;
 insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description,operation_id,counterparty_wallet_id)
  values(t,lw,delta,'purchase_transport_funding',pid,'Purchase transport funding adjusted; uncharged historical funding does not credit purchasing wallets',op,case when bank_delta<>0 then dw end);
 update public.purchases set transport_funded=coalesce(transport_cost,0),paid_amount=paid_amount+bank_delta,
 payment_status=case when paid_amount+bank_delta>=total_cost then 'paid' when paid_amount+bank_delta>0 then 'partial' else 'unpaid' end,paid_at=case when paid_amount+bank_delta>=total_cost then now() end where tenant_id=t and purchase_id=pid;
 insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details) values(t,pid,'transport_funded',auth.uid(),jsonb_build_object('amount',delta,'purchasing_amount',bank_delta,'operation_id',op,'source',(select name from public.wallets where tenant_id=t and wallet_id=dw),'destination',(select name from public.wallets where tenant_id=t and wallet_id=lw)));
end $$;

-- Old cached full-settlement clients must refresh before writing financial data.
create or replace function public.pay_purchase(p_purchase_id uuid,p_revision integer) returns jsonb language plpgsql security definer set search_path='' as $$
begin perform app_private.require_permission('purchases:manage'); raise exception 'Purchase payments updated. Refresh the application and select payment wallets.'; end $$;
create or replace function public.cancel_purchase(p_purchase_id uuid,p_revision integer) returns jsonb language plpgsql security definer set search_path='' as $$
begin perform app_private.require_permission('purchases:manage'); raise exception 'Cancellation updated. Refresh the application and type CANCEL to confirm.'; end $$;

create function public.record_purchase_payment(p_purchase_id uuid,p_payments jsonb,p_request_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('purchases:manage'); p public.purchases; payload jsonb; prior public.finance_requests; result jsonb;
 x jsonb; w public.wallets; a numeric; part numeric; remaining numeric; company_left numeric; labour_left numeric; component text; id uuid; paid numeric:=0; detail jsonb:='[]';
begin
 if p_request_id is null then raise exception 'Payment request ID is required'; end if;
 payload:=jsonb_build_object('action','purchase_payment','purchase',p_purchase_id,'payments',p_payments,'actor',auth.uid());
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from payload then raise exception 'Request ID already used with different details'; end if; return prior.result; end if;
 select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id for update;
 if not found then raise exception 'Purchase not found'; end if;
 if p.status not in ('in_transit','received') then raise exception 'Payments require a dispatched, non-cancelled purchase'; end if;
 if p.payment_status='paid' or p.total_cost<=p.paid_amount then raise exception 'Purchase is already fully paid'; end if;
 if p_payments is null or jsonb_typeof(p_payments)<>'array' or jsonb_array_length(p_payments) not between 1 and 20 then raise exception 'Add between 1 and 20 payment entries'; end if;
 select greatest(0,p.company_payable-coalesce(-sum(amount),0)) into company_left from public.wallet_transactions where tenant_id=t and reference_id=p_purchase_id and type in ('purchase_company_payment','purchase_payment_company');
 select greatest(0,coalesce(p.labour_cost,0)-coalesce(-sum(amount),0)) into labour_left from public.wallet_transactions where tenant_id=t and reference_id=p_purchase_id and type in ('purchase_logistics_payment','purchase_payment_labour');
 perform 1 from public.wallets where tenant_id=t and wallet_id in(select (value->>'wallet_id')::uuid from jsonb_array_elements(p_payments)) order by wallet_id for update;
 for x in select value from jsonb_array_elements(p_payments) loop
  if jsonb_typeof(x)<>'object' or jsonb_typeof(x->'amount') is distinct from 'number' then raise exception 'Payment amounts must be numbers'; end if;
  a:=app_private.purchase_money((x->>'amount')::numeric);
  if a<=0 or a<>(x->>'amount')::numeric then raise exception 'Enter a positive amount with at most two decimals'; end if;
  select * into w from public.wallets where tenant_id=t and wallet_id=(x->>'wallet_id')::uuid and is_active and kind<>'logistics';
  if not found then raise exception 'Select an active payment wallet belonging to this business'; end if;
  if length(coalesce(x->>'reference',''))>200 then raise exception 'Payment reference is too long'; end if;
  paid:=paid+a; if p.paid_amount+paid>p.total_cost then raise exception 'Payments exceed the remaining purchase balance'; end if;
  remaining:=a;
  while remaining>0 loop
   if company_left>0 then component:='company';part:=least(remaining,company_left);company_left:=company_left-part;
   elsif labour_left>0 then component:='labour';part:=least(remaining,labour_left);labour_left:=labour_left-part;
   else component:='transport';part:=remaining; end if;
   insert into public.purchase_payments(tenant_id,purchase_id,wallet_id,wallet_name,method,amount,kind,component,operation_id,reference,created_by)
    values(t,p_purchase_id,w.wallet_id,w.name,w.kind,part,'payment',component,p_request_id,coalesce(x->>'reference',''),auth.uid()) returning payment_id into id;
   insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description,operation_id,purchase_payment_id)
    values(t,w.wallet_id,-part,'purchase_payment_'||component,p_purchase_id,'Purchase '||component||' · '||w.name||' · '||coalesce(x->>'reference',''),p_request_id,id);
   detail:=detail||jsonb_build_array(jsonb_build_object('payment_id',id,'wallet_id',w.wallet_id,'wallet_name',w.name,'method',w.kind,'amount',part,'component',component,'reference',coalesce(x->>'reference','')));
   remaining:=remaining-part;
  end loop;
 end loop;
 update public.purchases set paid_amount=paid_amount+paid,payment_status=case when paid_amount+paid>=total_cost then 'paid' else 'partial' end,
 paid_at=case when paid_amount+paid>=total_cost then now() else null end,revision=revision+1,updated_at=now() where tenant_id=t and purchase_id=p_purchase_id;
 result:=jsonb_build_object('purchase_id',p_purchase_id,'paid',paid,'paid_amount',p.paid_amount+paid,'due',p.total_cost-p.paid_amount-paid);
 insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details) values(t,p_purchase_id,'payment_recorded',auth.uid(),result||jsonb_build_object('payments',detail,'operation_id',p_request_id));
 insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,payload,result,auth.uid());
 return result;
end $$;
create function public.initiate_purchase_cancellation(p_purchase_id uuid,p_revision integer,p_confirmation text,p_request_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('purchases:manage'); p public.purchases; prior public.finance_requests; payload jsonb; result jsonb;
 r record; transport_paid numeric:=0; logistics_income numeric:=0; obligation_total numeric:=0; sources jsonb;
begin
 if not public.can_cancel_purchases() then raise exception 'Only the OWNER can cancel purchases' using errcode='42501'; end if;
 if p_confirmation is distinct from 'CANCEL' then raise exception 'Type exactly CANCEL to confirm cancellation'; end if;
 if p_request_id is null then raise exception 'Cancellation request ID is required'; end if;
 payload:=jsonb_build_object('action','purchase_cancel','purchase',p_purchase_id,'revision',p_revision,'confirmation',p_confirmation,'actor',auth.uid());
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from payload then raise exception 'Request ID already used with different details'; end if; return prior.result; end if;
 select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id for update;
 if not found then raise exception 'Purchase not found'; end if;
 if p.status='received' then raise exception 'Received purchases can never be cancelled'; end if;
 if p.status='cancelled' then raise exception 'Purchase is already cancelled'; end if;
 if p_revision is distinct from p.revision then raise exception 'Purchase changed. Reload before cancellation.' using errcode='40001'; end if;
 perform 1 from public.trucks where tenant_id=t and truck_id=p.truck_id for update;
 perform 1 from public.transits where tenant_id=t and purchase_id=p_purchase_id order by transit_id for update;
 insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details) values(t,p_purchase_id,'cancellation_confirmed',auth.uid(),jsonb_build_object('previous_status',p.status,'confirmation','CANCEL','operation_id',p_request_id,'before',to_jsonb(p)));
 -- Only dispatch is reversible: receiving is a permanent cancellation boundary.
 for r in select m.item_id,sum(m.empty_quantity_change) empties from public.inventory_movements m where m.tenant_id=t and
 (m.reference_id=p_purchase_id and m.reference_type='purchase_dispatch' or m.reference_id is null and m.notes='Empty bottles sent for refill (Purchase '||p_purchase_id||')') group by m.item_id order by m.item_id loop
  perform 1 from public.items where tenant_id=t and item_id=r.item_id for update;
  if r.empties<>0 then insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,empty_quantity_change,notes,created_by)
   values(t,r.item_id,'purchase_adjustment','purchase_cancellation',p_purchase_id,-r.empties,'Cancelled purchase: dispatched empties returned',auth.uid()); end if;
 end loop;
 select greatest(0,coalesce(sum(x.amount),0)) into logistics_income from public.wallet_transactions x join public.wallets w using(tenant_id,wallet_id)
  where x.tenant_id=t and x.reference_id=p_purchase_id and w.type='logistics' and x.type in ('transport_income','transport_income_adj','purchase_transport_settlement','purchase_transport_funding');
 -- Refund only evidence of actual purchasing-business debits. Historical settled
 -- headers with no ledger attribution never create fictional money to refund.
 for r in select component,greatest(0,-sum(amount)) amount,jsonb_agg(evidence order by created_at,transaction_id) sources from (
  select x.amount,x.created_at,x.transaction_id,case when x.type in ('purchase_company_payment','purchase_payment_company') then 'company'
   when x.type in ('purchase_logistics_payment','purchase_payment_labour') then 'labour'
   when x.type in ('purchase_transport_funding','purchase_payment_transport') then 'transport' else 'legacy' end component,
   jsonb_build_object('transaction_id',x.transaction_id,'payment_id',x.purchase_payment_id,'wallet_id',x.wallet_id,'wallet_name',x.wallet_name_snapshot,'method',x.wallet_method_snapshot,'amount',x.amount,'description',x.description,'created_at',x.created_at) evidence
  from public.wallet_transactions x join public.wallets w using(tenant_id,wallet_id) where x.tenant_id=t and x.reference_id=p_purchase_id and w.type<>'logistics'
   and x.type in ('purchase_expense','purchase_company_payment','purchase_logistics_payment','purchase_transport_funding','purchase_payment_company','purchase_payment_labour','purchase_payment_transport')
 ) q group by component loop
  if r.amount>0 then
   insert into public.purchase_refund_obligations(tenant_id,purchase_id,component,amount,logistics_amount,sources,created_by)
    values(t,p_purchase_id,r.component,r.amount,case when r.component='transport' then least(r.amount,logistics_income) else 0 end,r.sources,auth.uid());
   obligation_total:=obligation_total+r.amount;
   if r.component='transport' then transport_paid:=r.amount; end if;
  end if;
 end loop;
 if logistics_income>transport_paid then
  select coalesce(jsonb_agg(jsonb_build_object('transaction_id',x.transaction_id,'wallet_name',x.wallet_name_snapshot,'amount',x.amount,'description',x.description)),'[]') into sources
   from public.wallet_transactions x join public.wallets w using(tenant_id,wallet_id) where x.tenant_id=t and x.reference_id=p_purchase_id and w.type='logistics'
    and x.type in ('transport_income','transport_income_adj','purchase_transport_settlement','purchase_transport_funding');
  insert into public.purchase_refund_obligations(tenant_id,purchase_id,component,amount,logistics_amount,credit_business,sources,created_by)
   values(t,p_purchase_id,'transport_income',logistics_income-transport_paid,logistics_income-transport_paid,false,sources,auth.uid());
  obligation_total:=obligation_total+logistics_income-transport_paid;
 end if;
 update public.transits set status='cancelled',revision=revision+1,updated_at=now() where tenant_id=t and purchase_id=p_purchase_id;
 update public.purchases set status='cancelled',cancelled_at=now(),refund_due=obligation_total,financial_closed_at=case when obligation_total=0 then now() end,
  updated_at=now(),revision=revision+1 where tenant_id=t and purchase_id=p_purchase_id;
 if not exists(select 1 from public.transits where tenant_id=t and truck_id=p.truck_id and status='active')
  and not exists(select 1 from public.purchases where tenant_id=t and truck_id=p.truck_id and status='in_transit') then
  update public.trucks set status='idle',updated_at=now() where tenant_id=t and truck_id=p.truck_id;
 end if;
 result:=jsonb_build_object('purchase_id',p_purchase_id,'refund_due',obligation_total,'financially_closed',obligation_total=0);
 insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details) values(t,p_purchase_id,'cancellation_initiated',auth.uid(),result||jsonb_build_object('notes','Dispatched empties returned; truck released; transit cancelled. Incurred operating costs preserved. Refunds require separate settlement.'));
 if obligation_total=0 then insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details) values(t,p_purchase_id,'financially_closed',auth.uid(),result); end if;
 insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,payload,result,auth.uid());
 return result;
end $$;

create function public.refund_purchase(p_purchase_id uuid,p_obligation_id uuid,p_payments jsonb,p_request_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('purchases:manage'); p public.purchases; o public.purchase_refund_obligations;
 payload jsonb; prior public.finance_requests; result jsonb; x jsonb; w public.wallets; lw uuid; a numeric; debit numeric; id uuid;
 refunded numeric; total numeric:=0; details jsonb:='[]';
begin
 if p_request_id is null then raise exception 'Refund request ID is required'; end if;
 payload:=jsonb_build_object('action','purchase_refund','purchase',p_purchase_id,'obligation',p_obligation_id,'payments',p_payments,'actor',auth.uid());
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from payload then raise exception 'Request ID already used with different details'; end if; return prior.result; end if;
 select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id for update;
 if not found then raise exception 'Purchase not found'; end if;
 if p.status<>'cancelled' or p.financial_closed_at is not null then raise exception 'Only pending cancelled purchases accept refunds'; end if;
 select * into o from public.purchase_refund_obligations where tenant_id=t and purchase_id=p_purchase_id and obligation_id=p_obligation_id;
 if not found then raise exception 'Refund obligation not found'; end if;
 select coalesce(sum(amount),0) into refunded from public.purchase_payments where tenant_id=t and obligation_id=p_obligation_id;
 if p_payments is null or jsonb_typeof(p_payments)<>'array' or jsonb_array_length(p_payments) not between 1 and 20 then raise exception 'Add between 1 and 20 refund entries'; end if;
 select wallet_id into lw from public.wallets where tenant_id=t and type='logistics';
 perform 1 from public.wallets where tenant_id=t and (wallet_id=lw or wallet_id in(select (value->>'wallet_id')::uuid from jsonb_array_elements(p_payments))) order by wallet_id for update;
 for x in select value from jsonb_array_elements(p_payments) loop
  if jsonb_typeof(x)<>'object' or jsonb_typeof(x->'amount') is distinct from 'number' then raise exception 'Refund amounts must be numbers'; end if;
  a:=app_private.purchase_money((x->>'amount')::numeric);
  if a<=0 or a<>(x->>'amount')::numeric then raise exception 'Enter a positive amount with at most two decimals'; end if;
  if length(coalesce(x->>'reference',''))>200 then raise exception 'Refund reference is too long'; end if;
  select * into w from public.wallets where tenant_id=t and wallet_id=(x->>'wallet_id')::uuid and is_active and (o.credit_business and kind<>'logistics' or not o.credit_business and wallet_id=lw);
  if not found then raise exception 'Select an active refund wallet belonging to this business'; end if;
  if refunded+total+a>o.amount then raise exception 'Refund exceeds the remaining obligation'; end if;
  debit:=least(a,greatest(0,o.logistics_amount-refunded-total));
  insert into public.purchase_payments(tenant_id,purchase_id,wallet_id,wallet_name,method,amount,kind,component,obligation_id,operation_id,reference,created_by)
   values(t,p_purchase_id,w.wallet_id,w.name,w.kind,a,'refund',o.component,o.obligation_id,p_request_id,coalesce(x->>'reference',''),auth.uid()) returning payment_id into id;
  if o.credit_business then
   insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description,operation_id,purchase_payment_id,counterparty_wallet_id)
    values(t,w.wallet_id,a,'purchase_refund',p_purchase_id,'Purchase '||o.component||' refund · '||w.name||' · '||coalesce(x->>'reference',''),p_request_id,id,case when debit>0 then lw end);
  end if;
  if debit>0 then
   insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description,operation_id,purchase_payment_id,counterparty_wallet_id)
    values(t,lw,-debit,'purchase_funding_reversal',p_purchase_id,'Purchase transport funding reversed; operating expenses retained',p_request_id,id,case when o.credit_business then w.wallet_id end);
  end if;
  details:=details||jsonb_build_array(jsonb_build_object('payment_id',id,'wallet_id',w.wallet_id,'wallet_name',w.name,'method',w.kind,'amount',a,'component',o.component,'reference',coalesce(x->>'reference',''),'logistics_reversal',debit,'business_credit',case when o.credit_business then a else 0 end));
  total:=total+a;
 end loop;
 update public.purchases set refund_due=refund_due-total,refunded_amount=refunded_amount+total,
  financial_closed_at=case when refund_due=total then now() end,revision=revision+1,updated_at=now() where tenant_id=t and purchase_id=p_purchase_id;
 result:=jsonb_build_object('purchase_id',p_purchase_id,'refunded',total,'refund_due',p.refund_due-total,'financially_closed',p.refund_due=total);
 insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details) values(t,p_purchase_id,'refund_recorded',auth.uid(),result||jsonb_build_object('payments',details,'obligation_id',o.obligation_id,'original_payments',o.sources,'operation_id',p_request_id));
 if p.refund_due=total then
  insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details) values(t,p_purchase_id,'refund_completed',auth.uid(),result),(t,p_purchase_id,'financially_closed',auth.uid(),jsonb_build_object('notes','All purchase refund obligations settled. Transit operating-cost closure remains independent.'));
 end if;
 insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,payload,result,auth.uid());
 return result;
end $$;

create or replace function public.update_purchase(p_purchase_id uuid,p_payload jsonb,p_revision integer) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t uuid := app_private.require_permission('purchases:manage'); p public.purchases; truck uuid; before_items jsonb;
begin
  select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id for update;
  if not found then raise exception 'Purchase not found'; end if;
  if p_revision is distinct from p.revision then raise exception 'Purchase changed. Reload it before saving.' using errcode='40001'; end if;
  if p.status='cancelled' or (p.status='received' and p.payment_status='paid') then raise exception 'Purchase is completed and locked'; end if;
  if p_payload ? 'plant_id' and (p_payload->>'plant_id')::uuid is distinct from p.plant_id
    or p_payload ? 'brand_id' and (p_payload->>'brand_id')::uuid is distinct from p.brand_id then
    raise exception 'Plant and company cannot change'; end if;
  select jsonb_agg(to_jsonb(pi)) into before_items from public.purchase_items pi where tenant_id=t and purchase_id=p_purchase_id;
  truck := case when p_payload ? 'truck_id' then (p_payload->>'truck_id')::uuid else p.truck_id end;
  if p.status<>'created' and truck is distinct from p.truck_id then raise exception 'Truck is locked after dispatch'; end if;
  if truck is not null and not exists(select 1 from public.trucks where tenant_id=t and truck_id=truck) then raise exception 'Truck not found'; end if;
  if p.payment_status='paid' or exists(select 1 from public.wallet_transactions where tenant_id=t and reference_id=p_purchase_id and amount<0 and type in ('purchase_expense','purchase_company_payment','purchase_logistics_payment','purchase_payment_company','purchase_payment_labour','purchase_payment_transport')) then
    if p_payload ? 'items' or p_payload ? 'commission' or p_payload ? 'transport_cost' or p_payload ? 'labour_cost' then
      raise exception 'Financial values lock after the first payment'; end if;
  else
    update public.purchases set truck_id=truck where tenant_id=t and purchase_id=p_purchase_id;
    if p_payload ?| array['items','commission','transport_cost','labour_cost'] then
    if p.status<>'created' then
      perform 1 from public.trucks where tenant_id=t and truck_id=p.truck_id for update;
      perform 1 from public.transits where tenant_id=t and purchase_id=p_purchase_id order by transit_id for update;
    end if;
    if p_payload ? 'items' then perform app_private.save_purchase_lines(t,p_purchase_id,p_payload->'items'); end if;
    update public.purchases set truck_id=truck,
      transport_cost=app_private.purchase_money(coalesce((p_payload->>'transport_cost')::numeric,transport_cost,0)),
      labour_cost=app_private.purchase_money(coalesce((p_payload->>'labour_cost')::numeric,labour_cost,0)),
      commission=app_private.purchase_money(coalesce((p_payload->>'commission')::numeric,commission))
      where tenant_id=t and purchase_id=p_purchase_id;
    perform app_private.recalculate_purchase(t,p_purchase_id);
    if exists(select 1 from public.transits where tenant_id=t and purchase_id=p_purchase_id and closed_at is not null)
      and (select transport_cost from public.purchases where tenant_id=t and purchase_id=p_purchase_id) is distinct from p.transport_cost then
      raise exception 'Transport fee is locked because the transit is closed'; end if;
    update public.transits set transport_fee=(select transport_cost from public.purchases where tenant_id=t and purchase_id=p_purchase_id)
      where tenant_id=t and purchase_id=p_purchase_id;
    if p.status<>'created' then perform app_private.fund_purchase_transport(t,p_purchase_id); end if;
    end if;
  end if;
  update public.purchases set payment_status=case when status='created' then payment_status when paid_amount>=total_cost then 'paid' when paid_amount>0 then 'partial' else 'unpaid' end,
    paid_at=case when status<>'created' and paid_amount>=total_cost then coalesce(paid_at,now()) else paid_at end,notes=case when p_payload ? 'notes' then p_payload->>'notes' else notes end,
    updated_at=now(),revision=revision+1 where tenant_id=t and purchase_id=p_purchase_id;
  insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details)
    values(t,p_purchase_id,'updated',auth.uid(),jsonb_build_object('before',to_jsonb(p),'before_items',before_items,
      'after',(select to_jsonb(h) from public.purchases h where h.tenant_id=t and h.purchase_id=p_purchase_id),
      'items',(select jsonb_agg(to_jsonb(pi)) from public.purchase_items pi where pi.tenant_id=t and pi.purchase_id=p_purchase_id)));
  return jsonb_build_object('purchase_id',p_purchase_id);
end $$;

create function public.get_purchase_settlement(p_purchase_id uuid,p_offset integer default 0,p_limit integer default 10) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['purchases:view','purchases:manage']); p public.purchases; result jsonb;
begin
 if p_offset is null or p_limit is null or p_offset<0 or p_limit not between 1 and 100 then raise exception 'Invalid payment page'; end if;
 select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id;
 if not found then raise exception 'Purchase not found'; end if;
 select jsonb_build_object('total',p.total_cost,'paid',p.paid_amount,'due',case when p.status='cancelled' then 0 else greatest(0,p.total_cost-p.paid_amount) end,
 'refund_due',p.refund_due,'refunded',p.refunded_amount,'financial_closed_at',p.financial_closed_at,'can_cancel',public.can_cancel_purchases(),
 'internal_wallet',(select jsonb_build_object('wallet_id',wallet_id,'name',name,'kind',kind,'type',type) from public.wallets where tenant_id=t and type='logistics'),
 'legacy',p.legacy_record,'financial_locked',p.payment_status='paid' or exists(select 1 from public.wallet_transactions where tenant_id=t and reference_id=p_purchase_id and amount<0 and type in ('purchase_expense','purchase_company_payment','purchase_logistics_payment','purchase_payment_company','purchase_payment_labour','purchase_payment_transport')),
 'obligations',coalesce((select jsonb_agg(to_jsonb(o)||jsonb_build_object('refunded',coalesce(q.amount,0),'remaining',o.amount-coalesce(q.amount,0)) order by o.component)
 from public.purchase_refund_obligations o left join lateral(select sum(amount) amount from public.purchase_payments where tenant_id=t and obligation_id=o.obligation_id) q on true where o.tenant_id=t and o.purchase_id=p_purchase_id),'[]'),
 'payment_count',(select count(*) from public.wallet_transactions where tenant_id=t and reference_id=p_purchase_id),
 'payments',coalesce((select jsonb_agg(to_jsonb(e) order by e.entry_no) from (select x.transaction_id,x.purchase_payment_id,x.wallet_name_snapshot wallet_name,x.wallet_method_snapshot method,x.amount,x.type,x.created_at,x.entry_no,x.operation_id,x.description,x.counterparty_wallet_id,pp.reference,pp.component,pp.obligation_id,up.full_name actor
  from public.wallet_transactions x left join public.purchase_payments pp on pp.tenant_id=t and pp.payment_id=x.purchase_payment_id
  left join public.user_profiles up on up.tenant_id=t and up.user_id=x.created_by
  where x.tenant_id=t and x.reference_id=p_purchase_id order by x.entry_no limit p_limit offset p_offset) e),'[]')) into result;
 return result;
end $$;

create or replace function public.get_purchase_overview() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['purchases:view','purchases:manage']); result jsonb;
begin
 select jsonb_build_object('total',count(*),'created',count(*) filter(where status='created'),'in_transit',count(*) filter(where status='in_transit'),
 'unpaid',count(*) filter(where payment_status<>'paid' and status not in ('created','cancelled')),
 'company_payable',coalesce(sum(company_payable) filter(where payment_status<>'paid' and status not in ('created','cancelled')),0),
 'outstanding',coalesce(sum(greatest(0,total_cost-paid_amount)) filter(where status not in ('created','cancelled')),0),
 'refund_due',coalesce(sum(refund_due),0),'pending_refunds',count(*) filter(where status='cancelled' and financial_closed_at is null)) into result from public.purchases where tenant_id=t;
 return result;
end $$;

create or replace function public.get_purchase_directory(p_filters jsonb default '{}'::jsonb,p_offset integer default 0,p_limit integer default 6) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['purchases:view','purchases:manage']); result jsonb;
  ordering text:=coalesce(p_filters->>'sort','date_desc'); searching boolean:=false;
begin
  if p_filters is null or jsonb_typeof(p_filters)<>'object' or length(coalesce(p_filters->>'search',''))>500
    or coalesce(p_filters->>'status','all') not in ('all','created','in_transit','received','cancelled','pending_refund','closed')
    or coalesce(p_filters->>'payment','all') not in ('all','unpaid','partial','paid')
    or ordering not in ('date_desc','date_asc','amount_desc','amount_asc') then raise exception 'Invalid purchase filters'; end if;
  if p_offset is null or p_limit is null or p_offset<0 or p_offset>1000000 or p_limit not between 1 and 100 then raise exception 'Invalid purchase page'; end if;
  searching:=exists(select 1 from regexp_split_to_table(coalesce(p_filters->>'search',''),'\s*,\s*') g where btrim(g)<>'');
  with matching as materialized (
    select p.purchase_id,p.created_at,p.total_cost from public.purchases p
    left join public.trucks tr on tr.tenant_id=t and tr.truck_id=p.truck_id
    left join public.gas_plants gp on gp.tenant_id=t and gp.plant_id=p.plant_id
    left join public.lpg_brands b on b.tenant_id=t and b.brand_id=p.brand_id
    where p.tenant_id=t
      and (coalesce(p_filters->>'status','all')='all' or p.status::text=p_filters->>'status' or p_filters->>'status'='pending_refund' and p.status='cancelled' and p.financial_closed_at is null or p_filters->>'status'='closed' and p.status='cancelled' and p.financial_closed_at is not null)
      and (coalesce(p_filters->>'payment','all')='all' or p.payment_status=p_filters->>'payment')
      and (nullif(p_filters->>'from','') is null or p.created_at >= (nullif(p_filters->>'from','')::date::timestamp at time zone 'Asia/Dhaka'))
      and (nullif(p_filters->>'to','') is null or p.created_at < ((nullif(p_filters->>'to','')::date+1)::timestamp at time zone 'Asia/Dhaka'))
      and (not searching or exists(
        select 1 from (select lower(concat_ws(' ',p.purchase_id,b.brand_name,gp.plant_name,tr.name,p.notes,p.receipt_notes,p.status,p.payment_status,
          (select string_agg(concat_ws(' ',coalesce(lb.brand_name,i.brand),trim_scale(i.size_kg)||'kg',trim_scale(i.size_kg)||' kg',i.mouth_size,
            case when pi.type='refill' then 'refill exchange' else 'package new cylinders' end),' ')
          from public.purchase_items pi join public.items i on i.tenant_id=pi.tenant_id and i.item_id=pi.item_id
          left join public.lpg_brands lb on lb.tenant_id=i.tenant_id and lb.brand_id=i.brand_id where pi.tenant_id=t and pi.purchase_id=p.purchase_id))) text) document
        where exists(select 1 from regexp_split_to_table(lower(p_filters->>'search'),'\s*,\s*') g where btrim(g)<>'' and not exists(
          select 1 from regexp_split_to_table(btrim(g),'\s+') token where token<>'' and position(token in document.text)=0))))
  ), page as materialized (
    select * from matching order by
      case when ordering='date_desc' then created_at end desc,case when ordering='date_asc' then created_at end asc,
      case when ordering='amount_desc' then total_cost end desc,case when ordering='amount_asc' then total_cost end asc,purchase_id
    limit p_limit offset p_offset
  ), details as (
    select r.* from app_private.purchase_rows(t,coalesce((select array_agg(purchase_id) from page),'{}'::uuid[])) r
  ) select jsonb_build_object('total',(select count(*) from matching),'entries',coalesce((select jsonb_agg(d.r order by
    case when ordering='date_desc' then p.created_at end desc,case when ordering='date_asc' then p.created_at end asc,
    case when ordering='amount_desc' then p.total_cost end desc,case when ordering='amount_asc' then p.total_cost end asc,p.purchase_id)
    from details d(r) join page p on p.purchase_id=(d.r->>'purchase_id')::uuid),'[]'::jsonb)) into result;
  return result;
end $$;
create or replace function public.list_transits() returns setof jsonb
language plpgsql security definer set search_path='' as $$
declare t uuid := app_private.require_any_permission(array['logistics:view','logistics:manage']);
begin
  return query select to_jsonb(tr)||jsonb_build_object('truck_name',truck.name,'purchase_refund_due',p.refund_due,'purchase_financial_closed_at',p.financial_closed_at,
    'status',case when p.status='received' and tr.status='active' then 'completed' else tr.status::text end)
    from public.transits tr join public.trucks truck on truck.tenant_id=tr.tenant_id and truck.truck_id=tr.truck_id
    left join public.purchases p on p.tenant_id=tr.tenant_id and p.purchase_id=tr.purchase_id
    where tr.tenant_id=t order by tr.created_at desc;
end $$;
create or replace function public.save_transit_costs(p_transit_id uuid,p_costs jsonb,p_revision integer) returns jsonb
language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('logistics:manage'); tr public.transits; pid uuid; x jsonb; total numeric;
  driver numeric:=app_private.purchase_money((p_costs->>'driver_cost')::numeric);
  helper numeric:=app_private.purchase_money((p_costs->>'helper_cost')::numeric);
  oil numeric:=app_private.purchase_money((p_costs->>'oil_cost')::numeric);
  others numeric:=app_private.purchase_money((p_costs->>'others_cost')::numeric);
  extra jsonb:=coalesce(p_costs->'additional_costs','[]');
begin
  select purchase_id into pid from public.transits where tenant_id=t and transit_id=p_transit_id;
  if pid is not null then perform 1 from public.purchases where tenant_id=t and purchase_id=pid for update; end if;
  select * into tr from public.transits where tenant_id=t and transit_id=p_transit_id for update;
  if not found then raise exception 'Transit not found'; end if;
  if tr.closed_at is not null then raise exception 'Closed transit costs are locked'; end if;
  if p_revision is distinct from tr.revision then raise exception 'Transit changed. Reload before saving.' using errcode='40001'; end if;
  if jsonb_typeof(extra)<>'array' then raise exception 'Additional costs must be an array'; end if;
  total:=driver+helper+oil+others;
  for x in select value from jsonb_array_elements(extra) loop
    if nullif(trim(x->>'name'),'') is null then raise exception 'Additional cost name is required'; end if;
    total:=total+app_private.purchase_money((x->>'amount')::numeric);
  end loop;
  update public.transits set driver_cost=driver,helper_cost=helper,oil_cost=oil,others_cost=others,
    additional_costs=extra,total_cost=total,updated_at=now(),revision=revision+1 where tenant_id=t and transit_id=p_transit_id;
  if pid is not null then
    insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details)
      values(t,pid,'logistics_updated',auth.uid(),jsonb_build_object('transit_id',p_transit_id,'operating_cost',total,'before',to_jsonb(tr),'after',(select to_jsonb(h) from public.transits h where h.tenant_id=t and h.transit_id=p_transit_id)));
  end if;
  return jsonb_build_object('transit_id',p_transit_id);
end $$;
create or replace function public.get_wallet_ledger(p_filters jsonb default '{}',p_offset integer default 0,p_limit integer default 25) returns jsonb
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
  'entries',coalesce((select jsonb_agg((to_jsonb(p)-'search_document')||jsonb_build_object('wallet_name',coalesce(p.wallet_name_snapshot,w.name),'counterparty',cw.name,'actor',up.full_name,
   'payment_reference',coalesce(sp.reference,pp.reference),'customer_name',c.name,'customer_phone',c.phone,'source',case when sp.payment_id is not null then 'sale' when p.type like 'purchase%%' then 'purchase' when p.type like 'transit%%' or p.type like 'transport%%' then 'transit' else null end) order by
   case when $3='date_desc' then p.created_at end desc,case when $3='date_asc' then p.created_at end,
   case when $3='amount_desc' then abs(p.amount) end desc,case when $3='amount_asc' then abs(p.amount) end,p.entry_no desc)
   from page keys join public.wallet_transactions p on p.tenant_id=$1 and p.transaction_id=keys.transaction_id
   join public.wallets w on w.tenant_id=$1 and w.wallet_id=p.wallet_id
   left join public.wallets cw on cw.tenant_id=$1 and cw.wallet_id=p.counterparty_wallet_id
   left join public.user_profiles up on up.tenant_id=$1 and up.user_id=p.created_by
   left join public.sale_payments sp on sp.tenant_id=$1 and sp.payment_id=p.payment_id
   left join public.purchase_payments pp on pp.tenant_id=$1 and pp.payment_id=p.purchase_payment_id
   left join public.sales s on s.tenant_id=$1 and s.sale_id=sp.sale_id
   left join public.customers c on c.tenant_id=$1 and c.customer_id=s.customer_id),'[]'))
 $ledger$,search_condition) into result using t,p_filters,sorting,p_limit,p_offset;
 return result;
end $$;
alter table public.purchase_payments owner to postgres;
alter table public.purchase_refund_obligations owner to postgres;
alter function public.can_cancel_purchases() owner to postgres;
revoke all on function public.can_cancel_purchases() from public,anon,authenticated;
grant execute on function public.can_cancel_purchases() to authenticated;
alter function public.record_purchase_payment(uuid,jsonb,uuid) owner to postgres;
revoke all on function public.record_purchase_payment(uuid,jsonb,uuid) from public,anon,authenticated;
grant execute on function public.record_purchase_payment(uuid,jsonb,uuid) to authenticated;
alter function public.initiate_purchase_cancellation(uuid,integer,text,uuid) owner to postgres;
revoke all on function public.initiate_purchase_cancellation(uuid,integer,text,uuid) from public,anon,authenticated;
grant execute on function public.initiate_purchase_cancellation(uuid,integer,text,uuid) to authenticated;
alter function public.refund_purchase(uuid,uuid,jsonb,uuid) owner to postgres;
revoke all on function public.refund_purchase(uuid,uuid,jsonb,uuid) from public,anon,authenticated;
grant execute on function public.refund_purchase(uuid,uuid,jsonb,uuid) to authenticated;
alter function public.get_purchase_settlement(uuid,integer,integer) owner to postgres;
revoke all on function public.get_purchase_settlement(uuid,integer,integer) from public,anon,authenticated;
grant execute on function public.get_purchase_settlement(uuid,integer,integer) to authenticated;
notify pgrst, 'reload schema';

create or replace function public.dispatch_purchase(p_purchase_id uuid,p_revision integer) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t uuid := app_private.require_permission('purchases:manage'); p public.purchases; tr public.trucks; x record;
begin
  select * into p from public.purchases where tenant_id=t and purchase_id=p_purchase_id for update;
  if not found then raise exception 'Purchase not found'; end if;
  if p.status='in_transit' or p.status='received' then return jsonb_build_object('purchase_id',p_purchase_id,'already_dispatched',true); end if;
  if p.status<>'created' then raise exception 'Only a Created purchase can be dispatched'; end if;
  if p_revision is distinct from p.revision then raise exception 'Purchase changed. Reload before dispatch.' using errcode='40001'; end if;
  select * into tr from public.trucks where tenant_id=t and truck_id=p.truck_id for update;
  if not found or tr.status<>'idle' then raise exception 'Select an idle truck before dispatch'; end if;
  if exists(select 1 from public.transits where tenant_id=t and truck_id=p.truck_id and status='active')
    or exists(select 1 from public.purchases where tenant_id=t and truck_id=p.truck_id and status='in_transit') then
    raise exception 'Truck already has an active shipment'; end if;
  if not exists(select 1 from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id) then raise exception 'Add at least one product before dispatch'; end if;
  -- Existing Created plans need an explicit save before dispatch if they used
  -- independent empties. Do not silently rewrite a saved plan or its revision.
  if exists(select 1 from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id
    and empty_dispatched <> case when type='refill' then quantity else 0 end) then
    raise exception 'Refills exchange one empty cylinder per refill. Refresh and save the purchase before dispatch.';
  end if;
  perform 1 from public.gas_plants gp join public.lpg_brands b on b.tenant_id=gp.tenant_id and b.brand_id=gp.brand_id
    where gp.tenant_id=t and gp.plant_id=p.plant_id and gp.brand_id=p.brand_id and gp.is_active and b.is_active for share of gp,b;
  if not found then raise exception 'Plant company is unavailable'; end if;
  perform app_private.check_purchase_empties(t,(select jsonb_agg(to_jsonb(pi)) from public.purchase_items pi where tenant_id=t and purchase_id=p_purchase_id));
  -- Acquire stock locks in SKU order. Movement inserts apply the stock once.
  for x in select i.item_id,i.empty_quantity,i.brand_id,sum(pi.empty_dispatched) outgoing
    from public.purchase_items pi join public.items i on i.tenant_id=pi.tenant_id and i.item_id=pi.item_id
    where pi.tenant_id=t and pi.purchase_id=p_purchase_id group by i.tenant_id,i.item_id order by i.item_id loop
    perform 1 from public.items where tenant_id=t and item_id=x.item_id for update;
    if x.brand_id is distinct from p.brand_id then raise exception 'All products must belong to the plant company'; end if;
    if (select empty_quantity from public.items where tenant_id=t and item_id=x.item_id) < x.outgoing then
      raise exception 'Insufficient empty cylinder stock'; end if;
    if x.outgoing>0 then
      insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,empty_quantity_change,notes,created_by)
      values(t,x.item_id,'purchase','purchase_dispatch',p_purchase_id,-x.outgoing,'Empty cylinders dispatched to plant',auth.uid());
    end if;
  end loop;
  insert into public.transits(tenant_id,truck_id,purchase_id,status,transport_fee)
    values(t,p.truck_id,p_purchase_id,'active',p.transport_cost);
  perform app_private.fund_purchase_transport(t,p_purchase_id);
  update public.trucks set status='going',updated_at=now() where tenant_id=t and truck_id=p.truck_id;
  update public.purchases set status='in_transit',dispatched_at=now(),payment_status=case when paid_amount>=total_cost then 'paid' when paid_amount>0 then 'partial' else 'unpaid' end,paid_at=case when paid_amount>=total_cost then now() end,updated_at=now(),revision=revision+1
    where tenant_id=t and purchase_id=p_purchase_id;
  insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details)
    values(t,p_purchase_id,'dispatched',auth.uid(),jsonb_build_object('empty_cylinders',
      (select sum(empty_dispatched) from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id)));
  return jsonb_build_object('purchase_id',p_purchase_id);
end $$;
update public.purchases set payment_status='partial' where status<>'cancelled' and payment_status='unpaid' and paid_amount>0 and paid_amount<total_cost;
update public.purchases set payment_status='paid',paid_at=coalesce(paid_at,updated_at) where status in ('in_transit','received') and payment_status<>'paid' and total_cost>=0 and paid_amount>=total_cost;
