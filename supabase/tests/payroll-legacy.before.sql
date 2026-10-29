-- Called only by the disposable replay immediately before monthly payroll.
create schema payroll_migration_fixture;
insert into public.tenants(tenant_id,business_name) values('e9999999-9999-4999-8999-999999999999','Payroll migration fixture');
insert into public.employees(tenant_id,employee_id,name,current_salary,business_unit,is_active) values('e9999999-9999-4999-8999-999999999999','e8888888-8888-4888-8888-888888888888','Historical payroll fixture',9000,'gas_business',false);
insert into public.employee_phone_numbers(tenant_id,employee_id,phone,is_primary) values('e9999999-9999-4999-8999-999999999999','e8888888-8888-4888-8888-888888888888','01700000051',true);
insert into public.employee_payment_categories(tenant_id,code,name,category_kind) values
 ('e9999999-9999-4999-8999-999999999999','salary','Monthly Salary','salary'),
 ('e9999999-9999-4999-8999-999999999999','bonus','Bonus','bonus'),
 ('e9999999-9999-4999-8999-999999999999','trips','Trips','trips');
insert into public.employee_payments(tenant_id,employee_id,category_id,category_code,amount,payment_date,salary_year,salary_month,trip_count,description)
 select c.tenant_id,'e8888888-8888-4888-8888-888888888888',c.category_id,c.code,v.amount,'2025-05-01',case when c.code='salary' then 2025 end,case when c.code='salary' then 4 end,case when c.code='trips' then 2 end,'Historical evidence'
 from public.employee_payment_categories c join (values('salary',5000),('bonus',1000),('trips',600)) v(code,amount) using(code) where c.tenant_id='e9999999-9999-4999-8999-999999999999';
create table payroll_migration_fixture.payments as select * from public.employee_payments where tenant_id='e9999999-9999-4999-8999-999999999999';
