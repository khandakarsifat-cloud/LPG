-- Show actual LPG company identities and natural withdrawal movements in all-account activity.
CREATE OR REPLACE FUNCTION app_private.analysis_entity(t uuid, code text, id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO ''
AS $function$
declare label text;k text;ref uuid:=id;begin
 if id is null and code='cash' then label:='Pooled business cash';
 elsif id is null then select a.name into label from public.accounting_accounts a where a.code=analysis_entity.code;
 elsif code='cash' then select name,'wallet' into label,k from public.wallets where tenant_id=t and wallet_id=id;
 elsif code in ('inventory_lpg','inventory_stove') then
  select coalesce(i.product_name,concat_ws(' ',b.brand_name,i.size_kg||' kg',i.mouth_size)),'product' into label,k from public.items i left join public.lpg_brands b using(tenant_id,brand_id) where i.tenant_id=t and i.item_id=id;
 elsif code='customer_receivable' then select coalesce(nullif(shop_name,''),name),'customer' into label,k from public.customers where tenant_id=t and customer_id=id;
 elsif code in ('loan_payable','loan_receivable') then select lender,'loan' into label,k from public.loans where tenant_id=t and loan_id=id;
 elsif code in ('vehicles','equipment','other_assets') then select name,'asset' into label,k from public.business_assets where tenant_id=t and asset_id=id;
 elsif code in ('supplier_payable','inventory_transit') then select coalesce(p.supplier_name,b.brand_name,'Supplier')||' · Purchase #'||left(id::text,8),'purchase' into label,k from public.purchases p left join public.lpg_brands b using(tenant_id,brand_id) where p.tenant_id=t and p.purchase_id=id;
 elsif code='other_income' and exists(select 1 from public.purchases where tenant_id=t and purchase_id=id) then select coalesce(p.supplier_name,b.brand_name,'Company')||' · Purchase #'||left(id::text,8),'purchase' into label,k from public.purchases p left join public.lpg_brands b using(tenant_id,brand_id) where p.tenant_id=t and p.purchase_id=id;
 elsif code='bottle_receivable' then select 'Cylinders · Sale #'||left(id::text,8),'sale' into label,k from public.sales where tenant_id=t and sale_id=id;
 elsif code='supplier_receivable' and exists(select 1 from app_private.purchase_rebate_accounts where tenant_id=t and account_id=id) then select company_name||' · Company rebate credit' into label from app_private.purchase_rebate_accounts where tenant_id=t and account_id=id;
 elsif code='supplier_receivable' then select brand_name||' · Supplier advance/refund' into label from public.lpg_brands where tenant_id=t and brand_id=id; 
 elsif code='employee_payable' then select name,'employee' into label,k from public.employees where tenant_id=t and employee_id=id;
 end if;
 if label is null then select description,'obligation' into label,k from public.finance_obligations where tenant_id=t and obligation_id=id;end if;
 if label is null then select 'Journey · '||destination||' #'||left(id::text,8),'transit' into label,k from public.transits where tenant_id=t and transit_id=id;end if;
 if label is null then select a.name into label from public.accounting_accounts a where a.code=analysis_entity.code;end if;
 return jsonb_build_object('entity_name',label,'record_kind',k,'record_id',ref);end $function$;
CREATE OR REPLACE FUNCTION public.get_accounting_breakdown(p_filters jsonb, p_group text, p_side text, p_mode text DEFAULT 'components'::text, p_offset integer DEFAULT 0, p_limit integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$declare
 ids uuid[]:=app_private.analysis_scope(p_filters);d date:=(p_filters->>'to')::date;f date:=(p_filters->>'from')::date;
 cat text:=coalesce(p_filters->>'category','all');original boolean:=false;before_day boolean:=false;r jsonb;begin
 if coalesce(p_filters->>'direction','all') not in ('all','increase','decrease') or coalesce(p_filters->>'sort','newest') not in ('newest','oldest','largest','smallest')
 or nullif(p_filters->>'min','')::numeric<0 or nullif(p_filters->>'max','')::numeric<0
 or nullif(p_filters->>'min','')::numeric>nullif(p_filters->>'max','')::numeric
 or nullif(p_filters->>'history_from','')::date>d then raise exception 'Invalid activity ranges';end if;
 if p_side not in ('opening','closing','period') or p_mode not in ('components','history') or p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit not between 1 and 100
 or p_group not in ('all','assets','liabilities','equity','accumulated_income','cash','inventory','receivables','fixed_assets','other_assets','dues','employees','other_liabilities','capital','revenue','expenses','withdrawals','other_equity')
 or f is null or d is null or not isfinite(f) or not isfinite(d) or f>d or d>(now() at time zone 'Asia/Dhaka')::date or length(coalesce(p_filters->>'search',''))>500 or cat not in ('all','lpg','stove','logistics') then raise exception 'Invalid breakdown filters';end if;
 if coalesce((p_filters->>'all_time')::boolean,false) then select min((started_at at time zone 'Asia/Dhaka')::date) into f from public.accounting_periods where tenant_id=any(ids);f:=least(f,d);end if;
 if p_side='opening' then before_day:=true;d:=f;original:=coalesce((p_filters->>'all_time')::boolean,false);end if;
 with evidence as(select *,1 sign from app_private.dimensional_balances(ids,d,before_day,original) union all select *,-1 from app_private.dimensional_balances(ids,f,true,coalesce((p_filters->>'all_time')::boolean,false)) where p_side='period'),
 balances as materialized(select b.tenant_id,b.account,b.business_category,b.type_id,
 case when a.kind in ('income','expense','equity') or b.account='cash' then null else b.entity_id end entity_id,a.kind,a.name,
 sum(b.sign*case when cat='all' then b.consolidated_amount else b.amount end) amount
 from evidence b join public.accounting_accounts a on a.code=b.account where cat='all' or b.business_category=cat group by 1,2,3,4,5,6,7),
 classified as(select *,sum(amount) over(partition by tenant_id,account,entity_id) control_total,case when kind='liability' and sum(amount) over(partition by tenant_id,account,entity_id)>0 then 'asset'
 when kind='asset' and account<>'cash' and sum(amount) over(partition by tenant_id,account,entity_id)<0 then 'liability' else kind end reported_kind from balances),
 selected as materialized(select *,case when p_group='withdrawals' or p_group='all' and account='withdrawals' then 1 when p_group in ('equity','accumulated_income') or reported_kind in ('liability','income','equity') then -1 else 1 end sign
 from classified where (p_group='all' or app_private.analysis_matches(p_group,account,reported_kind))
 and (nullif(p_filters->>'account','') is null or account=p_filters->>'account')
 and (nullif(p_filters->>'type_id','') is null or type_id=(p_filters->>'type_id')::uuid)
 and (nullif(p_filters->>'component_business','') is null or business_category=p_filters->>'component_business')
 and (nullif(p_filters->>'entity_id','') is null or p_filters->>'entity_id'='none' and entity_id is null or entity_id=nullif(nullif(p_filters->>'entity_id',''),'none')::uuid)),
 described as materialized(select s.*,ft.name type_name,app_private.analysis_entity(s.tenant_id,s.account,s.entity_id) entity from selected s join public.financial_types ft using(type_id)),
 components as materialized(select * from described where
 (nullif(p_filters->>'min','') is null or abs(amount)>=(p_filters->>'min')::numeric)
 and (nullif(p_filters->>'max','') is null or abs(amount)<=(p_filters->>'max')::numeric)
 and (coalesce(p_filters->>'direction','all')='all' or p_filters->>'direction'='increase' and amount*sign>0 or p_filters->>'direction'='decrease' and amount*sign<0) and amount<>0 and (kind in ('income','expense','equity') or control_total<>0) and app_private.finance_search(concat_ws(' ',name,type_name,business_category,entity->>'entity_name'),coalesce(p_filters->>'search',''))),
 component_page as(select * from components order by abs(amount) desc,tenant_id,account,type_id,business_category,entity_id nulls first offset p_offset limit p_limit),
 movements as materialized(select j.tenant_id,j.journal_id,j.entry_no,j.occurred_on,j.description,j.source,j.source_id,j.source_id transaction_reference,j.estimated,l.line_no,l.account,s.name,l.type_id,s.type_name,l.business_category,l.entity_id,
 (case when cat='all' then l.consolidated_amount else l.amount end)*s.sign amount,app_private.analysis_entity(l.tenant_id,l.account,l.entity_id)||app_private.financial_source_link(j.tenant_id,j.source,j.source_id) entity
 from described s join public.accounting_lines l on l.tenant_id=s.tenant_id and l.account=s.account and l.type_id=s.type_id and l.business_category=s.business_category
 and (s.kind in ('income','expense','equity') or s.account='cash' or l.entity_id is not distinct from s.entity_id)
 join public.accounting_journals j on j.tenant_id=l.tenant_id and j.journal_id=l.journal_id
 where p_mode='history' and (p_side<>'period' or j.occurred_on>=f) and (case when before_day then j.occurred_on<d or original and j.is_opening and j.occurred_on=d else j.occurred_on<=d end)
 and (nullif(p_filters->>'history_from','') is null or j.occurred_on>=(p_filters->>'history_from')::date)
 and (nullif(p_filters->>'source','') is null or j.source=p_filters->>'source')
 and app_private.finance_search(concat_ws(' ',j.description,s.name,s.type_name,s.business_category,s.entity->>'entity_name',j.source,j.source_id),coalesce(p_filters->>'search',''))),
 filtered_movements as materialized(select * from movements where
 (nullif(p_filters->>'min','') is null or abs(amount)>=(p_filters->>'min')::numeric)
 and (nullif(p_filters->>'max','') is null or abs(amount)<=(p_filters->>'max')::numeric)
 and (coalesce(p_filters->>'direction','all')='all' or p_filters->>'direction'='increase' and amount>0 or p_filters->>'direction'='decrease' and amount<0)),
 history_page as(select * from filtered_movements order by
 case when p_filters->>'sort'='oldest' then occurred_on end asc,
 case when p_filters->>'sort'='largest' then abs(amount) end desc,
 case when p_filters->>'sort'='smallest' then abs(amount) end asc,
 occurred_on desc,entry_no desc,line_no offset p_offset limit p_limit)
 select jsonb_build_object('cutoff',case when before_day and not original then d-1 else d end,'original_opening',original,'accounts',(select jsonb_agg(jsonb_build_object('code',code,'name',name) order by name) from public.accounting_accounts),'sources',coalesce((select jsonb_agg(source order by source) from(select distinct source from public.accounting_journals where tenant_id=any(ids)) sources),'[]'::jsonb),
 'balance',coalesce((select sum(amount*sign) from selected),0),
 'total',case when p_mode='components' then (select count(*) from components) else (select count(*) from filtered_movements) end,
 'filtered_movement',case when p_mode='history' then (select coalesce(sum(amount),0) from filtered_movements) end,
 'entries',case when p_mode='components' then coalesce((select jsonb_agg(jsonb_build_object('tenant_id',tenant_id,'account',account,'name',name,'kind',reported_kind,'entity_id',entity_id,'type_id',type_id,'type_name',type_name,'business_category',business_category,'amount',amount*sign)||entity order by abs(amount) desc,tenant_id,account,type_id,business_category,entity_id nulls first) from component_page),'[]')
 else coalesce((select jsonb_agg((to_jsonb(p)-'entity')||entity order by case when p_filters->>'sort'='oldest' then occurred_on end asc,case when p_filters->>'sort'='largest' then abs(amount) end desc,case when p_filters->>'sort'='smallest' then abs(amount) end asc,occurred_on desc,entry_no desc,line_no) from history_page p),'[]') end) into r;return r;end $function$;
notify pgrst,'reload schema';
