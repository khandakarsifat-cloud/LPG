do $$ declare f app_private.accounting_normalization_fixture;begin
 select * into f from app_private.accounting_normalization_fixture;
 if exists(select 1 from public.wallets where tenant_id=f.t and type='logistics') then raise exception 'Virtual wallet survived normalization';end if;
 if exists(select 1 from public.wallets where tenant_id=f.t and balance<>0) then raise exception 'Funding and its partial refund were not unwound exactly once';end if;
 if (select record from public.financial_source_archive where tenant_id=f.t and source_table='wallets' and source_id=f.virtual) is distinct from f.original_virtual then raise exception 'Original virtual wallet evidence changed';end if;
 if (select jsonb_agg(record order by source_id) from public.financial_source_archive where tenant_id=f.t and source_table='wallet_transactions') is distinct from f.original_ledger then raise exception 'Original virtual ledger evidence changed';end if;
 if not exists(select 1 from public.purchases where tenant_id=f.t and purchase_id=f.pid and payable_amount=100 and paid_amount=0 and refund_due=0 and financial_closed_at is not null) then raise exception 'Obsolete funding created an invented payment or refund';end if;
 if (select count(*) from public.wallet_transactions where tenant_id=f.t and type='accounting_normalization')<>2 then raise exception 'Funding normalization did not preserve compensating references';end if;
end $$;
drop table app_private.accounting_normalization_fixture;
select 'PASS: virtual wallet and ledger archived byte-for-byte; partial funding/refund corrected once; no invented payments or residual refund obligation';
