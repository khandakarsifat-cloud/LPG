create schema bottle_migration_fixture;
create table bottle_migration_fixture.preservation as select
 (select md5(coalesce(jsonb_agg(to_jsonb(s) order by tenant_id,sale_id)::text,'')) from public.sales s) sales,
 (select md5(coalesce(jsonb_agg(to_jsonb(i) order by tenant_id,item_id)::text,'')) from public.items i) stock,
 (select md5(coalesce(jsonb_agg(to_jsonb(m) order by tenant_id,movement_id)::text,'')) from public.inventory_movements m) movements,
 (select md5(coalesce(jsonb_agg(to_jsonb(w) order by tenant_id,wallet_id)::text,'')) from public.wallets w) wallets,
 (select md5(coalesce(jsonb_agg(to_jsonb(w) order by tenant_id,transaction_id)::text,'')) from public.wallet_transactions w) ledger;
