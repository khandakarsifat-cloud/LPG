-- Apply immediately before the canonical development migration in a disposable replay.
create schema canonical_migration_fixture;
create table canonical_migration_fixture.state as select
 (select md5(coalesce(jsonb_agg(jsonb_build_array(tenant_id,item_id,filled_quantity,empty_quantity) order by tenant_id,item_id)::text,'')) from public.items) stock,
 (select md5(coalesce(jsonb_agg(to_jsonb(x) order by tenant_id,wallet_id)::text,'')) from public.wallets x) wallets,
 (select md5(coalesce(jsonb_agg(to_jsonb(x) order by tenant_id,transaction_id)::text,'')) from public.wallet_transactions x) wallet_ledger,
 (select md5(coalesce(jsonb_agg(to_jsonb(x) order by tenant_id,transaction_id)::text,'')) from public.customer_transactions x) customer_ledger,
 (select md5(coalesce(jsonb_agg(to_jsonb(x) order by tenant_id,payment_id)::text,'')) from public.sale_payments x) payments;
create table canonical_migration_fixture.receipts as
 select s.tenant_id,s.sale_id,si.item_id,sum(si.quantity) quantity
 from public.sales s join public.sale_items si using(tenant_id,sale_id)
 where not s.bottle_tracking and si.type='empty_return' group by s.tenant_id,s.sale_id,si.item_id;
create table canonical_migration_fixture.commissions as
 select tenant_id,rate_id,commission_per_unit refill_rate,coalesce(package_commission_per_unit,commission_per_unit) package_rate
 from public.product_commission_rates;
