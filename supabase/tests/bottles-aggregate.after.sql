do $$begin
 if exists(select 1 from aggregate_migration_fixture.preservation p where p.sales is distinct from (select md5(jsonb_agg(to_jsonb(s) order by tenant_id,sale_id)::text) from public.sales s)
 or p.stock is distinct from (select md5(jsonb_agg(to_jsonb(i) order by tenant_id,item_id)::text) from public.items i)
 or p.movements is distinct from (select md5(jsonb_agg(to_jsonb(m) order by tenant_id,movement_id)::text) from public.inventory_movements m)
 or p.wallets is distinct from (select md5(jsonb_agg(to_jsonb(w) order by tenant_id,wallet_id)::text) from public.wallets w)
 or p.ledger is distinct from (select md5(jsonb_agg(to_jsonb(w) order by tenant_id,transaction_id)::text) from public.wallet_transactions w)
 or p.receipts is distinct from (select md5(jsonb_agg(to_jsonb(r)-'expense'-'expense_wallet_id'-'expense_wallet_name' order by tenant_id,receipt_id)::text) from public.sale_bottle_receipts r)
 or p.lines is distinct from (select md5(jsonb_agg(to_jsonb(l)-'acknowledged' order by tenant_id,line_id)::text) from public.sale_bottle_receipt_lines l)) then raise exception 'Aggregate migration changed historical evidence';end if;
end $$;
set role authenticated;
select set_config('request.jwt.claim.sub','c2222222-2222-4222-8222-222222222222',false);
do $$declare sid uuid;state jsonb;begin
 select sale_id into sid from public.sales where notes='Historical tracked sale';
 state:=public.get_sale_bottles(sid);
 if (state->>'outstanding')::integer<>3 or (state->>'received')::integer<>2 or (public.get_sale_settlement(sid)->>'due')::numeric<>520 then raise exception 'Historical aggregate/money changed';end if;
 if not exists(select 1 from jsonb_array_elements(state->'events') e where e->>'kind'='bottles' and (e->>'amount')::numeric=20 and e->'lines'->0->>'expected_item_id' is not null) then raise exception 'Historical fee/allocation evidence missing';end if;
 perform public.collect_sale_bottles(sid,
 '{"lines":[{"received_item_id":"cb000000-0000-4000-8000-000000000001","quantity":3,"acknowledged":true}]}',gen_random_uuid());
 if (public.get_sale_bottles(sid)->>'outstanding')::integer<>0 or (public.get_sale_settlement(sid)->>'due')::numeric<>520 then raise exception 'Historical sale cannot settle by aggregate';end if;
end $$;
reset role;
create table aggregate_migration_fixture.cleanup(id integer);
create function aggregate_migration_fixture.cleanup() returns trigger language plpgsql as $$begin
delete from public.finance_requests where tenant_id in ('c1111111-1111-4111-8111-111111111111','d1111111-1111-4111-8111-111111111111');
delete from public.wallet_transactions where tenant_id in ('c1111111-1111-4111-8111-111111111111','d1111111-1111-4111-8111-111111111111');
delete from public.customer_transactions where tenant_id in ('c1111111-1111-4111-8111-111111111111','d1111111-1111-4111-8111-111111111111');
delete from public.sale_payments where tenant_id in ('c1111111-1111-4111-8111-111111111111','d1111111-1111-4111-8111-111111111111');
delete from public.sale_bottle_receipt_lines where tenant_id in ('c1111111-1111-4111-8111-111111111111','d1111111-1111-4111-8111-111111111111');
delete from public.sale_bottle_receipts where tenant_id in ('c1111111-1111-4111-8111-111111111111','d1111111-1111-4111-8111-111111111111');
delete from public.sale_bottle_obligations where tenant_id in ('c1111111-1111-4111-8111-111111111111','d1111111-1111-4111-8111-111111111111');
delete from public.sale_items where tenant_id in ('c1111111-1111-4111-8111-111111111111','d1111111-1111-4111-8111-111111111111');
delete from public.sales where tenant_id in ('c1111111-1111-4111-8111-111111111111','d1111111-1111-4111-8111-111111111111');
delete from public.inventory_movements where tenant_id in ('c1111111-1111-4111-8111-111111111111','d1111111-1111-4111-8111-111111111111');
delete from public.price_books where tenant_id in ('c1111111-1111-4111-8111-111111111111','d1111111-1111-4111-8111-111111111111');
delete from public.items where tenant_id in ('c1111111-1111-4111-8111-111111111111','d1111111-1111-4111-8111-111111111111');
delete from public.customers where tenant_id in ('c1111111-1111-4111-8111-111111111111','d1111111-1111-4111-8111-111111111111');
delete from public.wallets where tenant_id in ('c1111111-1111-4111-8111-111111111111','d1111111-1111-4111-8111-111111111111');
delete from public.user_roles where tenant_id in ('c1111111-1111-4111-8111-111111111111','d1111111-1111-4111-8111-111111111111');
delete from public.role_permissions where tenant_id in ('c1111111-1111-4111-8111-111111111111','d1111111-1111-4111-8111-111111111111');
delete from public.roles where tenant_id in ('c1111111-1111-4111-8111-111111111111','d1111111-1111-4111-8111-111111111111');
delete from public.audit_logs where tenant_id in ('c1111111-1111-4111-8111-111111111111','d1111111-1111-4111-8111-111111111111');
delete from public.user_profiles where tenant_id in ('c1111111-1111-4111-8111-111111111111','d1111111-1111-4111-8111-111111111111');
delete from public.tenants where tenant_id in ('c1111111-1111-4111-8111-111111111111','d1111111-1111-4111-8111-111111111111');
return new;end$$;
create trigger cleanup after insert on aggregate_migration_fixture.cleanup for each row execute function aggregate_migration_fixture.cleanup();
insert into aggregate_migration_fixture.cleanup values(1);
delete from auth.users where id in ('c2222222-2222-4222-8222-222222222222','d2222222-2222-4222-8222-222222222222');
drop schema aggregate_migration_fixture cascade;
select 'PASS: tracked historical receipts, allocation evidence, customer fees, stock, wallets and ledger preserved; old sale settles by aggregate';
