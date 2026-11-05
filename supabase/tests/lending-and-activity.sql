-- Runs only inside the owned disposable database, then rolls back.
insert into auth.users(id,email,is_anonymous) values('fc062000-0000-4000-8000-000000000001','lending-owner@example.invalid',false);
select pg_temp.fixture_identity('fc062000-0000-4000-8000-000000000001');
select pg_temp.fixture_business('Lending disposable acceptance','Lending owner');
do $$declare
 t uuid:=app_private.current_tenant_id(); cash uuid; loan uuid; borrowed uuid; req uuid:=gen_random_uuid(); result jsonb; body jsonb; r jsonb; d date:=(now() at time zone 'Asia/Dhaka')::date;
 loan_action text;rounded_loan uuid;part numeric;
 filters jsonb:=jsonb_build_object('from',d,'to',d,'category','all');
begin
 select wallet_id into cash from public.wallets where tenant_id=t and type='cash';
 perform public.accounting_operation(jsonb_build_object('action','capital','amount',1000,'wallet_id',cash,'date',d,'description','Lending fixture funds'),gen_random_uuid());
 body:=jsonb_build_object('action','loan_lend','amount',100.01,'wallet_id',cash,'date',d,'lender','Fixture borrower','description','Lending fixture principal','allocations','{"lpg":33.33,"stove":66.67}'::jsonb);
 result:=public.accounting_operation(body,req);loan:=(result->>'id')::uuid;
 if public.accounting_operation(body,req)<>result then raise exception 'FAIL lending replay';end if;
 begin perform public.accounting_operation(body||'{"amount":100.02}',req);raise exception 'FAIL changed request';exception when others then if sqlerrm<>'Request ID already used with different details' then raise;end if;end;
 if (select balance from public.wallets where tenant_id=t and wallet_id=cash)<>899.99 then raise exception 'FAIL lending cash';end if;
 if (select sum(amount) from public.accounting_lines where tenant_id=t and account='loan_receivable')<>100.01 then raise exception 'FAIL lending receivable';end if;
 if (public.get_accounting_register('loans')->>'total')::integer<>0 or (public.get_accounting_register('lending')->>'total')::integer<>1 then raise exception 'FAIL direction registers';end if;
 begin perform public.accounting_operation(jsonb_build_object('action','loan_repay','loan_id',loan,'amount',1,'wallet_id',cash,'date',d,'description','Wrong direction'),gen_random_uuid());raise exception 'FAIL wrong direction';exception when others then if sqlerrm<>'Repayment exceeds outstanding principal or loan was not found' then raise;end if;end;
 perform public.accounting_operation(jsonb_build_object('action','loan_collect','loan_id',loan,'amount',40.01,'wallet_id',cash,'date',d,'description','Lending partial repayment'),gen_random_uuid());
 if (select outstanding from public.loans where tenant_id=t and loan_id=loan)<>60 then raise exception 'FAIL partial collection';end if;
 begin perform public.accounting_operation(jsonb_build_object('action','loan_collect','loan_id',loan,'amount',60.01,'wallet_id',cash,'date',d,'description','Too much'),gen_random_uuid());raise exception 'FAIL overcollection';exception when others then if sqlerrm<>'Repayment exceeds outstanding principal or loan was not found' then raise;end if;end;
 r:=public.get_finance_analysis(filters);
 if (r->'closing'->>'assets')::numeric<>1000 or (r->'closing'->>'cash')::numeric<>940 or (r->'closing'->>'revenue')::numeric<>0 or (r->'closing'->>'expenses')::numeric<>0 then raise exception 'FAIL lending recognition';end if;
 perform app_private.build_accounting_snapshots(t,2);
 r:=public.get_accounting_breakdown(filters||jsonb_build_object('account','loan_receivable'),'all','closing','history',0,100);
 if (r->>'total')::integer<>2 or (r->>'filtered_movement')::numeric<>60 then raise exception 'FAIL full lending activity and exact business splits';end if;
 r:=public.get_accounting_breakdown(filters||jsonb_build_object('account','loan_receivable','direction','decrease','min','1','max','100','search','partial repayment'),'all','closing','history',0,100);
 if (r->>'total')::integer<>1 or (r->>'filtered_movement')::numeric<>-40.01 then raise exception 'FAIL combined search/amount/direction filters';end if;
 r:=public.get_accounting_breakdown(filters||jsonb_build_object('account','loan_receivable'),'receivables','closing','components',0,100);
 if (r->>'total')::integer<>4 or (r->>'balance')::numeric<>60 then raise exception 'FAIL lending components and receivable classification';end if;
 if not app_private.reconcile_record(t,'loan',loan) then
  if exists(select 1 from app_private.reconciliation_findings where tenant_id=t and entity_id=loan and status='open') then raise exception 'FAIL lending reconciliation';end if;
 end if;
 perform public.accounting_operation(jsonb_build_object('action','loan_collect','loan_id',loan,'amount',60,'wallet_id',cash,'date',d,'description','Lending final repayment'),gen_random_uuid());
 if (select balance from public.wallets where tenant_id=t and wallet_id=cash)<>1000 or (select outstanding from public.loans where tenant_id=t and loan_id=loan)<>0 then raise exception 'FAIL full collection';end if;
 if exists(select 1 from public.accounting_lines where tenant_id=t and entity_id=loan and account='loan_receivable' group by business_category having sum(amount)<>0) then raise exception 'FAIL full collection leaves business rounding residue';end if;
 result:=public.accounting_operation(jsonb_build_object('action','loan_create','amount',50,'wallet_id',cash,'date',d,'lender','Fixture lender','description','Borrowing unchanged'),gen_random_uuid());borrowed:=(result->>'id')::uuid;
 perform public.accounting_operation(jsonb_build_object('action','loan_repay','loan_id',borrowed,'amount',50,'wallet_id',cash,'date',d,'description','Borrowing repaid'),gen_random_uuid());
 if (public.get_accounting_register('loans')->>'total')::integer<>1 then raise exception 'FAIL borrowing retained';end if;
 -- Rounded cumulative percentage boundaries can move a middle share backward.
 -- Settlements must stay nonnegative and within the original principal cents.
 foreach loan_action in array array['loan_lend','loan_create'] loop
  result:=public.accounting_operation(jsonb_build_object('action',loan_action,'amount',100.05,'wallet_id',cash,'date',d,'lender','Three-business rounding boundary','description','Bounded principal fixture','allocations','{"logistics":33.33,"lpg":33.33,"stove":33.34}'::jsonb),gen_random_uuid());rounded_loan:=(result->>'id')::uuid;
  foreach part in array array[100.04,0.01]::numeric[] loop
   perform public.accounting_operation(jsonb_build_object('action',case when loan_action='loan_lend' then 'loan_collect' else 'loan_repay' end,'loan_id',rounded_loan,'amount',part,'wallet_id',cash,'date',d,'description','Final cent stays within original ownership'),gen_random_uuid());
  end loop;
  if (select outstanding from public.loans where tenant_id=t and loan_id=rounded_loan)<>0 or exists(select 1 from public.accounting_lines where tenant_id=t and entity_id=rounded_loan and account in ('loan_receivable','loan_payable') group by business_category having sum(amount)<>0)
   then raise exception 'FAIL three-business repayment ownership did not close';end if;
 end loop;
 if exists(select 1 from public.accounting_lines where tenant_id=t group by journal_id having sum(amount)<>0 or sum(consolidated_amount)<>0) then raise exception 'FAIL unbalanced lending journal';end if;
 if exists(select 1 from app_private.dimensional_balances(array[t],d,false,false) b full join (select tenant_id,account,business_category,type_id,entity_id,sum(amount) amount,sum(consolidated_amount) consolidated_amount from public.accounting_lines l join public.accounting_journals j using(tenant_id,journal_id) where l.tenant_id=t and j.occurred_on<=d group by 1,2,3,4,5) x on b.tenant_id=x.tenant_id and b.account=x.account and b.business_category=x.business_category and b.type_id=x.type_id and b.entity_id is not distinct from x.entity_id where coalesce(b.amount,0)<>coalesce(x.amount,0) or coalesce(b.consolidated_amount,0)<>coalesce(x.consolidated_amount,0)) then raise exception 'FAIL savepoint versus full journal';end if;
end $$;
