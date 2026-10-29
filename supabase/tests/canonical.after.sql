do $$ begin
 if exists(select 1 from canonical_migration_fixture.state p where
 p.stock is distinct from (select md5(coalesce(jsonb_agg(jsonb_build_array(tenant_id,item_id,filled_quantity,empty_quantity) order by tenant_id,item_id)::text,'')) from public.items)
 or p.wallets is distinct from (select md5(coalesce(jsonb_agg(to_jsonb(x) order by tenant_id,wallet_id)::text,'')) from public.wallets x)
 or p.wallet_ledger is distinct from (select md5(coalesce(jsonb_agg(to_jsonb(x) order by tenant_id,transaction_id)::text,'')) from public.wallet_transactions x)
 or p.customer_ledger is distinct from (select md5(coalesce(jsonb_agg(to_jsonb(x) order by tenant_id,transaction_id)::text,'')) from public.customer_transactions x)
 or p.payments is distinct from (select md5(coalesce(jsonb_agg(to_jsonb(x) order by tenant_id,payment_id)::text,'')) from public.sale_payments x))
 then raise exception 'Canonical migration reposted stock or money'; end if;
 if exists(select 1 from canonical_migration_fixture.receipts e where e.quantity<>(
  select coalesce(sum(l.quantity),0) from public.sale_bottle_receipt_lines l join public.sale_bottle_receipts r using(tenant_id,receipt_id)
  where l.tenant_id=e.tenant_id and l.sale_id=e.sale_id and l.received_item_id=e.item_id and r.phase='checkout'))
 then raise exception 'Original empty returns not normalized exactly once'; end if;
 if exists(select 1 from canonical_migration_fixture.commissions c join public.product_commission_rates r using(tenant_id,rate_id)
  where c.refill_rate<>r.refill_commission_per_unit or c.package_rate<>r.package_commission_per_unit)
 then raise exception 'Commission normalization changed rates'; end if;
 if to_regclass('public.sale_bottle_obligations') is not null
 or exists(select 1 from information_schema.columns where table_schema='public' and column_name in ('bottle_tracking','payment_tracking','legacy_record','cylinder_weight','expected_item_id','allow_incompatible'))
 or to_regprocedure('public.list_purchases()') is not null or to_regprocedure('public.set_product_commission(uuid,numeric,uuid)') is not null
 then raise exception 'Obsolete schema survived normalization'; end if;
 if exists(select 1 from public.items where brand_id is null)
 or exists(select 1 from public.product_commission_rates where package_commission_per_unit is null)
 then raise exception 'Canonical data is incomplete'; end if;
 if exists(select 1 from public.sales s where s.paid_amount<(select coalesce(sum(amount),0) from public.sale_payments p where p.tenant_id=s.tenant_id and p.sale_id=s.sale_id))
 then raise exception 'Recorded payments exceed paid header'; end if;
 if exists(select 1 from pg_proc p where pronamespace in ('public'::regnamespace,'app_private'::regnamespace)
  and prosrc ~ '(bottle_tracking|payment_tracking|legacy_record|sale_bottle_obligations|expected_item_id|allow_incompatible|[.]brand\y)')
 then raise exception 'Runtime still depends on obsolete schema'; end if;
end $$;
select 'PASS: canonical receipts and commission backfill; obsolete schema/RPC removal; unchanged stock, wallet/customer ledgers and payment evidence';
drop schema canonical_migration_fixture cascade;
