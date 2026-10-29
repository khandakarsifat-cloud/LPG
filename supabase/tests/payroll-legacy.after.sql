do $$ begin
 if exists(select 1 from payroll_migration_fixture.payments old left join public.employee_payments p using(tenant_id,payment_id) where p.payment_id is null or
 (p.employee_id,p.amount,p.payment_date,p.description,p.trip_count,p.created_at,p.created_by,p.kind) is distinct from
 (old.employee_id,old.amount,old.payment_date,old.description,old.trip_count,old.created_at,old.created_by,old.category_code)) then raise exception 'Historical employee payments changed'; end if;
 if (select base_amount from public.payroll_obligations where employee_id='e8888888-8888-4888-8888-888888888888')<>5000 then raise exception 'Invented historical salary entitlement'; end if;
 if (select app_private.payroll_balance('e9999999-9999-4999-8999-999999999999',obligation_id)->>'outstanding' from public.payroll_obligations where employee_id='e8888888-8888-4888-8888-888888888888')::numeric<>0 then raise exception 'Invented historical salary arrears'; end if;
 if exists(select 1 from public.employee_payment_entries where tenant_id='e9999999-9999-4999-8999-999999999999') then raise exception 'Invented historical wallet attribution'; end if;
 if not exists(select 1 from public.employee_terms where employee_id='e8888888-8888-4888-8888-888888888888' and monthly_salary=9000 and not is_active) then raise exception 'Employee opening terms changed'; end if;
end $$;
select 'PASS: historical payment amounts, dates, descriptions, trips and identities preserved; known salaries settled without invented entitlement, arrears or wallet movements';
