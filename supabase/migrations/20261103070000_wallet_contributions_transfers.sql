create or replace function public.move_wallet_money(p_payload jsonb,p_request_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$declare
 t uuid:=app_private.require_permission('finance:manage');prior public.finance_requests;body jsonb:=p_payload||jsonb_build_object('actor',auth.uid());
 src uuid:=(p_payload->>'wallet_id')::uuid;dest uuid:=(p_payload->>'destination_id')::uuid;a numeric:=(p_payload->>'amount')::numeric;
 b text:=coalesce(p_payload->>'business','lpg');db text:=coalesce(p_payload->>'destination_business',b);action text:=p_payload->>'action';reason text:=trim(p_payload->>'reason');result jsonb; mode text:=coalesce(p_payload->>'transfer_mode','proportional'); portions jsonb; total numeric; running numeric:=0; assigned numeric:=0; part numeric; k text; d date:=coalesce((p_payload->>'date')::date,(now() at time zone 'Asia/Dhaka')::date);begin
 perform app_private.require_permission(case when action='transfer' then 'wallets:transfer' else 'wallets:adjust' end);
 if p_request_id is null then raise exception 'Request ID is required';end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||':finance:'||p_request_id::text,0));
 select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload is distinct from body then raise exception 'Request ID already used with different details';end if;return prior.result;end if;
 if action not in ('transfer','adjustment') or action is null or reason is null or length(reason) not between 3 and 500 or jsonb_typeof(p_payload->'amount') is distinct from 'number'
 or a=0 or abs(a)<>app_private.purchase_money(abs(a)) or b not in ('lpg','stove','logistics') or db not in ('lpg','stove','logistics') or not isfinite(d) or d>(now() at time zone 'Asia/Dhaka')::date then raise exception 'Choose a valid operation, amount, business, date and reason';end if;
 perform 1 from public.wallets where tenant_id=t and wallet_id in(src,dest) order by wallet_id for update;
 if not exists(select 1 from public.wallets where tenant_id=t and wallet_id=src and is_active) then raise exception 'Active source wallet not found';end if;
 if action='transfer' then
  if a<0 or dest is null or mode not in ('proportional','business') then raise exception 'Choose a valid transfer mode, destination and positive amount';end if;
  if not exists(select 1 from public.wallets where tenant_id=t and wallet_id=dest and is_active) then raise exception 'Active destination wallet not found';end if;
  if mode='business' then
   if dest=src and db=b then raise exception 'Choose a different wallet or business';end if;
   insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,description,counterparty_wallet_id,operation_id,accounting_date,allocations) values
    (t,src,-a,'wallet_transfer',reason,dest,p_request_id,d,jsonb_build_object(b,100)),(t,dest,a,'wallet_transfer',reason,src,p_request_id,d,jsonb_build_object(db,100));
  else
   if dest=src then raise exception 'Choose a different destination wallet';end if;
   if p_payload ? 'business' or p_payload ? 'destination_business' then raise exception 'Business selection requires business transfer mode';end if;
   select balance,business_balances into total,portions from public.wallets where tenant_id=t and wallet_id=src;
   if total=0 then raise exception 'A zero-total wallet requires Advanced business transfer';end if;
   -- Cumulative signed rounding keeps the three portions exact to the paisa.
   foreach k in array array['lpg','stove','logistics'] loop
    running:=running+(portions->>k)::numeric;
    part:=round(a*running/total,2)-assigned;
    assigned:=assigned+part;
    if part<>0 then
     insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,description,counterparty_wallet_id,operation_id,accounting_date,allocations) values
      (t,src,-part,'wallet_transfer',reason,dest,p_request_id,d,jsonb_build_object(k,100)),(t,dest,part,'wallet_transfer',reason,src,p_request_id,d,jsonb_build_object(k,100));
    end if;
   end loop;
  end if;
 else
  if dest is not null or coalesce(p_payload->>'classification','correction') not in ('correction','capital') then raise exception 'Invalid adjustment classification';end if;
  if p_payload->>'classification'='capital' then perform app_private.require_owner('finance:manage');if a<0 then raise exception 'Capital contribution must be positive';end if;end if;
  insert into public.wallet_transactions(tenant_id,wallet_id,amount,type,description,operation_id,accounting_date,allocations)
  values(t,src,a,case p_payload->>'classification' when 'capital' then 'owner_capital' else 'balance_adjustment' end,reason,p_request_id,d,jsonb_build_object(b,100));
 end if;
 result:=jsonb_build_object('operation_id',p_request_id);insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,result,auth.uid());return result;
end $$;

-- Historical opening source evidence is retained. New wallet and stock additions
-- use one capital contract; no historical quantities, costs or journals are reposted.
do $$declare s text;begin
 s:=pg_get_functiondef('public.adjust_inventory(jsonb,uuid)'::regprocedure);
 s:=replace(s,'''opening'',''capital'',''gain''','''capital'',''gain''');
 s:=replace(s,'when ''opening'' then ''opening_equity'' ','');
 execute s;
 s:=pg_get_functiondef('public.accounting_operation(jsonb,uuid)'::regprocedure);
 s:=replace(s,'(''capital'',''opening_cash'')','(''capital'')');
 s:=replace(s,'(''loan_repay'',''capital'',''opening_cash'',''settle_obligation'')','(''loan_repay'',''capital'',''settle_obligation'')');
 s:=replace(s,'case when action=''opening_cash'' then ''opening_cash'' else ''owner_capital'' end','''owner_capital''');
 execute s;
end $$;
revoke all on function public.move_wallet_money(jsonb,uuid) from public,anon;
grant execute on function public.move_wallet_money(jsonb,uuid) to authenticated;
