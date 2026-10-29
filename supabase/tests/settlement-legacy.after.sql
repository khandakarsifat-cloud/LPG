
do $$begin
 if settlement_migration_fixture.snapshot()<>(select before from settlement_migration_fixture.preservation) then raise exception 'Settlement migration changed business rows';end if;
end $$;
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub','c2222222-2222-4222-8222-222222222222',true);
do $$declare r record; result jsonb;begin
 select * into r from settlement_migration_fixture.state;
 result:=public.collect_sale_bottles((r.payload->>'sale')::uuid,r.payload->'body',r.request_id);
 if result<>r.result then raise exception 'Historical expense retry reinterpreted';end if;
 result:=public.get_sale_receipt((r.payload->>'sale')::uuid);
 if (result#>>'{settlement,additional_charges}')::numeric<>0 or (result#>>'{settlement,due}')::numeric<>520 then raise exception 'Historical expense converted to customer debt';end if;
end $$;
rollback;
create table settlement_migration_fixture.cleanup(id integer);
create function settlement_migration_fixture.cleanup() returns trigger language plpgsql as $$begin
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
create trigger cleanup after insert on settlement_migration_fixture.cleanup for each row execute function settlement_migration_fixture.cleanup();
insert into settlement_migration_fixture.cleanup values(1);
delete from auth.users where id in ('c2222222-2222-4222-8222-222222222222','d2222222-2222-4222-8222-222222222222');
drop schema settlement_migration_fixture cascade;
select 'PASS: settlement migration preserves every business row and historical expense retries retain original accounting';
