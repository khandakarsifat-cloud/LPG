-- Only invoked inside disposable migration replay, before virtual-wallet removal.
insert into auth.users(id,email,is_anonymous) values('aa910000-0000-4000-8000-000000000001','accounting-normalization@example.invalid',false);
select set_config('request.jwt.claim.sub','aa910000-0000-4000-8000-000000000001',false);
select public.setup_business('Accounting normalization disposable fixture','Owner');
select set_config('request.jwt.claim.sub','',false);
create table app_private.accounting_normalization_fixture(t uuid,pid uuid,bank uuid,cash uuid,virtual uuid,original_virtual jsonb,original_ledger jsonb);
do $$ declare t uuid;p uuid:=gen_random_uuid();b uuid:=gen_random_uuid();plant uuid:=gen_random_uuid();bank uuid;cash uuid;lw uuid;ob uuid;pay uuid;src uuid;begin
 select tenant_id into t from public.user_profiles where user_id='aa910000-0000-4000-8000-000000000001';
 insert into public.lpg_brands(tenant_id,brand_id,brand_name) values(t,b,'Normalization brand');
 insert into public.gas_plants(tenant_id,plant_id,brand_id,plant_name) values(t,plant,b,'Normalization plant');
 insert into public.purchases(tenant_id,purchase_id,plant_id,brand_id,status,company_payable,transport_cost,labour_cost,total_cost,paid_amount,transport_funded,refund_due)
 values(t,p,plant,b,'cancelled',100,20,0,120,20,20,10);
 select wallet_id into bank from public.wallets where tenant_id=t and type='dealership';select wallet_id into cash from public.wallets where tenant_id=t and type='cash';select wallet_id into lw from public.wallets where tenant_id=t and type='logistics';
 insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description) values(t,bank,-20,'purchase_transport_funding',p,'Recorded virtual funding debit') returning transaction_id into src;
 insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description) values(t,lw,20,'purchase_transport_funding',p,'Recorded virtual funding credit');
 insert into public.purchase_refund_obligations(tenant_id,purchase_id,component,amount,logistics_amount,credit_business,sources,created_by)
 values(t,p,'transport',20,20,true,jsonb_build_array(jsonb_build_object('transaction_id',src,'amount',-20)),'aa910000-0000-4000-8000-000000000001') returning obligation_id into ob;
 insert into public.purchase_payments(tenant_id,purchase_id,wallet_id,wallet_name,method,amount,kind,component,obligation_id,operation_id,created_by)
 values(t,p,cash,'Cash Register','cash',10,'refund','transport',ob,gen_random_uuid(),'aa910000-0000-4000-8000-000000000001') returning payment_id into pay;
 insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,reference_id,description,purchase_payment_id) values(t,cash,10,'purchase_refund',p,'Partly returned virtual funding',pay),(t,lw,-10,'purchase_funding_reversal',p,'Partly reversed virtual funding',pay);
 insert into app_private.accounting_normalization_fixture select t,p,bank,cash,lw,(select to_jsonb(w) from public.wallets w where w.tenant_id=t and w.wallet_id=lw),
 (select jsonb_agg(to_jsonb(x) order by x.transaction_id) from public.wallet_transactions x where x.tenant_id=t and x.wallet_id=lw);
end $$;
