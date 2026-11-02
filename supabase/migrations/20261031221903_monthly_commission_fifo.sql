-- Monthly rebates and durable FIFO. Operational records and posted journals are
-- preserved; corrections append dated journal/cost deltas and invalidate savepoints.
create table public.monthly_commission_rates (
 tenant_id uuid not null,item_id uuid not null,month date not null,
 rate numeric(18,6) not null check(rate>=0 and rate<10000000000),
 source text not null check(source in ('manual','inferred_partial')),
 calculation jsonb not null default '{}',revision integer not null default 1,
 modified_by uuid,modified_at timestamptz not null default clock_timestamp(),
 primary key(tenant_id,item_id,month),foreign key(tenant_id,item_id) references public.items(tenant_id,item_id),
 check(isfinite(month) and month=date_trunc('month',month)::date)
);
create table public.monthly_commission_history (
 tenant_id uuid not null,history_id uuid not null default gen_random_uuid(),item_id uuid not null,month date not null,
 rate numeric(18,6) not null,source text not null,calculation jsonb not null,revision integer not null,
 reason text not null,modified_by uuid,modified_at timestamptz not null default clock_timestamp(),
 primary key(tenant_id,history_id),foreign key(tenant_id,item_id) references public.items(tenant_id,item_id)
);
create index monthly_commission_history_page on public.monthly_commission_history(tenant_id,item_id,month desc,modified_at desc);
create table public.monthly_commission_deductions (
 tenant_id uuid not null,purchase_id uuid not null,earned_month date not null,received_on date not null,
 amount numeric(16,2) not null check(amount>=0),revision integer not null default 1,modified_by uuid,
 primary key(tenant_id,purchase_id),foreign key(tenant_id,purchase_id) references public.purchases(tenant_id,purchase_id),
 check(isfinite(earned_month) and earned_month=date_trunc('month',earned_month)::date)
);
create index monthly_deductions_month on public.monthly_commission_deductions(tenant_id,earned_month,purchase_id);
create table public.monthly_commission_deduction_history (
 tenant_id uuid not null,history_id uuid not null default gen_random_uuid(),purchase_id uuid not null,
 earned_month date not null,amount numeric(16,2) not null,reason text not null,
 modified_by uuid,modified_at timestamptz not null default clock_timestamp(),
 primary key(tenant_id,history_id),foreign key(tenant_id,purchase_id) references public.purchases(tenant_id,purchase_id)
);
-- FIFO projections are private. Acquisition quantities/costs and consumption
-- links are retained, including fully consumed layers, for arbitrary cutoffs.
alter table public.inventory_movements add column movement_no bigint generated always as identity;
alter table public.inventory_movements alter column created_at set default clock_timestamp();
create table app_private.fifo_layers (
 tenant_id uuid not null,item_id uuid not null,layer_id uuid not null default gen_random_uuid(),
 movement_id uuid not null,component text not null check(component in ('filled','empty')),
 acquired_at timestamptz not null,acquired_order bigint not null,quantity integer not null check(quantity>0),remaining integer not null check(remaining>=0),
 value numeric(20,2) not null check(value>=0),remaining_value numeric(20,2) not null check(remaining_value>=0),
 shell_value numeric(20,2) not null default 0,remaining_shell_value numeric(20,2) not null default 0,
 primary key(tenant_id,layer_id),unique(tenant_id,movement_id,component),
 foreign key(tenant_id,item_id) references public.items(tenant_id,item_id),check(remaining<=quantity)
);
create index fifo_available on app_private.fifo_layers(tenant_id,item_id,component,acquired_at,acquired_order) where remaining>0;
create table app_private.fifo_consumptions (
 tenant_id uuid not null,movement_id uuid not null,layer_id uuid not null,quantity integer not null,value numeric(20,2) not null,shell_value numeric(20,2) not null default 0,
 primary key(tenant_id,movement_id,layer_id),foreign key(tenant_id,layer_id) references app_private.fifo_layers(tenant_id,layer_id)
);
create index fifo_consumption_layer on app_private.fifo_consumptions(tenant_id,layer_id) include(quantity,value,shell_value);
create table app_private.fifo_movement_costs (
 tenant_id uuid not null,movement_id uuid not null,item_id uuid not null,occurred_at timestamptz not null,
 filled_value numeric(20,2) not null,empty_value numeric(20,2) not null,
 primary key(tenant_id,movement_id),foreign key(tenant_id,movement_id) references public.inventory_movements(tenant_id,movement_id)
);
create index fifo_movement_item on app_private.fifo_movement_costs(tenant_id,item_id,occurred_at,movement_id);
create index inventory_chronology on public.inventory_movements(tenant_id,item_id,created_at,movement_id);
create index commission_eligible_receipts on public.purchases(tenant_id,brand_id,received_at,purchase_id) where status='received' and business_category='lpg';

create function app_private.fifo_take(t uuid,id uuid,mid uuid,part text,qty integer) returns numeric
language plpgsql set search_path='' as $$
declare r record;n integer:=qty;take integer;v numeric;shell numeric;total numeric:=0;begin
 for r in select * from app_private.fifo_layers where tenant_id=t and item_id=id and component=part and remaining>0 order by acquired_at,acquired_order for update loop
  exit when n=0;take:=least(n,r.remaining);v:=case when take=r.remaining then r.remaining_value else round(r.remaining_value*take/r.remaining,2) end;
  shell:=case when take=r.remaining then r.remaining_shell_value else round(r.remaining_shell_value*take/r.remaining,2) end;
  update app_private.fifo_layers set remaining=remaining-take,remaining_value=remaining_value-v,remaining_shell_value=remaining_shell_value-shell where tenant_id=t and layer_id=r.layer_id;
  insert into app_private.fifo_consumptions values(t,mid,r.layer_id,take,v,shell);total:=total+v;n:=n-take;
 end loop;
 if n<>0 then raise exception 'Insufficient FIFO % stock for product %',part,id;end if;
 return total;end $$;

create function app_private.fifo_add(t uuid,id uuid,mid uuid,part text,at_time timestamptz,qty integer,cost numeric,shell numeric default 0) returns void
language plpgsql set search_path='' as $$begin
 if qty>0 then
  if cost<0 then raise exception 'Acquisition commission exceeds recorded acquisition cost';end if;
  if shell<0 or shell>cost then raise exception 'Shell allocation exceeds acquisition value';end if;
  insert into app_private.fifo_layers(tenant_id,item_id,movement_id,component,acquired_at,acquired_order,quantity,remaining,value,remaining_value,shell_value,remaining_shell_value)
  values(t,id,mid,part,at_time,(select movement_no from public.inventory_movements where tenant_id=t and movement_id=mid),qty,qty,cost,cost,shell,shell);
 end if;end $$;

-- Preserve original values as reconciliation targets before recalculating.
insert into app_private.accounting_source_state(tenant_id,source,source_id,lines,revision)
select j.tenant_id,'inventory',j.source_id,jsonb_agg(app_private.accounting_line(l.account,l.amount,l.business_category,l.entity_id)),0
from public.accounting_journals j join public.accounting_lines l using(tenant_id,journal_id)
where j.source='inventory' group by j.tenant_id,j.source_id on conflict do nothing;
insert into app_private.fifo_movement_costs
select e.tenant_id,e.movement_id,e.item_id,m.created_at,e.filled_value,e.empty_value from public.inventory_cost_entries e join public.inventory_movements m using(tenant_id,movement_id);
-- Earlier reconstruction recorded opening valuations in journals/cost entries,
-- but its temporary replay did not persist the movement's valuation payload.
-- Materialize that exact evidence; never estimate a new opening value.
alter table public.inventory_movements disable trigger immutable_inventory_movement;
update public.inventory_movements m set valuation=jsonb_build_object('counter_account','opening_equity',
 'filled_unit_cost',case when e.filled_change>0 then e.filled_value/e.filled_change else 0 end,
 'empty_unit_cost',case when e.empty_change>0 then e.empty_value/e.empty_change else 0 end)
from public.inventory_cost_entries e where e.tenant_id=m.tenant_id and e.movement_id=m.movement_id and m.valuation is null and m.reference_type is null
and exists(select 1 from public.accounting_journals j where j.tenant_id=m.tenant_id and j.source='inventory' and j.source_id=m.movement_id and j.is_opening);
alter table public.inventory_movements enable trigger immutable_inventory_movement;
-- A filled package contains its own shell. Preserve an audit of the obsolete
-- development rule that also removed an unrelated empty shell on package sales.
create table app_private.inventory_normalization_audit(tenant_id uuid not null,movement_id uuid not null,original jsonb not null,reason text not null,recorded_at timestamptz not null default clock_timestamp(),primary key(tenant_id,movement_id));
insert into app_private.inventory_normalization_audit(tenant_id,movement_id,original,reason)
select tenant_id,movement_id,to_jsonb(m),'Package contained its own shell; remove duplicate empty-cylinder consumption' from public.inventory_movements m where reference_type='sale' and filled_quantity_change<0 and empty_quantity_change<0;
alter table public.inventory_movements disable trigger immutable_inventory_movement;
update public.inventory_movements set valuation=jsonb_build_object('sale_type',case when empty_quantity_change<0 then 'package' else 'refill' end),empty_quantity_change=0 where reference_type='sale' and filled_quantity_change<0;
alter table public.inventory_movements enable trigger immutable_inventory_movement;
update public.items i set empty_quantity=empty_quantity+q.qty from(select tenant_id,(original->>'item_id')::uuid item_id,sum(-(original->>'empty_quantity_change')::integer) qty from app_private.inventory_normalization_audit group by 1,2)q where i.tenant_id=q.tenant_id and i.item_id=q.item_id;
insert into public.inventory_cost_entries(tenant_id,item_id,occurred_on,filled_change,empty_change,filled_value,empty_value,filled_after,empty_after,reason,estimated)
select a.tenant_id,(a.original->>'item_id')::uuid,((a.original->>'created_at')::timestamptz at time zone 'Asia/Dhaka')::date,0,-(a.original->>'empty_quantity_change')::integer,0,0,0,0,a.reason,true from app_private.inventory_normalization_audit a;
alter table app_private.inventory_normalization_audit owner to postgres;
alter table app_private.inventory_normalization_audit enable row level security;
revoke all on app_private.inventory_normalization_audit from public,anon,authenticated;
alter table public.purchase_items add column shell_unit_cost numeric(18,6);
-- Existing invoices with refill/package prices establish the shell difference.
-- Otherwise retain the recorded shell basis, labeled by original provenance.
update public.purchase_items pi set shell_unit_cost=greatest(0,least(pi.unit_price,coalesce(pi.unit_price-(select sum(q.billed_quantity*q.unit_price)/nullif(sum(q.billed_quantity),0) from public.purchase_items q where q.tenant_id=pi.tenant_id and q.purchase_id=pi.purchase_id and q.item_id=pi.item_id and q.type='refill'),c.empty_unit_cost,0))) from public.inventory_costs c,public.items i where pi.tenant_id=i.tenant_id and pi.item_id=i.item_id and c.tenant_id=i.tenant_id and c.item_id=i.item_id and i.business_category='lpg' and pi.type='package';

create function app_private.snapshot_purchase_shells(t uuid,pid uuid) returns void language plpgsql set search_path='' as $$begin
 update public.purchase_items pi set shell_unit_cost=coalesce(pi.shell_unit_cost,greatest(0,pi.unit_price-(select sum(q.billed_quantity*q.unit_price)/nullif(sum(q.billed_quantity),0) from public.purchase_items q where q.tenant_id=t and q.purchase_id=pid and q.item_id=pi.item_id and q.type='refill')),(select empty_unit_cost from public.inventory_costs where tenant_id=t and item_id=pi.item_id))
 where pi.tenant_id=t and pi.purchase_id=pid and pi.type='package' and exists(select 1 from public.items where tenant_id=t and item_id=pi.item_id and business_category='lpg');
 if exists(select 1 from public.purchase_items pi join public.items i using(tenant_id,item_id) where pi.tenant_id=t and pi.purchase_id=pid and i.business_category='lpg' and pi.type='package' and (pi.shell_unit_cost is null or pi.shell_unit_cost<0 or pi.shell_unit_cost>pi.unit_price)) then raise exception 'Enter a shell acquisition cost for each package product before receipt';end if;
end $$;
alter function app_private.snapshot_purchase_shells(uuid,uuid) owner to postgres;
revoke all on function app_private.snapshot_purchase_shells(uuid,uuid) from public,anon,authenticated;
do $$declare s text;at_end integer;begin
 s:=pg_get_functiondef('app_private.save_purchase_lines(uuid,uuid,jsonb)'::regprocedure);
 at_end:=strpos(s,E'\nend $function$');
 -- The inspected function ends its PL/pgSQL body with "end $function$".
 if at_end<1 then raise exception 'Unexpected purchase line function definition';end if;
 s:=overlay(s placing 'update public.purchase_items pi set shell_unit_cost=case when x.value->>''shell_unit_cost'' is null then null else app_private.purchase_money((x.value->>''shell_unit_cost'')::numeric) end from jsonb_array_elements(p_lines) x where pi.tenant_id=p_tenant and pi.purchase_id=p_purchase and pi.item_id=(x.value->>''item_id'')::uuid and pi.type::text=x.value->>''type'';
 ' from at_end for 0);
 execute s;
 s:=pg_get_functiondef('public.receive_purchase(uuid,integer)'::regprocedure);
 s:=replace(s,'if p.status=''received'' then return jsonb_build_object(''already_received'',true); end if;','if p.status=''received'' then return jsonb_build_object(''already_received'',true); end if; perform 1 from public.items where tenant_id=t and brand_id=p.brand_id order by item_id for update; perform app_private.snapshot_purchase_shells(t,p_purchase_id);');execute s;
 s:=pg_get_functiondef('public.create_pos_sale(character varying,character varying,character varying,text,character varying,numeric,numeric,text,jsonb,uuid,uuid,jsonb,jsonb)'::regprocedure);
 s:=replace(s,'sum(case when category=''lpg'' and l.value->>''type''=''package'' then -(l.value->>''quantity'')::numeric
      else 0 end)', '0::numeric');
 s:=replace(s,'empty_delta:=case when category=''lpg'' then -qty else 0 end;','empty_delta:=0;');
 s:=replace(s,'if category=''lpg'' then perform app_private.receive_sale_bottles(t,sale,bottles,''checkout'',p_request_id);end if;','');
 s:=replace(s,'filled_quantity_change,empty_quantity_change,notes,created_by)', 'filled_quantity_change,empty_quantity_change,notes,created_by,valuation)');
 s:=replace(s,'''POS Sale #''||left(sale::text,8),actor);','''POS Sale #''||left(sale::text,8),actor,jsonb_build_object(''sale_type'',x->>''type''));');
 s:=replace(s,'insert into public.customer_transactions(tenant_id,customer_id,type,amount,reference_id,created_by)', 'if category=''lpg'' then perform app_private.receive_sale_bottles(t,sale,bottles,''checkout'',p_request_id);end if;
 insert into public.customer_transactions(tenant_id,customer_id,type,amount,reference_id,created_by)');execute s;
end $$;
drop trigger recognize_bottle_asset on public.sale_items;
drop function app_private.recognize_bottle_asset();

create function app_private.fifo_cost_movement(m public.inventory_movements) returns void language plpgsql set search_path='' as $$
declare c public.inventory_costs;p public.purchases;old_cost app_private.fifo_movement_costs;
 cat text;account text;counter text:='cogs';fc numeric:=0;ec numeric:=0;gross numeric:=0;rebate numeric:=0;gain numeric:=0;
 invoice numeric;total_invoice numeric;total_qty integer;last_line boolean;empty_cost numeric;asset_value numeric;before_qty integer;shell numeric:=0;issued_shell numeric:=0;
 d date:=(m.created_at at time zone 'Asia/Dhaka')::date;lines jsonb;f_after numeric;e_after numeric;batch record;
begin
 select * into c from public.inventory_costs where tenant_id=m.tenant_id and item_id=m.item_id for update;
 select business_category into cat from public.items where tenant_id=m.tenant_id and item_id=m.item_id;
 account:=case when cat='stove' then 'inventory_stove' else 'inventory_lpg' end;
 select * into old_cost from app_private.fifo_movement_costs where tenant_id=m.tenant_id and movement_id=m.movement_id;
 if m.reference_type='stove_purchase_cancellation' then
  for batch in select l.* from app_private.fifo_layers l join public.inventory_movements im using(tenant_id,movement_id) where l.tenant_id=m.tenant_id and l.item_id=m.item_id and im.reference_id=m.reference_id and im.reference_type='stove_purchase_receipt' for update of l loop
   if batch.remaining<>batch.quantity then raise exception 'Purchase stock batch has been consumed; it cannot be cancelled';end if;
   fc:=fc-batch.remaining_value;
   insert into app_private.fifo_consumptions values(m.tenant_id,m.movement_id,batch.layer_id,batch.remaining,batch.remaining_value,batch.remaining_shell_value);
   update app_private.fifo_layers set remaining=0,remaining_value=0,remaining_shell_value=0 where tenant_id=m.tenant_id and layer_id=batch.layer_id;
  end loop;
 elsif m.filled_quantity_change<0 then fc:=-app_private.fifo_take(m.tenant_id,m.item_id,m.movement_id,'filled',-m.filled_quantity_change);end if;
 if m.empty_quantity_change<0 then ec:=-app_private.fifo_take(m.tenant_id,m.item_id,m.movement_id,'empty',-m.empty_quantity_change);end if;
 empty_cost:=c.empty_unit_cost;
 if m.reference_type in ('purchase_receipt_new','purchase_receipt_refill','stove_purchase_receipt') then
  select * into p from public.purchases where tenant_id=m.tenant_id and purchase_id=m.reference_id;
  select sum(billed_quantity*unit_price) into invoice from public.purchase_items where tenant_id=m.tenant_id and purchase_id=m.reference_id and item_id=m.item_id and type=case when m.reference_type='purchase_receipt_refill' then 'refill'::public.purchase_type else 'package'::public.purchase_type end;
  select sum(quantity),sum(billed_quantity*unit_price) into total_qty,total_invoice from public.purchase_items where tenant_id=m.tenant_id and purchase_id=m.reference_id;
  gross:=round(coalesce(invoice,0)+case when total_invoice>0 then p.labour_cost*invoice/total_invoice else p.labour_cost*m.filled_quantity_change/nullif(total_qty,0) end,2);
  if cat='lpg' then
   select round(coalesce(rate,0)*m.filled_quantity_change,2) into rebate from public.monthly_commission_rates where tenant_id=m.tenant_id and item_id=m.item_id and month=date_trunc('month',coalesce(p.received_at,m.created_at) at time zone 'Asia/Dhaka')::date;
   rebate:=coalesce(rebate,0);
  end if;
  -- Last receipt absorbs only landed-cost rounding, never another product's rebate.
  last_line:=total_qty=(select coalesce(sum(x.filled_quantity_change),0) from public.inventory_movements x where x.tenant_id=m.tenant_id and x.reference_id=m.reference_id and x.reference_type in ('purchase_receipt_new','purchase_receipt_refill','stove_purchase_receipt') and (x.created_at,x.movement_no)<=(m.created_at,m.movement_no));
  if last_line then gross:=p.subtotal+p.labour_cost-coalesce((select sum((pi.billed_quantity*pi.unit_price)+case when total_invoice>0 then round(p.labour_cost*pi.billed_quantity*pi.unit_price/total_invoice,2) else round(p.labour_cost*pi.quantity/nullif(total_qty,0),2) end) from public.purchase_items pi where pi.tenant_id=m.tenant_id and pi.purchase_id=m.reference_id and not(pi.item_id=m.item_id and pi.type=case when m.reference_type='purchase_receipt_refill' then 'refill'::public.purchase_type else 'package'::public.purchase_type end)),0);end if;
  fc:=gross-rebate;
  if m.reference_type='purchase_receipt_refill' then
   select coalesce(-sum(x.empty_value),0) into ec from app_private.fifo_movement_costs x join public.inventory_movements im using(tenant_id,movement_id) where x.tenant_id=m.tenant_id and x.item_id=m.item_id and im.reference_id=m.reference_id and im.reference_type='purchase_dispatch';
   -- A returned filled cylinder carries the dispatched shell exactly once.
   shell:=ec;fc:=fc+ec;ec:=0;
  elsif cat='lpg' then
   select round(coalesce(max(shell_unit_cost),0)*m.filled_quantity_change,2) into shell from public.purchase_items where tenant_id=m.tenant_id and purchase_id=m.reference_id and item_id=m.item_id and type='package';
  end if;counter:='inventory_transit';
 elsif m.reference_type='stove_purchase_cancellation' then
  -- A specific batch may be cancelled only while entirely unconsumed.
  counter:='inventory_transit';
 elsif m.reference_type='purchase_dispatch' then counter:='inventory_transit';
 elsif m.reference_type='purchase_cancellation' then
  select coalesce(-sum(x.empty_value),0) into ec from app_private.fifo_movement_costs x join public.inventory_movements im using(tenant_id,movement_id) where x.tenant_id=m.tenant_id and x.item_id=m.item_id and im.reference_id=m.reference_id and im.reference_type='purchase_dispatch';counter:='inventory_transit';
 elsif m.valuation->>'counter_account' is not null then
  counter:=m.valuation->>'counter_account';
  if counter not in ('opening_equity','inventory_loss','other_income','capital') then raise exception 'Invalid stock adjustment classification';end if;
  if m.filled_quantity_change>0 then fc:=round(m.filled_quantity_change*app_private.purchase_money((m.valuation->>'filled_unit_cost')::numeric),2);end if;
  if m.empty_quantity_change>0 then ec:=round(m.empty_quantity_change*app_private.purchase_money((m.valuation->>'empty_unit_cost')::numeric),2);end if;
  if cat='lpg' and m.filled_quantity_change>0 then shell:=least(fc,round(m.filled_quantity_change*coalesce((m.valuation->>'filled_shell_unit_cost')::numeric,(m.valuation->>'empty_unit_cost')::numeric,empty_cost,0),2));end if;
 elsif m.reference_type='sale' then
  if m.filled_quantity_change<0 and cat='lpg' and m.valuation->>'sale_type'='refill' then
   select coalesce(sum(x.shell_value),0) into issued_shell from app_private.fifo_consumptions x join app_private.fifo_layers l using(tenant_id,layer_id) where x.tenant_id=m.tenant_id and x.movement_id=m.movement_id and l.component='filled';
   perform app_private.sync_journal(m.tenant_id,'bottle_obligation',m.movement_id,d,'FIFO shell retained with customer',jsonb_build_array(app_private.accounting_line('bottle_receivable',issued_shell,'lpg',m.reference_id),app_private.accounting_line('cogs',-issued_shell,'lpg')));
  end if;
  if m.empty_quantity_change>0 then
   select greatest(0,coalesce(sum(l.amount),0)-coalesce((select sum(x.empty_value) from app_private.fifo_movement_costs x join public.inventory_movements im using(tenant_id,movement_id) where im.tenant_id=m.tenant_id and im.reference_id=m.reference_id and im.reference_type='sale' and im.empty_quantity_change>0 and (im.created_at,im.movement_no)<(m.created_at,m.movement_no)),0)) into asset_value from public.accounting_lines l join public.accounting_journals j using(tenant_id,journal_id) where l.tenant_id=m.tenant_id and l.account='bottle_receivable' and l.entity_id=m.reference_id and j.source='bottle_obligation';
   select greatest(0,coalesce((select sum(quantity) from public.sale_items where tenant_id=m.tenant_id and sale_id=m.reference_id and type='empty_return'),0)-coalesce((select sum(im.empty_quantity_change) from public.inventory_movements im where im.tenant_id=m.tenant_id and im.reference_type='sale' and im.reference_id=m.reference_id and im.empty_quantity_change>0 and (im.created_at,im.movement_no)<(m.created_at,m.movement_no)),0)) into before_qty;
   ec:=case when before_qty>0 then round(asset_value*least(before_qty,m.empty_quantity_change)/before_qty,2) else 0 end;
   if m.empty_quantity_change>before_qty and empty_cost is null then raise exception 'Record a verified cylinder value before accepting excess bottles';end if;
   gain:=round(greatest(0,m.empty_quantity_change-before_qty)*coalesce(empty_cost,0),2);ec:=ec+gain;counter:='bottle_receivable';
  end if;
 elsif m.reference_type='sale_reversal' then
  issued_shell:=ec;
  select -coalesce(sum(x.filled_value),0),-coalesce(sum(x.empty_value),0) into fc,ec from app_private.fifo_movement_costs x join public.inventory_movements im using(tenant_id,movement_id) where x.tenant_id=m.tenant_id and x.item_id=m.item_id and im.reference_id=m.reference_id and im.reference_type='sale';
  if m.empty_quantity_change<0 and issued_shell<>ec then raise exception 'Returned cylinder stock has been consumed; original carrying value cannot be reversed';end if;
  select coalesce(sum(x.shell_value),0) into shell from app_private.fifo_consumptions x join public.inventory_movements im on im.tenant_id=x.tenant_id and im.movement_id=x.movement_id join app_private.fifo_layers l on l.tenant_id=x.tenant_id and l.layer_id=x.layer_id where im.tenant_id=m.tenant_id and im.item_id=m.item_id and im.reference_id=m.reference_id and im.reference_type='sale' and l.component='filled';
  -- Returned goods restore their original batches and FIFO age. Negative
  -- consumption links retain when the goods became available again.
  for batch in select x.* from app_private.fifo_consumptions x join public.inventory_movements im on im.tenant_id=x.tenant_id and im.movement_id=x.movement_id join app_private.fifo_layers l on l.tenant_id=x.tenant_id and l.layer_id=x.layer_id where im.tenant_id=m.tenant_id and im.item_id=m.item_id and im.reference_id=m.reference_id and im.reference_type='sale' and im.filled_quantity_change<0 and l.component='filled' loop
   update app_private.fifo_layers set remaining=remaining+batch.quantity,remaining_value=remaining_value+batch.value,remaining_shell_value=remaining_shell_value+batch.shell_value where tenant_id=m.tenant_id and layer_id=batch.layer_id;
   insert into app_private.fifo_consumptions values(m.tenant_id,m.movement_id,batch.layer_id,-batch.quantity,-batch.value,-batch.shell_value)
   on conflict(tenant_id,movement_id,layer_id) do update set quantity=fifo_consumptions.quantity+excluded.quantity,value=fifo_consumptions.value+excluded.value,shell_value=fifo_consumptions.shell_value+excluded.shell_value;
  end loop;
 else raise exception 'Stock movement requires recorded acquisition evidence';end if;
 if fc is null or ec is null then raise exception 'Missing FIFO acquisition cost';end if;
 if m.reference_type<>'sale_reversal' or m.reference_type is null then perform app_private.fifo_add(m.tenant_id,m.item_id,m.movement_id,'filled',m.created_at,m.filled_quantity_change,fc,shell);end if;
 perform app_private.fifo_add(m.tenant_id,m.item_id,m.movement_id,'empty',m.created_at,m.empty_quantity_change,ec);
 f_after:=c.filled_value+fc;e_after:=c.empty_value+ec;
 update public.inventory_costs set filled_quantity=filled_quantity+m.filled_quantity_change,empty_quantity=empty_quantity+m.empty_quantity_change,filled_value=f_after,empty_value=e_after,
 empty_unit_cost=case when m.empty_quantity_change>0 then ec/m.empty_quantity_change else empty_unit_cost end where tenant_id=m.tenant_id and item_id=m.item_id;
 if old_cost.movement_id is null then
  insert into public.inventory_cost_entries(tenant_id,item_id,movement_id,occurred_on,filled_change,empty_change,filled_value,empty_value,filled_after,empty_after,reason,estimated,created_by)
  values(m.tenant_id,m.item_id,m.movement_id,d,m.filled_quantity_change,m.empty_quantity_change,fc,ec,f_after,e_after,coalesce(m.notes,'FIFO stock movement'),c.estimated,m.created_by);
 elsif old_cost.filled_value<>fc or old_cost.empty_value<>ec then
  insert into public.inventory_cost_entries(tenant_id,item_id,occurred_on,filled_change,empty_change,filled_value,empty_value,filled_after,empty_after,reason,estimated,created_by)
  values(m.tenant_id,m.item_id,d,0,0,fc-old_cost.filled_value,ec-old_cost.empty_value,f_after,e_after,'FIFO revaluation of '||m.movement_id,c.estimated,auth.uid());
 end if;
 insert into app_private.fifo_movement_costs values(m.tenant_id,m.movement_id,m.item_id,m.created_at,fc,ec) on conflict(tenant_id,movement_id) do update set filled_value=excluded.filled_value,empty_value=excluded.empty_value;
 lines:=jsonb_build_array(app_private.accounting_line(account,fc+ec,cat,m.item_id),app_private.accounting_line(counter,-fc-ec-rebate+gain,cat,m.reference_id),app_private.accounting_line('supplier_receivable',rebate,cat,(select brand_id from public.items where tenant_id=m.tenant_id and item_id=m.item_id)),app_private.accounting_line('other_income',-gain,cat));
 perform app_private.sync_journal(m.tenant_id,'inventory',m.movement_id,d,coalesce(m.notes,'FIFO carrying cost'),lines,counter='opening_equity');
end $$;

create function app_private.rebuild_fifo_set(t uuid,ids uuid[]) returns void language plpgsql set search_path='' as $$declare m public.inventory_movements;begin
 -- Callers already hold item locks in UUID order. Never acquire a purchase or
 -- snapshot lock here: journal invalidation is always the final lock boundary.
 perform 1 from public.items where tenant_id=t and item_id=any(ids) order by item_id for update;
 delete from app_private.fifo_consumptions where tenant_id=t and layer_id in(select layer_id from app_private.fifo_layers where tenant_id=t and item_id=any(ids));
 delete from app_private.fifo_layers where tenant_id=t and item_id=any(ids);
 update public.inventory_costs set filled_quantity=0,empty_quantity=0,filled_value=0,empty_value=0 where tenant_id=t and item_id=any(ids);
 for m in select im.* from public.inventory_movements im where im.tenant_id=t and im.item_id=any(ids) order by im.created_at,case when im.reference_type='sale' then (select min(x.movement_no) from public.inventory_movements x where x.tenant_id=t and x.reference_type='sale' and x.reference_id=im.reference_id) else im.movement_no end,case when im.reference_type='sale' and im.filled_quantity_change<0 then 0 else 1 end,im.movement_no loop perform app_private.fifo_cost_movement(m);end loop;
end $$;
create function app_private.rebuild_fifo(t uuid,id uuid) returns void language sql set search_path='' as $$select app_private.rebuild_fifo_set(t,array[id]);$$;

create or replace function app_private.cost_inventory_movement() returns trigger language plpgsql set search_path='' as $$begin
 if exists(select 1 from app_private.fifo_movement_costs f join public.inventory_movements im using(tenant_id,movement_id) where f.tenant_id=new.tenant_id and f.item_id=new.item_id and (f.occurred_at,im.movement_no)>(new.created_at,new.movement_no)) then
  perform app_private.rebuild_fifo_set(new.tenant_id,(select array_agg(item_id order by item_id) from public.items where tenant_id=new.tenant_id));
 else perform app_private.fifo_cost_movement(new);end if;return new;end $$;

create function app_private.infer_monthly_commissions(t uuid,brand uuid,period date) returns uuid[] language plpgsql set search_path='' as $$
declare deducted numeric;manual_total numeric;basis numeric;r record;next_rate numeric;prev public.monthly_commission_rates;calculation jsonb;affected uuid[]:='{}';begin
 select coalesce(sum(d.amount),0) into deducted from public.monthly_commission_deductions d join public.purchases p using(tenant_id,purchase_id) where d.tenant_id=t and p.brand_id=brand and d.earned_month=period;
 select coalesce(sum(pi.received_quantity*mr.rate) filter(where mr.source='manual'),0),coalesce(sum(pi.received_quantity*i.size_kg) filter(where mr.source is distinct from 'manual'),0)
 into manual_total,basis from public.purchases p join public.purchase_items pi using(tenant_id,purchase_id) join public.items i using(tenant_id,item_id)
 left join public.monthly_commission_rates mr on mr.tenant_id=i.tenant_id and mr.item_id=i.item_id and mr.month=period
 where p.tenant_id=t and p.brand_id=brand and p.business_category='lpg' and i.business_category='lpg' and p.status='received' and p.received_at>=period::timestamp at time zone 'Asia/Dhaka' and p.received_at<(period+interval '1 month')::timestamp at time zone 'Asia/Dhaka';
 for r in select distinct i.item_id,i.size_kg from public.purchases p join public.purchase_items pi using(tenant_id,purchase_id) join public.items i using(tenant_id,item_id) where p.tenant_id=t and p.brand_id=brand and p.status='received' and p.business_category='lpg' and i.business_category='lpg' and pi.received_quantity>0 and p.received_at>=period::timestamp at time zone 'Asia/Dhaka' and p.received_at<(period+interval '1 month')::timestamp at time zone 'Asia/Dhaka' order by i.item_id loop
  select * into prev from public.monthly_commission_rates where tenant_id=t and item_id=r.item_id and month=period;
  if prev.source='manual' then continue;end if;
  next_rate:=round(greatest(0,deducted-manual_total)*r.size_kg/nullif(basis,0),6);
  calculation:=jsonb_build_object('deductions',deducted,'manual_earned',manual_total,'unrated_kg',basis,'weight_kg',r.size_kg,'provisional',true,'basis','cumulative deductions; lower bound, not final monthly entitlement');
  if prev.rate is not distinct from next_rate and prev.calculation=calculation then continue;end if;
  insert into public.monthly_commission_rates(tenant_id,item_id,month,rate,source,calculation,modified_by) values(t,r.item_id,period,coalesce(next_rate,0),'inferred_partial',calculation,auth.uid())
  on conflict(tenant_id,item_id,month) do update set rate=excluded.rate,calculation=excluded.calculation,revision=monthly_commission_rates.revision+1,modified_by=excluded.modified_by,modified_at=clock_timestamp() where monthly_commission_rates.source<>'manual';
  if prev.rate is distinct from next_rate then affected:=array_append(affected,r.item_id);end if;
  insert into public.monthly_commission_history(tenant_id,item_id,month,rate,source,calculation,revision,reason,modified_by)
  select mr.tenant_id,mr.item_id,mr.month,mr.rate,mr.source,mr.calculation,mr.revision,'Cumulative supplier deductions; provisional lower-bound rate',auth.uid() from public.monthly_commission_rates mr where mr.tenant_id=t and mr.item_id=r.item_id and mr.month=period;
 end loop;return affected;
end $$;

-- Deductions settle prior earned rebates; they never discount the new batch.
insert into public.accounting_accounts values('commission_pending','Supplier commission deductions pending receipt','liability');
do $$declare s text;begin
 s:=pg_get_functiondef('app_private.source_accounting()'::regprocedure);
 s:=replace(s,'app_private.accounting_line(''inventory_transit'',a,cat,id),app_private.accounting_line(''supplier_payable'',-a,cat,id)',
 'app_private.accounting_line(''inventory_transit'',case when new.status in (''in_transit'',''received'') then new.subtotal+new.labour_cost else 0 end,cat,id),app_private.accounting_line(''supplier_payable'',-a,cat,id),app_private.accounting_line(case when new.status=''received'' then ''supplier_receivable'' else ''commission_pending'' end,case when new.status in (''in_transit'',''received'') then -new.commission else 0 end,cat,case when new.status=''received'' then new.brand_id else id end)');
 execute s;
end $$;

create function app_private.receive_monthly_commission() returns trigger language plpgsql set search_path='' as $$
declare period date;r record;affected uuid[];begin
 if new.status<>'received' or new.business_category<>'lpg' then return new;end if;
 if old.status='received' then return new;end if;
 period:=(date_trunc('month',new.received_at at time zone 'Asia/Dhaka')-interval '1 month')::date;
 -- Lock all affected SKUs before source journals acquire savepoint state.
 perform 1 from public.items where tenant_id=new.tenant_id and brand_id=new.brand_id order by item_id for update;
 if new.commission>0 then
  insert into public.monthly_commission_deductions(tenant_id,purchase_id,earned_month,received_on,amount,modified_by) values(new.tenant_id,new.purchase_id,period,(new.received_at at time zone 'Asia/Dhaka')::date,new.commission,auth.uid());
  insert into public.monthly_commission_deduction_history(tenant_id,purchase_id,earned_month,amount,reason,modified_by) values(new.tenant_id,new.purchase_id,period,new.commission,'Deduction on actual receipt; prior calendar month',auth.uid());
 end if;
 affected:=app_private.infer_monthly_commissions(new.tenant_id,new.brand_id,period)||app_private.infer_monthly_commissions(new.tenant_id,new.brand_id,date_trunc('month',new.received_at at time zone 'Asia/Dhaka')::date);
 for r in select distinct unnest(affected) item_id order by item_id loop perform app_private.rebuild_fifo(new.tenant_id,r.item_id);end loop;
 return new;end $$;
-- Before purchase source accounting; same transaction invalidates all affected months.
create trigger aa_monthly_commission after update of status on public.purchases for each row execute function app_private.receive_monthly_commission();

create function public.get_monthly_commissions(p_item_id uuid,p_month date,p_offset integer default 0) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare t uuid:=app_private.require_any_permission(array['inventory:view','inventory:manage']);r jsonb;begin
 if p_month is null or not isfinite(p_month) or p_month<>date_trunc('month',p_month)::date or p_offset is null or p_offset<0 then raise exception 'Invalid commission month or history page';end if;
 if not exists(select 1 from public.items where tenant_id=t and item_id=p_item_id and business_category='lpg') then raise exception 'Eligible LPG product not found';end if;
 select jsonb_build_object('current',(select to_jsonb(c) from public.monthly_commission_rates c where tenant_id=t and item_id=p_item_id and month=p_month),
 'quantity',coalesce((select sum(pi.received_quantity) from public.purchase_items pi join public.purchases p using(tenant_id,purchase_id) where pi.tenant_id=t and pi.item_id=p_item_id and p.status='received' and p.received_at>=p_month::timestamp at time zone 'Asia/Dhaka' and p.received_at<(p_month+interval '1 month')::timestamp at time zone 'Asia/Dhaka'),0),
 'total',(select count(*) from public.monthly_commission_history where tenant_id=t and item_id=p_item_id and month=p_month),
 'entries',coalesce((select jsonb_agg(to_jsonb(h)) from(select h.*,coalesce(u.full_name,'System inference') actor from public.monthly_commission_history h left join public.user_profiles u on u.user_id=h.modified_by where h.tenant_id=t and h.item_id=p_item_id and h.month=p_month order by h.revision desc offset p_offset limit 10)h),'[]')) into r;return r;end $$;

create function public.set_monthly_commission(p_payload jsonb,p_request_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_owner('inventory:manage');id uuid:=(p_payload->>'item_id')::uuid;period date:=(p_payload->>'month')::date;
 rate numeric:=(p_payload->>'rate')::numeric;prev public.monthly_commission_rates;prior public.finance_requests;brand uuid;r record;result jsonb;
 affected uuid[];body jsonb:=jsonb_build_object('action','monthly_commission','actor',auth.uid(),'body',p_payload);begin
 if p_request_id is null or period is null or not isfinite(period) or period<>date_trunc('month',period)::date or period>date_trunc('month',now() at time zone 'Asia/Dhaka')::date or rate is null or rate<0 or rate>=10000000000 or rate::text in ('NaN','Infinity','-Infinity') or rate<>round(rate,6) or length(trim(coalesce(p_payload->>'reason',''))) not between 3 and 1000 then raise exception 'Enter a valid month, rate and reason';end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from body then raise exception 'Request ID already used with different details';end if;return prior.result;end if;
 select brand_id into brand from public.items where tenant_id=t and item_id=id and business_category='lpg';if not found then raise exception 'Eligible LPG product not found';end if;
 perform 1 from public.items where tenant_id=t and brand_id=brand order by item_id for update;
 select * into prev from public.monthly_commission_rates where tenant_id=t and item_id=id and month=period;
 if coalesce(prev.revision,0) is distinct from (p_payload->>'expected_revision')::integer then raise exception 'Monthly commission changed. Reload before saving.';end if;
 insert into public.monthly_commission_rates(tenant_id,item_id,month,rate,source,calculation,modified_by) values(t,id,period,rate,'manual',jsonb_build_object('reason',p_payload->>'reason'),auth.uid())
 on conflict(tenant_id,item_id,month) do update set rate=excluded.rate,source='manual',calculation=excluded.calculation,revision=monthly_commission_rates.revision+1,modified_by=auth.uid(),modified_at=clock_timestamp();
 insert into public.monthly_commission_history(tenant_id,item_id,month,rate,source,calculation,revision,reason,modified_by)
 select mr.tenant_id,mr.item_id,mr.month,mr.rate,mr.source,mr.calculation,mr.revision,p_payload->>'reason',auth.uid() from public.monthly_commission_rates mr where mr.tenant_id=t and mr.item_id=id and mr.month=period;
 affected:=app_private.infer_monthly_commissions(t,brand,period)||array[id];
 for r in select distinct unnest(affected) item_id order by item_id loop perform app_private.rebuild_fifo(t,r.item_id);end loop;
 result:=jsonb_build_object('saved',true);insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,result,auth.uid());return result;end $$;

-- Explicit grants; all writes use owner/tenant gates. No private layer access.
do $$declare n text;begin
 foreach n in array array['monthly_commission_rates','monthly_commission_history','monthly_commission_deductions','monthly_commission_deduction_history'] loop
  execute format('alter table public.%I enable row level security',n);execute format('revoke all on public.%I from public,anon,authenticated',n);
 end loop;
 foreach n in array array['fifo_layers','fifo_consumptions','fifo_movement_costs'] loop execute format('alter table app_private.%I enable row level security',n);execute format('revoke all on app_private.%I from public,anon,authenticated',n);end loop;
end $$;
create trigger immutable_monthly_commission_history before update or delete on public.monthly_commission_history for each row execute function app_private.immutable_finance_record();
create trigger immutable_monthly_deduction_history before update or delete on public.monthly_commission_deduction_history for each row execute function app_private.immutable_finance_record();
revoke all on function public.get_monthly_commissions(uuid,date,integer),public.set_monthly_commission(jsonb,uuid) from public,anon;
grant execute on function public.get_monthly_commissions(uuid,date,integer),public.set_monthly_commission(jsonb,uuid) to authenticated;
revoke all on function app_private.fifo_take(uuid,uuid,uuid,text,integer),app_private.fifo_add(uuid,uuid,uuid,text,timestamptz,integer,numeric,numeric),app_private.fifo_cost_movement(public.inventory_movements),app_private.rebuild_fifo(uuid,uuid),app_private.infer_monthly_commissions(uuid,uuid,date),app_private.receive_monthly_commission() from public,anon,authenticated;
alter function app_private.fifo_take(uuid,uuid,uuid,text,integer) owner to postgres;
alter function app_private.fifo_add(uuid,uuid,uuid,text,timestamptz,integer,numeric,numeric) owner to postgres;
alter function app_private.fifo_cost_movement(public.inventory_movements) owner to postgres;
alter function app_private.rebuild_fifo(uuid,uuid) owner to postgres;
alter function app_private.rebuild_fifo_set(uuid,uuid[]) owner to postgres;
revoke all on function app_private.rebuild_fifo_set(uuid,uuid[]) from public,anon,authenticated;
alter function app_private.infer_monthly_commissions(uuid,uuid,date) owner to postgres;
alter function app_private.receive_monthly_commission() owner to postgres;
alter function public.get_monthly_commissions(uuid,date,integer) owner to postgres;
alter function public.set_monthly_commission(jsonb,uuid) owner to postgres;
alter table public.monthly_commission_rates owner to postgres;
alter table public.monthly_commission_history owner to postgres;
alter table public.monthly_commission_deductions owner to postgres;
alter table public.monthly_commission_deduction_history owner to postgres;
alter table app_private.fifo_layers owner to postgres;
alter table app_private.fifo_consumptions owner to postgres;
alter table app_private.fifo_movement_costs owner to postgres;

-- Development normalization: old estimates remain operational references only;
-- they cannot be promoted into historical entitlements without evidence.
insert into public.monthly_commission_deductions(tenant_id,purchase_id,earned_month,received_on,amount,modified_by)
select tenant_id,purchase_id,(date_trunc('month',received_at at time zone 'Asia/Dhaka')-interval '1 month')::date,(received_at at time zone 'Asia/Dhaka')::date,commission,created_by from public.purchases where status='received' and business_category='lpg' and commission>0;
insert into public.monthly_commission_deduction_history(tenant_id,purchase_id,earned_month,amount,reason,modified_by)
select tenant_id,purchase_id,earned_month,amount,'Migrated actual received deduction; entitlement remains provisional',modified_by from public.monthly_commission_deductions;
do $$declare r record;s jsonb;d date;begin
 -- Replace estimated shell receivables with the issued FIFO shells, retaining
 -- original journals and appending corrections at their original business date.
 for r in select j.tenant_id,j.source_id,min(j.occurred_on) d,jsonb_agg(app_private.accounting_line(l.account,l.amount,l.business_category,l.entity_id)) lines from public.accounting_journals j join public.accounting_lines l using(tenant_id,journal_id) where j.source='bottle_obligation' group by j.tenant_id,j.source_id loop
  insert into app_private.accounting_source_state(tenant_id,source,source_id,lines) values(r.tenant_id,'bottle_obligation',r.source_id,r.lines) on conflict do nothing;
  perform app_private.sync_journal(r.tenant_id,'bottle_obligation',r.source_id,r.d,'Replace shell estimate with issued FIFO acquisition evidence','[]');
 end loop;
 for r in select distinct p.tenant_id,p.brand_id,c.earned_month from public.monthly_commission_deductions c join public.purchases p using(tenant_id,purchase_id) order by p.tenant_id,p.brand_id,c.earned_month loop perform app_private.infer_monthly_commissions(r.tenant_id,r.brand_id,r.earned_month);end loop;
 -- Retain the original payable and reconstruct gross acquisition plus dated
 -- deduction settlement. No financial entries or payments are removed.
 for r in select * from public.purchases where status in ('in_transit','received') order by tenant_id,purchase_id loop
  d:=(coalesce(r.dispatched_at,r.created_at) at time zone 'Asia/Dhaka')::date;
  s:=jsonb_build_array(app_private.accounting_line('inventory_transit',r.subtotal+r.labour_cost,r.business_category,r.purchase_id),app_private.accounting_line('supplier_payable',-r.payable_amount,r.business_category,r.purchase_id),app_private.accounting_line('commission_pending',-r.commission,r.business_category,r.purchase_id));
  perform app_private.sync_journal(r.tenant_id,'purchase',r.purchase_id,d,'Gross acquisition; commission belongs to prior purchases',s);
  if r.status='received' then
   s:=jsonb_build_array(app_private.accounting_line('inventory_transit',r.subtotal+r.labour_cost,r.business_category,r.purchase_id),app_private.accounting_line('supplier_payable',-r.payable_amount,r.business_category,r.purchase_id),app_private.accounting_line('supplier_receivable',-r.commission,r.business_category,r.brand_id));
   perform app_private.sync_journal(r.tenant_id,'purchase',r.purchase_id,(r.received_at at time zone 'Asia/Dhaka')::date,'Commission deduction settlement at receipt',s);
  end if;
 end loop;
 for r in select tenant_id,array_agg(item_id order by item_id) ids from public.items group by tenant_id order by tenant_id loop perform app_private.rebuild_fifo_set(r.tenant_id,r.ids);end loop;
end $$;

do $$declare s text;begin
 s:=pg_get_functiondef('public.get_inventory_valuation()'::regprocedure);execute replace(s,'moving_weighted_average','fifo');
 s:=pg_get_functiondef('public.get_finance_analysis(jsonb)'::regprocedure);execute replace(replace(s,'moving_weighted_average','fifo'),'Moving weighted-average','FIFO');
end $$;

-- Current dues are orthogonal to the selected sales-activity period. Filter
-- candidates before paging so counts, name sorts and all cached batches agree.
create function app_private.customer_dues_kind(t uuid,c uuid) returns text language sql stable set search_path='' as $$
 with balances as(select coalesce((select -ledger_balance>0 from app_private.customer_metrics where tenant_id=t and customer_id=c),false) payment,
 exists(select 1 from public.sales s where s.tenant_id=t and s.customer_id=c and s.status='completed' and
 (select coalesce(sum(quantity),0) from public.sale_items where tenant_id=t and sale_id=s.sale_id and type='empty_return')>
 (select coalesce(sum(quantity),0) from public.sale_bottle_receipt_lines where tenant_id=t and sale_id=s.sale_id)) bottle)
 select case when payment and bottle then 'both' when payment then 'payment' when bottle then 'bottle' else 'none' end from balances;$$;
alter function app_private.customer_dues_kind(uuid,uuid) owner to postgres;
revoke all on function app_private.customer_dues_kind(uuid,uuid) from public,anon,authenticated;
do $$declare s text;begin
 s:=pg_get_functiondef('public.get_customer_directory(jsonb,integer,integer,uuid)'::regprocedure);
 s:=replace(s,'perform app_private.validate_customer_filters(p_filters);','perform app_private.validate_customer_filters(p_filters); if coalesce(p_filters->>''dues'',''all'') not in (''all'',''payment'',''bottle'',''both'',''none'') then raise exception ''Invalid customer dues filter'';end if;');
 s:=replace(s,'from public.customers c where c.tenant_id=t and (p_customer_id', 'from public.customers c where c.tenant_id=t and (coalesce(p_filters->>''dues'',''all'')=''all'' or app_private.customer_dues_kind(t,c.customer_id)=p_filters->>''dues'') and (p_customer_id');
 execute s;
 -- Every cash adjustment has exactly one classified journal counter-account.
 s:=pg_get_functiondef('public.move_wallet_money(jsonb,uuid)'::regprocedure);
 s:=replace(s,'if dest is not null then raise exception ''Adjustments cannot have a destination''; end if;',
 'if dest is not null then raise exception ''Adjustments cannot have a destination''; end if;
 if coalesce(p_payload->>''classification'',''correction'') not in (''correction'',''opening'',''capital'') then raise exception ''Invalid balance adjustment classification'';end if;
 if p_payload->>''classification'' in (''opening'',''capital'') then perform app_private.require_owner(''finance:manage'');if amount<0 then raise exception ''Opening funds and capital must be positive'';end if;end if;
 if p_payload->>''date'' is not null and (not isfinite((p_payload->>''date'')::date) or (p_payload->>''date'')::date>(now() at time zone ''Asia/Dhaka'')::date) then raise exception ''Invalid adjustment date'';end if;');
 s:=replace(s,'insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,description,operation_id) values(t,src,amount,''balance_adjustment'',reason,p_request_id);',
 'insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,description,operation_id,accounting_date) values(t,src,amount,case p_payload->>''classification'' when ''opening'' then ''opening_cash'' when ''capital'' then ''owner_capital'' else ''balance_adjustment'' end,reason,p_request_id,coalesce((p_payload->>''date'')::date,(now() at time zone ''Asia/Dhaka'')::date));');
 execute s;
end $$;

do $$declare s text;begin
 s:=pg_get_functiondef('public.get_product_inventory(uuid)'::regprocedure);
 s:=replace(s,'select refill_commission_per_unit,package_commission_per_unit,rate_id
      from public.product_commission_rates where tenant_id=t and item_id=p_item_id
      order by created_at desc,rate_id desc limit 1',
 'select rate refill_commission_per_unit,rate package_commission_per_unit,null::uuid rate_id from public.monthly_commission_rates where tenant_id=t and item_id=p_item_id and month=date_trunc(''month'',now() at time zone ''Asia/Dhaka'')::date');execute s;
end $$;
drop function public.set_product_commissions(uuid,numeric,numeric,uuid);

-- Actual business dates are separate from when an operator entered the record.
alter table public.purchases add column commission_month date check(commission_month=date_trunc('month',commission_month)::date and isfinite(commission_month));
update public.purchases p set commission_month=d.earned_month from public.monthly_commission_deductions d where d.tenant_id=p.tenant_id and d.purchase_id=p.purchase_id;
do $$declare s text;begin
 s:=pg_get_functiondef('public.receive_purchase(uuid,integer)'::regprocedure);
 s:=replace(s,'public.receive_purchase(p_purchase_id uuid, p_revision integer)','public.receive_purchase(p_purchase_id uuid, p_revision integer, p_received_on date DEFAULT NULL, p_commission_month date DEFAULT NULL)');
 s:=replace(s,'p public.purchases; r record;', 'p public.purchases; r record; received_time timestamptz:=case when p_received_on is null then clock_timestamp() else (p_received_on+time ''12:00'') at time zone ''Asia/Dhaka'' end;');
 s:=replace(s,'if p.status=''received'' then return jsonb_build_object(''already_received'',true); end if;',
 'if p_received_on is not null and (not isfinite(p_received_on) or p_received_on>(now() at time zone ''Asia/Dhaka'')::date or p.business_category=''lpg'' and p_received_on<(p.dispatched_at at time zone ''Asia/Dhaka'')::date) then raise exception ''Receipt date must be finite, not future, and on or after dispatch'';end if;
 if p_commission_month is not null and (not isfinite(p_commission_month) or p_commission_month<>date_trunc(''month'',p_commission_month)::date or p_commission_month>date_trunc(''month'',received_time at time zone ''Asia/Dhaka'')::date) then raise exception ''Invalid earned commission month'';end if;
 if p.status=''received'' then if p_received_on is not null and p_received_on<>(p.received_at at time zone ''Asia/Dhaka'')::date or p_commission_month is not null and p_commission_month is distinct from p.commission_month then raise exception ''Shipment already received with different dates'';end if;return jsonb_build_object(''already_received'',true); end if;
 update public.purchases set commission_month=coalesce(p_commission_month,(date_trunc(''month'',received_time at time zone ''Asia/Dhaka'')-interval ''1 month'')::date) where tenant_id=t and purchase_id=p_purchase_id;');
 s:=replace(s,'filled_quantity_change,notes,created_by)', 'filled_quantity_change,notes,created_by,created_at)');
 s:=replace(s,'''Stove purchase received'',auth.uid());','''Stove purchase received'',auth.uid(),received_time);');
 s:=replace(s,'''Expected shipment received'',auth.uid());','''Expected shipment received'',auth.uid(),received_time);');
 s:=replace(s,'set status=''in_transit'' where', 'set status=''in_transit'',dispatched_at=received_time where');
 s:=replace(replace(s,'received_at=clock_timestamp()','received_at=received_time'),'received_at=now()','received_at=received_time');
 drop function public.receive_purchase(uuid,integer);execute s;
 s:=pg_get_functiondef('app_private.receive_monthly_commission()'::regprocedure);
 s:=replace(s,'period:=(date_trunc(''month'',new.received_at at time zone ''Asia/Dhaka'')-interval ''1 month'')::date;', 'period:=coalesce(new.commission_month,(date_trunc(''month'',new.received_at at time zone ''Asia/Dhaka'')-interval ''1 month'')::date);');execute s;
 s:=pg_get_functiondef('app_private.source_accounting()'::regprocedure);
 s:=replace(s,'if tg_op=''INSERT'' then d:=(coalesce(new.dispatched_at,new.created_at) at time zone ''Asia/Dhaka'')::date;end if;', 'd:=(case when new.status=''received'' then coalesce(new.received_at,new.dispatched_at,new.created_at) else coalesce(new.dispatched_at,new.created_at) end at time zone ''Asia/Dhaka'')::date;');execute s;
end $$;
alter function public.receive_purchase(uuid,integer,date,date) owner to postgres;
revoke all on function public.receive_purchase(uuid,integer,date,date) from public,anon;
grant execute on function public.receive_purchase(uuid,integer,date,date) to authenticated;

do $$declare s text;begin
 s:=pg_get_functiondef('public.adjust_inventory(jsonb,uuid)'::regprocedure);
 s:=replace(s,'if p_request_id is null then', 'if p_payload->>''date'' is not null and (not isfinite((p_payload->>''date'')::date) or (p_payload->>''date'')::date>(now() at time zone ''Asia/Dhaka'')::date) then raise exception ''Invalid stock accounting date'';end if; if p_request_id is null then');
 s:=replace(s,'notes,created_by,valuation)', 'notes,created_by,valuation,created_at)');
 s:=replace(s,'''empty_unit_cost'',p_payload->''empty_unit_cost'')) returning', '''empty_unit_cost'',p_payload->''empty_unit_cost''),coalesce(((p_payload->>''date'')::date+time ''12:00'') at time zone ''Asia/Dhaka'',clock_timestamp())) returning');execute s;
end $$;
do $$declare s text;begin
 s:=pg_get_functiondef('public.dispatch_purchase(uuid,integer)'::regprocedure);
 s:=replace(s,'public.dispatch_purchase(p_purchase_id uuid, p_revision integer)','public.dispatch_purchase(p_purchase_id uuid, p_revision integer, p_dispatched_on date DEFAULT NULL)');
 s:=replace(s,'tr public.vehicles; x record;', 'tr public.vehicles; x record; dispatch_time timestamptz:=case when p_dispatched_on is null then clock_timestamp() else (p_dispatched_on+time ''09:00'') at time zone ''Asia/Dhaka'' end;');
 s:=replace(s,'if not found then raise exception ''Purchase not found''; end if;', 'if not found then raise exception ''Purchase not found''; end if; if p_dispatched_on is not null and (not isfinite(p_dispatched_on) or p_dispatched_on>(now() at time zone ''Asia/Dhaka'')::date) then raise exception ''Invalid dispatch date'';end if;');
 s:=replace(s,'empty_quantity_change,notes,created_by)', 'empty_quantity_change,notes,created_by,created_at)');
 s:=replace(s,'''Empty cylinders dispatched to plant'',auth.uid());', '''Empty cylinders dispatched to plant'',auth.uid(),dispatch_time);');
 s:=replace(s,'dispatched_at=now()', 'dispatched_at=dispatch_time');
 s:=replace(s,'status,transport_fee)', 'status,transport_fee,created_at)');
 s:=replace(s,'''active'',p.transport_cost);', '''active'',p.transport_cost,dispatch_time);');
 drop function public.dispatch_purchase(uuid,integer);execute s;
end $$;
alter function public.dispatch_purchase(uuid,integer,date) owner to postgres;
revoke all on function public.dispatch_purchase(uuid,integer,date) from public,anon;
grant execute on function public.dispatch_purchase(uuid,integer,date) to authenticated;
create function public.correct_commission_deduction(p_payload jsonb,p_request_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_owner('purchases:manage');p public.purchases;prior public.finance_requests;
 period date:=(p_payload->>'month')::date;amount numeric:=app_private.purchase_money((p_payload->>'amount')::numeric);
 old_month date;affected uuid[];r record;result jsonb;body jsonb:=jsonb_build_object('action','correct_commission_deduction','actor',auth.uid(),'body',p_payload);begin
 if p_request_id is null or period is null or not isfinite(period) or period<>date_trunc('month',period)::date or amount is null or length(trim(coalesce(p_payload->>'reason',''))) not between 3 and 1000 then raise exception 'Month, nonnegative deduction and correction reason are required';end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id,0));select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from body then raise exception 'Request ID already used with different details';end if;return prior.result;end if;
 select * into p from public.purchases where tenant_id=t and purchase_id=(p_payload->>'purchase_id')::uuid for update;
 if not found or p.status<>'received' or p.business_category<>'lpg' then raise exception 'Received LPG purchase not found';end if;
 if p.revision is distinct from (p_payload->>'expected_revision')::integer then raise exception 'Purchase changed. Reload before correcting its commission.';end if;
 if amount>p.subtotal or period>date_trunc('month',p.received_at at time zone 'Asia/Dhaka')::date then raise exception 'Deduction exceeds invoice or earned month follows receipt';end if;
 perform 1 from public.items where tenant_id=t and brand_id=p.brand_id order by item_id for update;
 old_month:=coalesce(p.commission_month,(date_trunc('month',p.received_at at time zone 'Asia/Dhaka')-interval '1 month')::date);
 insert into public.monthly_commission_deductions(tenant_id,purchase_id,earned_month,received_on,amount,modified_by) values(t,p.purchase_id,period,(p.received_at at time zone 'Asia/Dhaka')::date,amount,auth.uid()) on conflict(tenant_id,purchase_id) do update set earned_month=excluded.earned_month,amount=excluded.amount,revision=monthly_commission_deductions.revision+1,modified_by=auth.uid();
 insert into public.monthly_commission_deduction_history(tenant_id,purchase_id,earned_month,amount,reason,modified_by) values(t,p.purchase_id,period,amount,p_payload->>'reason',auth.uid());
 update public.purchases set commission=amount,commission_month=period,revision=revision+1,updated_at=clock_timestamp() where tenant_id=t and purchase_id=p.purchase_id;
 perform app_private.recalculate_purchase(t,p.purchase_id);
 affected:=app_private.infer_monthly_commissions(t,p.brand_id,old_month)||app_private.infer_monthly_commissions(t,p.brand_id,period);
 for r in select distinct unnest(affected) item_id order by item_id loop perform app_private.rebuild_fifo(t,r.item_id);end loop;
 insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details) values(t,p.purchase_id,'commission_corrected',auth.uid(),jsonb_build_object('previous_amount',p.commission,'amount',amount,'previous_month',old_month,'month',period,'reason',p_payload->>'reason'));
 result:=jsonb_build_object('saved',true);insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,result,auth.uid());return result;
end $$;
alter function public.correct_commission_deduction(jsonb,uuid) owner to postgres;
revoke all on function public.correct_commission_deduction(jsonb,uuid) from public,anon;
grant execute on function public.correct_commission_deduction(jsonb,uuid) to authenticated;
-- Owners may enter dated historical invoices through the same atomic checkout.
-- Collections remain dated when money is actually received, independently.
do $$declare s text;begin
 s:=pg_get_functiondef('public.create_pos_sale(character varying,character varying,character varying,text,character varying,numeric,numeric,text,jsonb,uuid,uuid,jsonb,jsonb)'::regprocedure);
 s:=replace(s,'p_bottles jsonb DEFAULT NULL::jsonb)', 'p_bottles jsonb DEFAULT NULL::jsonb, p_sold_on date DEFAULT NULL)');
 s:=replace(s,'category text;wallet uuid;', 'category text;wallet uuid;sold_time timestamptz:=case when p_sold_on is null then clock_timestamp() else (p_sold_on+time ''15:00'') at time zone ''Asia/Dhaka'' end;');
 s:=replace(s,'if p_request_id is null then', 'if p_sold_on is not null then if not isfinite(p_sold_on) or p_sold_on>(now() at time zone ''Asia/Dhaka'')::date then raise exception ''Invalid sale business date'';end if;if p_sold_on<>(now() at time zone ''Asia/Dhaka'')::date then perform app_private.require_owner(''pos:sell'');end if;end if; if p_request_id is null then');
 s:=replace(s,'perform pg_advisory_xact_lock', 'if p_sold_on is not null then payload:=payload||jsonb_build_object(''sold_on'',p_sold_on);end if; perform pg_advisory_xact_lock');
 s:=replace(s,'checkout_payload,business_category)', 'checkout_payload,business_category,created_at)');
 s:=replace(s,'p_request_id,payload,category) returning sale_id', 'p_request_id,payload,category,sold_time) returning sale_id');
 s:=replace(s,'notes,created_by,valuation)', 'notes,created_by,valuation,created_at)');
 s:=replace(s,'jsonb_build_object(''sale_type'',x->>''type''));', 'jsonb_build_object(''sale_type'',x->>''type''),sold_time);');
 drop function public.create_pos_sale(character varying,character varying,character varying,text,character varying,numeric,numeric,text,jsonb,uuid,uuid,jsonb,jsonb);execute s;
 s:=pg_get_functiondef('app_private.receive_sale_bottles(uuid,uuid,jsonb,text,uuid)'::regprocedure);
 s:=replace(s,'created_by,fee)', 'created_by,fee,created_at)');s:=replace(s,'coalesce((body->>''fee'')::numeric,0)) returning receipt_id', 'coalesce((body->>''fee'')::numeric,0),case when phase=''checkout'' then s.created_at else clock_timestamp() end) returning receipt_id');
 s:=replace(s,'notes,created_by)', 'notes,created_by,created_at)');s:=replace(s,'end,auth.uid());','end,auth.uid(),case when phase=''checkout'' then s.created_at else clock_timestamp() end);');execute s;
end $$;
alter function public.create_pos_sale(character varying,character varying,character varying,text,character varying,numeric,numeric,text,jsonb,uuid,uuid,jsonb,jsonb,date) owner to postgres;
revoke all on function public.create_pos_sale(character varying,character varying,character varying,text,character varying,numeric,numeric,text,jsonb,uuid,uuid,jsonb,jsonb,date) from public,anon;
grant execute on function public.create_pos_sale(character varying,character varying,character varying,text,character varying,numeric,numeric,text,jsonb,uuid,uuid,jsonb,jsonb,date) to authenticated;
do $$declare s text;a integer;b integer;begin
 s:=pg_get_functiondef('app_private.refresh_buying_price(uuid,uuid,text,text,timestamptz,uuid,boolean)'::regprocedure);
 s:=replace(s,'c public.product_commission_rates','c record');
 s:=replace(s,'select * into c from public.product_commission_rates where tenant_id=t and item_id=id and created_at<=as_of order by created_at desc,rate_id desc limit 1;',
 'select rate refill_commission_per_unit,rate package_commission_per_unit,null::uuid rate_id into c from public.monthly_commission_rates where tenant_id=t and item_id=id and month=date_trunc(''month'',as_of at time zone ''Asia/Dhaka'')::date;');execute s;
 s:=pg_get_functiondef('public.accounting_operation(jsonb,uuid)'::regprocedure);
 a:=strpos(s,' elsif action=''commission_earn'' then');b:=strpos(s,' else raise exception ''Unsupported accounting action'';');
 if a=0 or b<=a then raise exception 'Unexpected superseded commission operation definition';end if;
 execute overlay(s placing '' from a for b-a);
 s:=pg_get_functiondef('app_private.analysis_entity(uuid,text,uuid)'::regprocedure);
 s:=replace(s,'elsif code=''supplier_receivable'' then select supplier_name,''commission'' into label,k from public.supplier_commissions where tenant_id=t and commission_id=id;',
 'elsif code=''supplier_receivable'' then select brand_name||'' · Monthly commission'' into label from public.lpg_brands where tenant_id=t and brand_id=id; if not found then select supplier_name,''commission'' into label,k from public.supplier_commissions where tenant_id=t and commission_id=id;end if;');
 execute s;
end $$;
drop trigger commission_buying_prices on public.product_commission_rates;
drop function app_private.commission_buying_prices();
create function app_private.monthly_buying_prices() returns trigger language plpgsql set search_path='' as $$declare k text;begin
 if new.month=date_trunc('month',now() at time zone 'Asia/Dhaka')::date then
  foreach k in array array['refill','package'] loop perform app_private.refresh_buying_price(new.tenant_id,new.item_id,k,'commission',clock_timestamp(),auth.uid());end loop;
 end if;return new;end $$;
alter function app_private.monthly_buying_prices() owner to postgres;
revoke all on function app_private.monthly_buying_prices() from public,anon,authenticated;
create trigger monthly_buying_prices after insert or update on public.monthly_commission_rates for each row execute function app_private.monthly_buying_prices();
-- Rare backdated source writes replay connected shell/bottle flows together.
-- Acquire the full ordered stock set before the first source journal, avoiding
-- an item -> snapshot -> another item lock inversion. Normal writes stay local.
do $$declare s text;begin
 s:=pg_get_functiondef('public.adjust_inventory(jsonb,uuid)'::regprocedure);
 s:=replace(s,'perform 1 from public.items where tenant_id=t and item_id=id for update;', 'if (p_payload->>''date'')::date<(now() at time zone ''Asia/Dhaka'')::date then perform 1 from public.items where tenant_id=t order by item_id for update;end if;perform 1 from public.items where tenant_id=t and item_id=id for update;');execute s;
 s:=pg_get_functiondef('public.adjust_inventory(jsonb,uuid)'::regprocedure);
 s:=replace(s,'coalesce(((p_payload->>''date'')::date+time ''12:00'') at time zone ''Asia/Dhaka'',clock_timestamp())','case when p_payload->>''date'' is null or (p_payload->>''date'')::date=(now() at time zone ''Asia/Dhaka'')::date then clock_timestamp() else ((p_payload->>''date'')::date+time ''12:00'') at time zone ''Asia/Dhaka'' end');execute s;
 s:=pg_get_functiondef('public.receive_purchase(uuid,integer,date,date)'::regprocedure);
 s:=replace(s,'perform 1 from public.items where tenant_id=t and brand_id=p.brand_id order by item_id for update;', 'if p_received_on<(now() at time zone ''Asia/Dhaka'')::date then perform 1 from public.items where tenant_id=t order by item_id for update;else perform 1 from public.items where tenant_id=t and brand_id=p.brand_id order by item_id for update;end if;');execute s;
 s:=pg_get_functiondef('public.receive_purchase(uuid,integer,date,date)'::regprocedure);
 s:=replace(s,'perform app_private.snapshot_purchase_shells(t,p_purchase_id);','if p_received_on is null or p_received_on=(now() at time zone ''Asia/Dhaka'')::date then received_time:=clock_timestamp();end if;perform app_private.snapshot_purchase_shells(t,p_purchase_id);');execute s;
 s:=pg_get_functiondef('public.dispatch_purchase(uuid,integer,date)'::regprocedure);
 s:=replace(s,'-- Acquire stock locks in SKU order.', 'if p_dispatched_on<(now() at time zone ''Asia/Dhaka'')::date then perform 1 from public.items where tenant_id=t order by item_id for update;end if;
 perform 1 from public.items where tenant_id=t and item_id in(select item_id from public.purchase_items where tenant_id=t and purchase_id=p_purchase_id) order by item_id for update;
 if p_dispatched_on is null or p_dispatched_on=(now() at time zone ''Asia/Dhaka'')::date then dispatch_time:=clock_timestamp();end if;
 -- Acquire stock locks in SKU order.');execute s;
 s:=pg_get_functiondef('public.create_pos_sale(character varying,character varying,character varying,text,character varying,numeric,numeric,text,jsonb,uuid,uuid,jsonb,jsonb,date)'::regprocedure);
 s:=replace(s,'-- Every participating item is locked', 'if p_sold_on<(now() at time zone ''Asia/Dhaka'')::date then perform 1 from public.items where tenant_id=t order by item_id for update;end if;
 -- Every participating item is locked');
 s:=replace(s,'insert into public.sales(tenant_id,customer_id,sale_tier,status,subtotal,discount_amount,exchange_fee,total_amount,','if p_sold_on is null or p_sold_on=(now() at time zone ''Asia/Dhaka'')::date then sold_time:=clock_timestamp();end if;
 insert into public.sales(tenant_id,customer_id,sale_tier,status,subtotal,discount_amount,exchange_fee,total_amount,');execute s;
end $$;
do $$declare s text;begin
 s:=pg_get_functiondef('public.save_vehicle(jsonb,uuid)'::regprocedure);
 s:=replace(s,'''date'',(now() at time zone ''Asia/Dhaka'')::date,''description'',''Vehicle acquisition: ''', '''date'',coalesce((p_payload->>''acquired_on'')::date,(now() at time zone ''Asia/Dhaka'')::date),''description'',''Vehicle acquisition: ''');execute s;
end $$;
notify pgrst,'reload schema';
