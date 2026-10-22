-- Run immediately before the multi-wallet migration in a disposable database.
insert into public.tenants(tenant_id,business_name) values('fa000000-0000-4000-8000-000000000001','Wallet migration fixture');
insert into public.wallets(tenant_id,wallet_id,type,balance) values
 ('fa000000-0000-4000-8000-000000000001','fa000000-0000-4000-8000-000000000002','dealership',-123.45),
 ('fa000000-0000-4000-8000-000000000001','fa000000-0000-4000-8000-000000000003','logistics',57.89);
insert into public.wallet_transactions(tenant_id,wallet_id,transaction_id,amount,type,description) values
 ('fa000000-0000-4000-8000-000000000001','fa000000-0000-4000-8000-000000000002','fa000000-0000-4000-8000-000000000004',10,'transport_income','Existing historical entry');
