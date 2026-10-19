-- Disposable replay only: create sales predating the sale-level tier column.
insert into public.tenants(tenant_id,business_name) values
 ('c1000000-0000-4000-8000-000000000001','Legacy tier A'),
 ('c1000000-0000-4000-8000-000000000002','Legacy tier B');
insert into public.customers(tenant_id,customer_id,name,phone,tier) values
 ('c1000000-0000-4000-8000-000000000001','c2000000-0000-4000-8000-000000000001','Legacy wholesale','01700000000','wholesale'),
 ('c1000000-0000-4000-8000-000000000002','c2000000-0000-4000-8000-000000000001','Reused ID retail','01700000000','retail'),
 ('c1000000-0000-4000-8000-000000000002','c2000000-0000-4000-8000-000000000002','Legacy unsupported tier','01700000001','legacy');
insert into public.sales(tenant_id,customer_id,status,subtotal,total_amount)
select tenant_id,customer_id,'completed',123,123 from public.customers
where tenant_id in ('c1000000-0000-4000-8000-000000000001','c1000000-0000-4000-8000-000000000002');
