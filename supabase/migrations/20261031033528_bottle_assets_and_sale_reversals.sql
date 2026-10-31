-- Outstanding returnable bottles retain their carrying value across periods.
-- Receiving bottles transfers that asset back into stock, not next-period profit.
create function app_private.recognize_bottle_asset() returns trigger language plpgsql set search_path='' as $$declare unit_cost numeric;begin
 if new.type='empty_return' then
  select coalesce(case when c.empty_quantity>0 then c.empty_value/c.empty_quantity end,c.empty_unit_cost) into unit_cost from public.inventory_costs c where c.tenant_id=new.tenant_id and c.item_id=new.item_id;
  if unit_cost is null then raise exception 'Record the cylinder opening value before checkout';end if;
  perform app_private.post_journal(new.tenant_id,'bottle_obligation',new.sale_item_id,'recognize',(now() at time zone 'Asia/Dhaka')::date,'Returnable bottle asset',jsonb_build_array(
   app_private.accounting_line('bottle_receivable',round(unit_cost*new.quantity,2),'lpg',new.sale_id),app_private.accounting_line('cogs',-round(unit_cost*new.quantity,2),'lpg')));
 end if;return new;end $$;
create trigger recognize_bottle_asset after insert on public.sale_items for each row execute function app_private.recognize_bottle_asset();
create table public.sale_reversals (
 tenant_id uuid not null,sale_id uuid not null,reason text not null,created_at timestamptz not null default clock_timestamp(),created_by uuid,
 primary key(tenant_id,sale_id),foreign key(tenant_id,sale_id) references public.sales(tenant_id,sale_id)
);
create table public.sale_refunds (
 tenant_id uuid not null,refund_id uuid not null default gen_random_uuid(),sale_id uuid not null,wallet_id uuid not null,amount numeric(16,2) not null check(amount>0 and amount<1000000000000),
 operation_id uuid not null,created_at timestamptz not null default clock_timestamp(),created_by uuid,primary key(tenant_id,refund_id),
 foreign key(tenant_id,sale_id) references public.sale_reversals(tenant_id,sale_id),foreign key(tenant_id,wallet_id) references public.wallets(tenant_id,wallet_id)
);
create index sale_refund_parent on public.sale_refunds(tenant_id,sale_id);
create index sale_refund_wallet on public.sale_refunds(tenant_id,wallet_id);
create function public.reverse_sale(p_sale_id uuid,p_reason text,p_confirmation text,p_request_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_owner('finance:manage');s public.sales;prior public.finance_requests;body jsonb:=jsonb_build_object('action','sale_reversal','actor',auth.uid(),'sale',p_sale_id,'reason',p_reason,'confirmation',p_confirmation);r record;value numeric;result jsonb;begin
 if p_request_id is null or p_confirmation is distinct from 'CANCEL' or nullif(trim(p_reason),'') is null or length(p_reason)>1000 then raise exception 'Reason, request ID and CANCEL confirmation are required';end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from body then raise exception 'Request ID already used';end if;return prior.result;end if;
 select * into s from public.sales where tenant_id=t and sale_id=p_sale_id for update;
 if not found or s.status<>'completed' then raise exception 'Completed sale not found';end if;
 if not exists(select 1 from public.inventory_cost_entries e join public.inventory_movements m using(tenant_id,movement_id) where e.tenant_id=t and m.reference_id=p_sale_id and m.reference_type='sale' and e.filled_change<0) or exists(select 1 from public.inventory_movements m where m.tenant_id=t and m.reference_id=p_sale_id and m.reference_type='sale' and not exists(select 1 from public.inventory_cost_entries e where e.tenant_id=t and e.movement_id=m.movement_id)) then raise exception 'Pre-opening sale has no recorded carrying costs; it cannot be reversed automatically';end if;
 for r in select item_id,-sum(filled_quantity_change) filled,-sum(empty_quantity_change) empties from public.inventory_movements where tenant_id=t and reference_id=p_sale_id and reference_type='sale' group by item_id order by item_id loop
  perform 1 from public.items where tenant_id=t and item_id=r.item_id for update;
  insert into public.inventory_movements(tenant_id,item_id,movement_type,reference_type,reference_id,filled_quantity_change,empty_quantity_change,notes,created_by)
  values(t,r.item_id,'adjust_gain','sale_reversal',p_sale_id,r.filled,r.empties,'Sale cancellation: '||trim(p_reason),auth.uid());
 end loop;
 select coalesce(sum(amount),0) into value from public.accounting_lines where tenant_id=t and account='bottle_receivable' and entity_id=p_sale_id;
 perform app_private.post_journal(t,'bottle_reversal',p_sale_id,'cancel',(now() at time zone 'Asia/Dhaka')::date,'Cancel remaining bottle obligation',jsonb_build_array(
 app_private.accounting_line('bottle_receivable',-value,'lpg',p_sale_id),app_private.accounting_line('cogs',value,'lpg')));
 insert into public.customer_transactions(tenant_id,customer_id,type,amount,reference_id,created_by) values(t,s.customer_id,'invoice_charge',s.total_amount+s.additional_charges,p_sale_id,auth.uid());
 insert into public.sale_reversals(tenant_id,sale_id,reason,created_by) values(t,p_sale_id,trim(p_reason),auth.uid());
 update public.sales set status='voided',updated_at=clock_timestamp() where tenant_id=t and sale_id=p_sale_id;
 result:=jsonb_build_object('sale_id',p_sale_id,'refund_due',s.paid_amount);insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,result,auth.uid());return result;end $$;
create function public.refund_sale(p_sale_id uuid,p_payments jsonb,p_request_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_owner('finance:manage');s public.sales;prior public.finance_requests;body jsonb:=jsonb_build_object('action','sale_refund','actor',auth.uid(),'sale',p_sale_id,'payments',p_payments);x jsonb;w public.wallets;a numeric;refunded numeric;total numeric:=0;id uuid;result jsonb;begin
 if p_request_id is null or jsonb_typeof(p_payments) is distinct from 'array' or jsonb_array_length(p_payments) not between 1 and 20 then raise exception 'Request ID and payment entries are required';end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from body then raise exception 'Request ID already used';end if;return prior.result;end if;
 select * into s from public.sales where tenant_id=t and sale_id=p_sale_id for update;if not found or s.status<>'voided' then raise exception 'Cancel the sale before recording refunds';end if;
 select coalesce(sum(amount),0) into refunded from public.sale_refunds where tenant_id=t and sale_id=p_sale_id;
 perform 1 from public.wallets where tenant_id=t and wallet_id in(select (value->>'wallet_id')::uuid from jsonb_array_elements(p_payments)) order by wallet_id for update;
 for x in select value from jsonb_array_elements(p_payments) loop
  a:=app_private.purchase_money((x->>'amount')::numeric);if a<=0 then raise exception 'Enter positive refund amounts';end if;total:=total+a;
  if total+refunded>s.paid_amount then raise exception 'Refund exceeds recorded customer payments';end if;
  select * into w from public.wallets where tenant_id=t and wallet_id=(x->>'wallet_id')::uuid and is_active;if not found then raise exception 'Choose an active business wallet';end if;
  insert into public.sale_refunds(tenant_id,sale_id,wallet_id,amount,operation_id,created_by) values(t,p_sale_id,w.wallet_id,a,p_request_id,auth.uid()) returning refund_id into id;
  insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,operation_id,description) values(t,w.wallet_id,-a,'sale_refund',p_sale_id,p_request_id,'Customer refund: sale #'||left(p_sale_id::text,8));
  insert into public.customer_transactions(tenant_id,customer_id,type,amount,reference_id,created_by) values(t,s.customer_id,'payment',-a,p_sale_id,auth.uid());
 end loop;
 result:=jsonb_build_object('sale_id',p_sale_id,'refund_due',s.paid_amount-refunded-total);insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,result,auth.uid());return result;end $$;
do $$declare n text;begin foreach n in array array['sale_reversals','sale_refunds'] loop
 execute format('alter table public.%I owner to postgres',n);execute format('alter table public.%I enable row level security',n);execute format('revoke all on public.%I from public,anon,authenticated',n);
 execute format('create trigger accounting_immutable before update or delete on public.%I for each row execute function app_private.immutable_finance_record()',n);end loop;end $$;
alter function app_private.recognize_bottle_asset() owner to postgres;
alter function public.reverse_sale(uuid,text,text,uuid) owner to postgres;
alter function public.refund_sale(uuid,jsonb,uuid) owner to postgres;
revoke all on function app_private.recognize_bottle_asset(),public.reverse_sale(uuid,text,text,uuid),public.refund_sale(uuid,jsonb,uuid) from public,anon,authenticated;
grant execute on function public.reverse_sale(uuid,text,text,uuid),public.refund_sale(uuid,jsonb,uuid) to authenticated;
