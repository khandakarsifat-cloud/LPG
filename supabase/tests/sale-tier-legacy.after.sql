do $$ begin
 if (select count(*) from public.sales where tenant_id='c1000000-0000-4000-8000-000000000001' and sale_tier='wholesale' and total_amount=123) <> 1
 or (select count(*) from public.sales where tenant_id='c1000000-0000-4000-8000-000000000002' and sale_tier='retail' and total_amount=123) <> 2 then
   raise exception 'Historical sale tier backfill is not tenant-qualified or changed totals';
 end if;
end $$;
delete from public.sales where tenant_id in ('c1000000-0000-4000-8000-000000000001','c1000000-0000-4000-8000-000000000002');
delete from public.customers where tenant_id in ('c1000000-0000-4000-8000-000000000001','c1000000-0000-4000-8000-000000000002');
delete from public.tenants where tenant_id in ('c1000000-0000-4000-8000-000000000001','c1000000-0000-4000-8000-000000000002');
select 'PASS: historical sale tier inference, reused customer IDs, retail fallback and preserved totals' as verification;
