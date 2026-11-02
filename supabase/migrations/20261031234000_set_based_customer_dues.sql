-- Evaluate current bottle obligations once per directory request rather than
-- traversing each customer's history separately. No additional stored counter.
do $$declare s text;begin
 s:=pg_get_functiondef('public.get_customer_directory(jsonb,integer,integer,uuid)'::regprocedure);
 if strpos(s,'app_private.customer_dues_kind(t,c.customer_id)')=0 then raise exception 'Unexpected customer dues predicate';end if;
 s:=replace(s,'with candidates as materialized (',
 'with bottle_due as materialized (
   select distinct s.customer_id from public.sales s
   join (select sale_id,sum(quantity) quantity from public.sale_items where tenant_id=t and type=''empty_return'' group by sale_id)e on e.sale_id=s.sale_id
   left join (select sale_id,sum(quantity) quantity from public.sale_bottle_receipt_lines where tenant_id=t group by sale_id)r on r.sale_id=s.sale_id
   where s.tenant_id=t and s.status=''completed'' and coalesce(p_filters->>''dues'',''all'')<>''all'' and e.quantity>coalesce(r.quantity,0)
 ), dues_scope as materialized (
   select c.customer_id from public.customers c
   left join app_private.customer_metrics m on m.tenant_id=c.tenant_id and m.customer_id=c.customer_id
   left join bottle_due b on b.customer_id=c.customer_id
   where c.tenant_id=t and coalesce(p_filters->>''dues'',''all'')<>''all''
   and (coalesce(m.ledger_balance,0)<0)=(p_filters->>''dues'' in (''payment'',''both''))
   and (b.customer_id is not null)=(p_filters->>''dues'' in (''bottle'',''both''))
 ), candidates as materialized (');
 s:=replace(s,'app_private.customer_dues_kind(t,c.customer_id)=p_filters->>''dues''','c.customer_id in(select customer_id from dues_scope)');execute s;
end $$;
drop function app_private.customer_dues_kind(uuid,uuid);
notify pgrst,'reload schema';
