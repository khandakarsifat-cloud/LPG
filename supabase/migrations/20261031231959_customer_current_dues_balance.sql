-- The unscoped directory's money due is the current customer-ledger balance,
-- including legitimate opening receivables, corrections and customer credits.
-- Date/product scopes retain their existing selected-invoice due calculation.
do $$declare s text;begin
 s:=pg_get_functiondef('public.get_customer_directory(jsonb,integer,integer,uuid)'::regprocedure);
 if strpos(s,'m.total_sold_amount,m.total_due,m.last_transaction_at')=0 then raise exception 'Unexpected customer lifetime projection definition';end if;
 s:=replace(s,'m.total_sold_amount,m.total_due,m.last_transaction_at','m.total_sold_amount,greatest(0,-m.ledger_balance),m.last_transaction_at');execute s;
end $$;
notify pgrst,'reload schema';
