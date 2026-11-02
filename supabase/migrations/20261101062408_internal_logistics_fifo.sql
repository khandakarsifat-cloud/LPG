-- Internal transportation uses real paired cash entries and the original FIFO
-- acquisition/consumption links. Consolidation removes the internal carrying
-- amount both while held as stock and when subsequently expensed.
alter table public.purchases add column transport_wallet_id uuid;
alter table public.purchases add foreign key(tenant_id,transport_wallet_id) references public.wallets(tenant_id,wallet_id);
create table app_private.internal_transport_settlements(
 tenant_id uuid not null,purchase_id uuid not null,source_wallet_id uuid not null,destination_wallet_id uuid not null,
 amount numeric(20,2) not null check(amount>0),occurred_on date not null,reversed boolean not null default false,
 primary key(tenant_id,purchase_id),foreign key(tenant_id,purchase_id) references public.purchases(tenant_id,purchase_id),
 foreign key(tenant_id,source_wallet_id) references public.wallets(tenant_id,wallet_id),foreign key(tenant_id,destination_wallet_id) references public.wallets(tenant_id,wallet_id)
);
alter table app_private.internal_transport_settlements enable row level security;
revoke all on app_private.internal_transport_settlements from public,anon,authenticated;

create function app_private.settle_internal_transport(t uuid,pid uuid,d date,reverse_entry boolean default false) returns void
language plpgsql set search_path='' as $$declare p public.purchases;s app_private.internal_transport_settlements;cash uuid;src uuid;v numeric;x uuid;y uuid;lines jsonb;begin
 select * into p from public.purchases where tenant_id=t and purchase_id=pid for update;
 select * into s from app_private.internal_transport_settlements where tenant_id=t and purchase_id=pid;
 if reverse_entry then if s.purchase_id is null or s.reversed then return;end if;v:=-s.amount;src:=s.source_wallet_id;cash:=s.destination_wallet_id;
 else
  if s.purchase_id is not null or p.transport_cost=0 then return;end if;
  select wallet_id into cash from public.wallets where tenant_id=t and type='cash' and is_active;
  src:=coalesce(p.transport_wallet_id,cash);v:=p.transport_cost;
 end if;
 perform 1 from public.wallets where tenant_id=t and wallet_id in(src,cash) order by wallet_id for update;
 if (select count(*) from public.wallets where tenant_id=t and wallet_id=any(array[src,cash]) and is_active)<>(case when src=cash then 1 else 2 end) then raise exception 'Choose active transport wallets';end if;
 if not reverse_entry then insert into app_private.internal_transport_settlements values(t,pid,src,cash,v,d,false);end if;
 insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,operation_id,description,accounting_date,allocations)
 values(t,src,-v,'internal_transport_payment',pid,pid,case when reverse_entry then 'Internal purchase transport reversed' else 'Internal purchase transport paid' end,d,jsonb_build_object(p.business_category,100)) returning transaction_id into x;
 insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,operation_id,description,accounting_date,allocations)
 values(t,cash,v,case when reverse_entry then 'internal_transport_return' else 'internal_transport_receipt' end,pid,pid,'Logistics internal purchase transport',d,'{"logistics":100}') returning transaction_id into y;
 lines:=jsonb_build_array(
  app_private.accounting_line('cash',-v,p.business_category,src,jsonb_build_object('wallet_transaction_id',x,'purchase_id',pid)),
  app_private.accounting_line('inventory_transit',v,p.business_category,pid)||jsonb_build_object('consolidated_amount',0),
  app_private.accounting_line('cash',v,'logistics',cash,jsonb_build_object('wallet_transaction_id',y,'purchase_id',pid)),
  app_private.accounting_line('internal_logistics_revenue',-v,'logistics',pid)||jsonb_build_object('consolidated_amount',0));
 perform app_private.post_journal(t,'internal_transport',pid,case when reverse_entry then 'return' else 'paid' end,d,'Internal purchase transport',lines);
 if reverse_entry then update app_private.internal_transport_settlements set reversed=true where tenant_id=t and purchase_id=pid;end if;
end $$;

-- Internal cash pairs are posted together; each journal balances in both views.
do $$declare s text;begin
 s:=pg_get_functiondef('app_private.account_wallet()'::regprocedure);
 s:=replace(s,'begin', 'begin if new.type in (''internal_transport_payment'',''internal_transport_receipt'',''internal_transport_return'') then return new;end if;');execute s;
 s:=pg_get_functiondef('public.create_purchase(jsonb)'::regprocedure);
 s:=replace(s,'return jsonb_build_object(''purchase_id'',id);',
 'if p_payload->>''transport_wallet_id'' is not null then update public.purchases set transport_wallet_id=(p_payload->>''transport_wallet_id'')::uuid where tenant_id=t and purchase_id=id;end if; return jsonb_build_object(''purchase_id'',id);');execute s;
 s:=pg_get_functiondef('public.dispatch_purchase(uuid,integer,date)'::regprocedure);
 s:=replace(s,'-- Acquire stock locks in SKU order.',
 'perform 1 from public.wallets where tenant_id=t and (wallet_id=p.transport_wallet_id or type=''cash'') order by wallet_id for update; -- Acquire stock locks in SKU order.');
 s:=replace(s,'insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details)',
 'perform app_private.settle_internal_transport(t,p_purchase_id,(dispatch_time at time zone ''Asia/Dhaka'')::date); insert into public.purchase_activity(tenant_id,purchase_id,action,created_by,details)');execute s;
 s:=pg_get_functiondef('public.initiate_purchase_cancellation(uuid,integer,text,uuid)'::regprocedure);
 s:=replace(s,'-- Only dispatch is reversible:',
 'perform 1 from public.wallets where tenant_id=t and (wallet_id in(select source_wallet_id from app_private.internal_transport_settlements where tenant_id=t and purchase_id=p_purchase_id) or type=''cash'') order by wallet_id for update; -- Only dispatch is reversible:');
 s:=replace(s,'update public.transits set status=''cancelled''',
 'perform app_private.settle_internal_transport(t,p_purchase_id,(now() at time zone ''Asia/Dhaka'')::date,true); update public.transits set status=''cancelled''');execute s;
end $$;

-- A deduction correction must update its dependent supplier amount in the same
-- source write; the recognition trigger must never observe an unbalanced row.
do $$declare s text;begin
 s:=pg_get_functiondef('public.correct_commission_deduction(jsonb,uuid)'::regprocedure);
 s:=replace(s,'set commission=amount,commission_month=period','set commission=amount,company_payable=subtotal-amount,commission_month=period');execute s;
 s:=pg_get_functiondef('app_private.logistics_result(uuid,uuid[],uuid[])'::regprocedure);
 s:=replace(s,'union all select ''operating_cost''',
 'union all select ''internal_transport'',tr.purchase_id,false from public.transits tr where tr.tenant_id=t and tr.transit_id=any(transit_ids) and tr.purchase_id is not null union all select ''operating_cost''');execute s;
end $$;

create function app_private.guard_transport_terms() returns trigger language plpgsql set search_path='' as $$begin
 if old.status<>'created' and (new.transport_cost<>old.transport_cost or new.transport_wallet_id is distinct from old.transport_wallet_id) then raise exception 'Dispatched transport terms are fixed; cancel the unreceived purchase to reverse its payment';end if;return new;end $$;
create trigger guard_transport_terms before update of transport_cost,transport_wallet_id on public.purchases for each row execute function app_private.guard_transport_terms();

alter table app_private.fifo_layers add column internal_value numeric(20,2) not null default 0;
alter table app_private.fifo_layers add column remaining_internal_value numeric(20,2) not null default 0;
alter table app_private.fifo_consumptions add column internal_value numeric(20,2) not null default 0;
create index fifo_internal_remaining on app_private.fifo_layers(tenant_id,item_id) include(remaining_internal_value) where remaining_internal_value<>0;

-- Cumulative invoice boundaries allocate exact cents without a last-row plug.
create function app_private.internal_layer_value(t uuid,mid uuid) returns numeric language sql stable set search_path='' as $$
 with movement as(select * from public.inventory_movements where tenant_id=t and movement_id=mid),
 lines as(select pi.item_id,pi.type,pi.quantity,pi.billed_quantity*pi.unit_price value,
  sum(pi.billed_quantity*pi.unit_price) over() total,sum(pi.quantity) over() total_qty,
  sum(pi.billed_quantity*pi.unit_price) over(order by pi.item_id,pi.type) boundary,
  sum(pi.quantity) over(order by pi.item_id,pi.type) qty_boundary,s.amount
  from movement m join public.purchase_items pi on pi.tenant_id=t and pi.purchase_id=m.reference_id
  join app_private.internal_transport_settlements s on s.tenant_id=t and s.purchase_id=pi.purchase_id and not s.reversed)
 select coalesce((select case when l.total>0 then round(l.amount*l.boundary/l.total,2)-round(l.amount*(l.boundary-l.value)/l.total,2)
 else round(l.amount*l.qty_boundary/l.total_qty,2)-round(l.amount*(l.qty_boundary-l.quantity)/l.total_qty,2) end
 from lines l,movement m where l.item_id=m.item_id and l.type::text=case when m.reference_type='purchase_receipt_refill' then 'refill' else 'package' end),0);$$;

create function app_private.initialize_internal_layer() returns trigger language plpgsql set search_path='' as $$begin
 if new.component='filled' then new.internal_value:=app_private.internal_layer_value(new.tenant_id,new.movement_id);new.remaining_internal_value:=new.internal_value;end if;return new;end $$;
create trigger initialize_internal_layer before insert on app_private.fifo_layers for each row execute function app_private.initialize_internal_layer();

create or replace function app_private.fifo_take(t uuid,id uuid,mid uuid,part text,qty integer) returns numeric
language plpgsql set search_path='' as $$declare r record;n integer:=qty;take integer;v numeric;shell numeric;iv numeric;total numeric:=0;begin
 for r in select * from app_private.fifo_layers where tenant_id=t and item_id=id and component=part and remaining>0 order by acquired_at,acquired_order for update loop
  exit when n=0;take:=least(n,r.remaining);v:=case when take=r.remaining then r.remaining_value else round(r.remaining_value*take/r.remaining,2) end;
  shell:=case when take=r.remaining then r.remaining_shell_value else round(r.remaining_shell_value*take/r.remaining,2) end;
  iv:=case when take=r.remaining then r.remaining_internal_value else round(r.remaining_internal_value*take/r.remaining,2) end;
  update app_private.fifo_layers set remaining=remaining-take,remaining_value=remaining_value-v,remaining_shell_value=remaining_shell_value-shell,remaining_internal_value=remaining_internal_value-iv where tenant_id=t and layer_id=r.layer_id;
  insert into app_private.fifo_consumptions(tenant_id,movement_id,layer_id,quantity,value,shell_value,internal_value) values(t,mid,r.layer_id,take,v,shell,iv);total:=total+v;n:=n-take;
 end loop;
 if n<>0 then raise exception 'Insufficient FIFO % stock for product',part;end if;return total;
end $$;

create function app_private.sync_internal_fifo(m public.inventory_movements) returns void language plpgsql set search_path='' as $$declare
 a numeric:=0;c numeric:=0;cat text;account text;counter text;lines jsonb;begin
 select coalesce(sum(internal_value),0) into a from app_private.fifo_layers where tenant_id=m.tenant_id and movement_id=m.movement_id;
 select coalesce(sum(internal_value),0) into c from app_private.fifo_consumptions where tenant_id=m.tenant_id and movement_id=m.movement_id;
 if a=0 and c=0 and not exists(select 1 from app_private.accounting_source_state where tenant_id=m.tenant_id and source in ('internal_inventory','internal_cogs') and source_id=m.movement_id and revision>0) then return;end if;
 select business_category into cat from public.items where tenant_id=m.tenant_id and item_id=m.item_id;
 account:=case when cat='stove' then 'inventory_stove' else 'inventory_lpg' end;
 counter:=case when a<>0 then 'inventory_transit' when m.reference_type in ('sale','sale_reversal') then 'cogs' else 'inventory_loss' end;
 lines:=jsonb_build_array(app_private.accounting_line(account,a-c,cat,m.item_id)||jsonb_build_object('consolidated_amount',0),
  app_private.accounting_line(counter,c-a,cat,case when counter='inventory_transit' then m.reference_id end)||jsonb_build_object('consolidated_amount',0));
 perform app_private.sync_journal(m.tenant_id,case when a<>0 then 'internal_inventory' else 'internal_cogs' end,m.movement_id,(m.created_at at time zone 'Asia/Dhaka')::date,'Internal transport FIFO carrying cost',lines);
end $$;

do $$declare s text;begin
 s:=pg_get_functiondef('app_private.fifo_cost_movement(public.inventory_movements)'::regprocedure);
 s:=replace(s,'remaining_shell_value=remaining_shell_value+batch.shell_value','remaining_shell_value=remaining_shell_value+batch.shell_value,remaining_internal_value=remaining_internal_value+batch.internal_value');
 s:=replace(s,'insert into app_private.fifo_consumptions values(m.tenant_id,m.movement_id,batch.layer_id,-batch.quantity,-batch.value,-batch.shell_value)',
 'insert into app_private.fifo_consumptions(tenant_id,movement_id,layer_id,quantity,value,shell_value,internal_value) values(m.tenant_id,m.movement_id,batch.layer_id,-batch.quantity,-batch.value,-batch.shell_value,-batch.internal_value)');
 s:=replace(s,'shell_value=fifo_consumptions.shell_value+excluded.shell_value;',
 'shell_value=fifo_consumptions.shell_value+excluded.shell_value,internal_value=fifo_consumptions.internal_value+excluded.internal_value;');
 s:=replace(s,'lines,counter=''opening_equity'');','lines,counter=''opening_equity'');perform app_private.sync_internal_fifo(m);');execute s;
end $$;

alter table app_private.internal_transport_settlements owner to postgres;
do $$declare r record;begin for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='app_private' and p.proname in ('settle_internal_transport','guard_transport_terms','internal_layer_value','initialize_internal_layer','sync_internal_fifo') loop
 execute format('alter function %s owner to postgres',r.sig);execute format('revoke all on function %s from public,anon,authenticated',r.sig);end loop;end $$;
