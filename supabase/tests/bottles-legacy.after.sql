do $$begin
 if exists(select 1 from bottle_migration_fixture.preservation p where
 p.sales is distinct from (select md5(coalesce(jsonb_agg(to_jsonb(s)-'bottle_tracking'-'additional_charges' order by tenant_id,sale_id)::text,'')) from public.sales s)
 or p.stock is distinct from (select md5(coalesce(jsonb_agg(to_jsonb(i) order by tenant_id,item_id)::text,'')) from public.items i)
 or p.movements is distinct from (select md5(coalesce(jsonb_agg(to_jsonb(m) order by tenant_id,movement_id)::text,'')) from public.inventory_movements m)
 or p.wallets is distinct from (select md5(coalesce(jsonb_agg(to_jsonb(w) order by tenant_id,wallet_id)::text,'')) from public.wallets w)
 or p.ledger is distinct from (select md5(coalesce(jsonb_agg(to_jsonb(w) order by tenant_id,transaction_id)::text,'')) from public.wallet_transactions w))
 then raise exception 'Bottle migration changed historical records'; end if;
 if exists(select 1 from public.sale_bottle_obligations) or exists(select 1 from public.sale_bottle_receipts) or exists(select 1 from public.sales where bottle_tracking or additional_charges<>0) then raise exception 'Bottle migration invented historical activity'; end if;
end $$;
select 'PASS: historical sales, stock, movements, wallet balances and ledger preserved; no artificial bottle dues or receipts';

drop schema bottle_migration_fixture cascade;
