do $$begin
 if exists(select 1 from purchase_migration_fixture.snapshot s where s.stock is distinct from
 (select md5(jsonb_agg(to_jsonb(i) order by tenant_id,item_id)::text) from public.items i) or s.wallets is distinct from
 (select md5(jsonb_agg(jsonb_build_array(tenant_id,wallet_id,type,balance,updated_at) order by tenant_id,wallet_id)::text) from public.wallets) or s.ledger is distinct from
 (select md5(jsonb_agg(jsonb_build_array(tenant_id,transaction_id,wallet_id,amount,type,reference_id,description,created_at,balance_after) order by tenant_id,transaction_id)::text) from public.wallet_transactions) or s.transits is distinct from
 (select md5(jsonb_agg(to_jsonb(tr) order by tenant_id,transit_id)::text) from public.transits tr) or s.lines is distinct from
 (select md5(jsonb_agg(to_jsonb(pi) order by tenant_id,purchase_item_id)::text) from public.purchase_items pi)) then raise exception 'Purchase migration altered original stock, balances, ledger, transits or lines'; end if;
 if exists(select 1 from public.purchases where legacy_record and payment_status='paid' and paid_amount<>total_cost) then raise exception 'Legacy settled meaning changed'; end if;
end $$;
select set_config('request.jwt.claim.sub','f9100000-0000-4000-8000-000000000001',false);
do $$declare p public.purchases; w uuid; lw uuid; o record; result jsonb; before_cash numeric; before_bank numeric;
begin
 select wallet_id,balance into w,before_cash from public.wallets where tenant_id=app_private.current_tenant_id() and type='cash';
 select * into p from public.purchases where tenant_id=app_private.current_tenant_id() and notes='Legacy paid transit';
 result:=public.initiate_purchase_cancellation(p.purchase_id,p.revision,'CANCEL',gen_random_uuid());
 if (result->>'refund_due')::numeric<>130 then raise exception 'Legacy paid transit obligations double counted'; end if;
 for o in select * from public.purchase_refund_obligations where tenant_id=p.tenant_id and purchase_id=p.purchase_id loop
  perform public.refund_purchase(p.purchase_id,o.obligation_id,jsonb_build_array(jsonb_build_object('wallet_id',w,'amount',o.amount)),gen_random_uuid());
 end loop;
 if (select balance from public.wallets where tenant_id=p.tenant_id and wallet_id=w)<>before_cash+130 then raise exception 'Legacy purchasing refunds incorrect'; end if;
 select wallet_id into lw from public.wallets where tenant_id=app_private.current_tenant_id() and type='logistics';
 select * into p from public.purchases where tenant_id=app_private.current_tenant_id() and notes='Legacy uncharged funding';
 if p.paid_amount<>0 then raise exception 'Legacy uncharged funding invented a payment'; end if;
 select balance into before_bank from public.wallets where tenant_id=p.tenant_id and type='dealership';
 perform public.update_purchase(p.purchase_id,'{"transport_cost":5}',p.revision);
 if (select balance from public.wallets where tenant_id=p.tenant_id and type='dealership')<>before_bank or
  (select paid_amount from public.purchases where tenant_id=p.tenant_id and purchase_id=p.purchase_id)<>0 then raise exception 'Editing uncharged legacy transport invented a purchasing credit'; end if;
 select * into p from public.purchases where tenant_id=p.tenant_id and purchase_id=p.purchase_id;
 perform public.initiate_purchase_cancellation(p.purchase_id,p.revision,'CANCEL',gen_random_uuid());
 select * into o from public.purchase_refund_obligations where tenant_id=p.tenant_id and purchase_id=p.purchase_id;
 if o.amount<>5 or o.credit_business then raise exception 'Legacy funding reversal invented a purchasing credit'; end if;
 perform public.refund_purchase(p.purchase_id,o.obligation_id,jsonb_build_array(jsonb_build_object('wallet_id',lw,'amount',5)),gen_random_uuid());
 if (select balance from public.wallets where tenant_id=p.tenant_id and wallet_id=w)<>before_cash+130 then raise exception 'Uncharged legacy funding credited purchasing wallet'; end if;
end $$;
-- Keep the seeded business only inside the disposable database until its final
-- DROP DATABASE teardown; immutable purchase history is intentionally retained.
drop schema purchase_migration_fixture cascade;
select set_config('request.jwt.claim.sub','',false);
select 'PASS: legacy paid purchase, original stock, wallet balances, ledger, transit and billed lines preserved';
