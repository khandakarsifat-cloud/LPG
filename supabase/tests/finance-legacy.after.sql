do $$ begin
 if not exists(select 1 from public.wallets where wallet_id='fa000000-0000-4000-8000-000000000002' and balance=-123.45 and opening_balance=-133.45 and name='Primary Bank Account') then raise exception 'Legacy signed wallet balance or identity changed'; end if;
 if not exists(select 1 from public.wallets where wallet_id='fa000000-0000-4000-8000-000000000003' and balance=57.89) then raise exception 'Logistics balance changed'; end if;
 if (select count(*) from public.wallets where tenant_id='fa000000-0000-4000-8000-000000000001')<>5 then raise exception 'Existing business defaults missing'; end if;
 if not exists(select 1 from public.wallet_transactions where transaction_id='fa000000-0000-4000-8000-000000000004' and amount=10 and balance_after=-123.45) or
 (select count(*) from public.wallet_transactions where tenant_id='fa000000-0000-4000-8000-000000000001')<>1 then raise exception 'Legacy ledger changed or was duplicated'; end if;
end $$;
delete from public.tenants where tenant_id='fa000000-0000-4000-8000-000000000001';
select 'PASS: existing signed balances, wallet IDs and ledger references preserved without financial backfill';
