-- Runs only in the disposable restored database. Retained lab operations are read-only.
begin;
create function pg_temp.assert(ok boolean,message text) returns void language plpgsql as $$begin if ok is not true then raise exception 'FAIL: %',message;end if;end $$;
grant execute on function pg_temp.assert(boolean,text) to authenticated;
select set_config('request.jwt.claim.sub',(select user_id::text from public.user_profiles where tenant_id='63907560-fbbd-4ac2-b22b-04bb08f0b123' limit 1),true);
-- Privileged source comparisons stay in this disposable test session; the RPCs
-- still resolve the selected user's trusted membership and permissions.
do $$
declare kind text; category text; sorting text; result jsonb; chunk jsonb; row jsonb; previous_number numeric; number_value numeric; previous_text text; text_value text; ascending boolean; expected integer; field text; numeric_sort boolean; seen integer;
begin
 for kind in select unnest(array['sales','purchase','employee']) loop
  for category in select unnest(case when kind='employee' then array['all'] else array['all','lpg','stove'] end) loop
   for sorting in select unnest(case kind
    when 'sales' then array['date_asc','date_desc','amount_asc','amount_desc','due_asc','due_desc','bottles_asc','bottles_desc','customer_asc','customer_desc']
    when 'purchase' then array['date_asc','date_desc','amount_asc','amount_desc','due_asc','due_desc','supplier_asc','supplier_desc']
    else array['name_asc','name_desc','salary_asc','salary_desc','joined_asc','joined_desc'] end) loop
    if kind='sales' then
     result:=public.get_sales_directory(jsonb_build_object('business_category',category,'sort',sorting),0,100);
     select count(*) into expected from public.sales where tenant_id=app_private.current_tenant_id() and (category='all' or business_category=category);
     chunk:=public.get_sales_directory(jsonb_build_object('business_category',category,'sort',sorting),1,2);
    elsif kind='purchase' then
     result:=public.get_purchase_directory(jsonb_build_object('business_category',category,'sort',sorting),0,100);
     select count(*) into expected from public.purchases where tenant_id=app_private.current_tenant_id() and (category='all' or business_category=category);
     chunk:=public.get_purchase_directory(jsonb_build_object('business_category',category,'sort',sorting),1,2);
    else
     result:=public.get_employee_directory(jsonb_build_object('sort',sorting),0,100);
     select count(*) into expected from public.employees where tenant_id=app_private.current_tenant_id();
     chunk:=public.get_employee_directory(jsonb_build_object('sort',sorting),1,2);
    end if;
    perform pg_temp.assert((result->>'total')::integer=expected,kind||' count matches source and trusted tenant');
    perform pg_temp.assert(expected>0 and expected<=100,kind||' fixture has representative source records');
    perform pg_temp.assert(chunk->'entries'=coalesce((select jsonb_agg(value order by ord) from jsonb_array_elements(result->'entries') with ordinality e(value,ord) where ord between 2 and 3),'[]'),kind||' stable server pagination: '||sorting);
    ascending:=sorting like '%_asc'; previous_number:=null; previous_text:=null; seen:=0;
    field:=split_part(sorting,'_',1); numeric_sort:=field in ('amount','due','bottles','salary');
    for row in select value from jsonb_array_elements(result->'entries') loop
     if kind<>'employee' then perform pg_temp.assert(category='all' or row->>'business_category'=category,kind||' category filtered before pagination');end if;
     if numeric_sort then
      number_value:=case field when 'amount' then (row->>case when kind='sales' then 'total_amount' else 'total_cost' end)::numeric
       when 'due' then case when kind='sales' then (row->>'due')::numeric else case when row->>'status'='cancelled' then 0 else greatest(0,(row->>'payable_amount')::numeric-(row->>'paid_amount')::numeric) end end
       when 'bottles' then (row->>'outstanding_bottles')::numeric when 'salary' then (row->>'current_salary')::numeric end;
      perform pg_temp.assert(number_value is not null and (previous_number is null or case when ascending then previous_number<=number_value else previous_number>=number_value end),kind||' numeric ordering: '||sorting);
      previous_number:=number_value;
     else
      text_value:=case field when 'date' then row->>'created_at' when 'joined' then row->>'joining_date'
       when 'name' then lower(row->>'name') when 'supplier' then lower(coalesce(row->>'company_name',row->>'supplier_name',''))
       when 'customer' then lower(case when row->>'sale_tier'='wholesale' then coalesce(nullif(row->>'shop_name',''),row->>'name') else row->>'name' end) end;
      perform pg_temp.assert(text_value is not null and (previous_text is null or case when ascending then previous_text<=text_value else previous_text>=text_value end),kind||' text ordering: '||sorting);
      previous_text:=text_value;
     end if;
     seen:=seen+1;
    end loop;
    perform pg_temp.assert(seen=expected,kind||' all matching records returned');
   end loop;
  end loop;
 end loop;
 begin perform public.get_sales_directory('{"business_category":"foreign"}');raise exception 'FAIL: invalid sales category accepted';exception when raise_exception then if sqlerrm like 'FAIL:%' then raise;end if;end;
 begin perform public.get_purchase_directory('{"sort":"injected"}');raise exception 'FAIL: invalid purchase sort accepted';exception when raise_exception then if sqlerrm like 'FAIL:%' then raise;end if;end;
end $$;
reset role;
select 'PASS: all directory sort directions, category counts, stable pagination and trusted tenant source comparisons';
rollback;
