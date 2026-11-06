-- Explicit action permissions. Only OWNER/platform administrators manage access.
insert into public.permissions(permission_id,module,label,description,owner_only,dependencies) values
 ('sales:discount','Sales','Apply checkout discounts','Apply a discount without changing saved product prices.',false,array['pos:sell']),
 ('finance:capital','Finance','Record capital contributions','Record owner investments and capital-funded acquisitions.',false,array['finance:manage']),
 ('finance:opening','Finance','Record opening positions','Record supported opening assets and liabilities.',false,array['finance:manage']),
 ('finance:loans:manage','Finance','Manage loans and lending','Record borrowing, lending and principal repayments.',false,array['finance:manage','finance:loans']),
 ('finance:assets:manage','Finance','Manage assets','Register, improve, depreciate and dispose of assets.',false,array['finance:manage']),
 ('finance:obligations:manage','Finance','Manage operating obligations','Record and settle unpaid operating costs.',false,array['finance:manage'])
 on conflict(permission_id) do nothing;
-- Preserve existing discount rights and replace the old explicit bundle in place.
insert into public.role_permissions(tenant_id,role_id,permission_id)
 select tenant_id,role_id,'sales:discount' from public.role_permissions where permission_id='pos:sell' on conflict do nothing;
insert into public.role_permissions(tenant_id,role_id,permission_id)
 select rp.tenant_id,rp.role_id,p.permission_id from public.role_permissions rp cross join public.permissions p
 where rp.permission_id='finance:owner' and p.permission_id in ('finance:capital','finance:opening','finance:loans:manage','finance:assets:manage','finance:obligations:manage','finance:loans') on conflict do nothing;
update app_private.user_permission_sets set permissions=(select coalesce(array_agg(distinct p order by p),'{}'::text[]) from unnest(
 array_remove(array_remove(permissions,'finance:owner'),'purchases:commission')
 ||case when 'pos:sell'=any(permissions) then array['sales:discount'] else '{}'::text[] end
 ||case when 'finance:owner'=any(permissions) then array['finance:capital','finance:opening','finance:loans:manage','finance:assets:manage','finance:obligations:manage','finance:loans'] else '{}'::text[] end) p);

do $$declare r record;s text;gate text;begin
 for r in select p.oid,p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in('public','app_private') and p.prosrc like '%finance:owner%' loop
  s:=pg_get_functiondef(r.oid);
  if r.proname='action_accounting_operation' then
   s:=replace(s,'app_private.require_permission(''finance:owner'')','app_private.require_permission(''finance:manage'')');
   s:=replace(s,'begin perform app_private.require_permission(''finance:manage'');', $gate$begin perform app_private.require_permission(case when action like 'loan_%' then 'finance:loans:manage' when action like 'asset_%' then 'finance:assets:manage' when action='capital' then 'finance:capital' when action='opening_entry' then 'finance:opening' when action='expense_accrue' then 'finance:obligations:manage' else 'finance:manage' end);
   if action='settle_obligation' then perform app_private.require_any_permission(array['finance:opening','finance:obligations:manage']);end if;
   if coalesce((p_payload->>'opening')::boolean,false) or p_payload->>'funding'='opening' then perform app_private.require_permission('finance:opening');end if;
   if p_payload->>'funding'='capital' then perform app_private.require_permission('finance:capital');end if;$gate$);
   s:=replace(s,'id:=ob.obligation_id;alloc:=ob.allocations;', $gate$perform app_private.require_permission(case when ob.origin='opening' then 'finance:opening' else 'finance:obligations:manage' end);id:=ob.obligation_id;alloc:=ob.allocations;$gate$);
   s:=replace(s,'if asset.vehicle_id is not null then','if asset.vehicle_id is not null then perform app_private.require_permission(''logistics:retire'');');
  elsif r.proname='action_record_financial_entry' then
   s:=replace(s,'app_private.require_permission(''finance:owner'')','app_private.require_permission(''finance:assets:manage'')');
   s:=replace(s,'if account=''capital'' then perform app_private.require_permission(''finance:assets:manage'')','if account=''capital'' then perform app_private.require_permission(''finance:capital'')');
  elsif r.proname='action_move_wallet_money' then
   s:=replace(s,'''finance:owner''','''finance:capital''');
   s:=replace(s,'case when action=''transfer'' then ''wallets:transfer'' else ''wallets:adjust'' end','case when action=''transfer'' then ''wallets:transfer'' when p_payload->>''classification''=''capital'' then ''finance:capital'' else ''wallets:adjust'' end');
  elsif r.proname='get_accounting_register' then
   s:=replace(s,'else perform app_private.require_permission(''finance:owner'');end if;', 'else perform app_private.require_permission(case p_kind when ''assets'' then ''finance:assets:manage'' when ''opening'' then ''finance:opening'' else ''finance:obligations:manage'' end);end if;');
  elsif r.proname='get_accounting_history' then s:=replace(s,'''finance:owner''','''finance:assets:manage''');
  else raise exception 'Unmapped retired financial permission in %',r.proname;
  end if;
  if position('finance:owner' in s)>0 then raise exception 'Retired guard remains in %',r.proname;end if;
  execute s;
 end loop;
 select pg_get_functiondef(oid) into s from pg_proc where oid='app_private.action_create_pos_sale(character varying,character varying,character varying,text,character varying,numeric,numeric,text,jsonb,uuid,uuid,jsonb,jsonb,date)'::regprocedure;
 s:=replace(s,'discount:=app_private.purchase_money(coalesce(p_discount_amount,0));','discount:=app_private.purchase_money(coalesce(p_discount_amount,0));if discount>0 then perform app_private.require_permission(''sales:discount'');end if;');execute s;
 select pg_get_functiondef(oid) into s from pg_proc where oid='public.get_purchase_settlement(uuid,integer,integer)'::regprocedure;
 s:=replace(s,'app_private.is_owner() and app_private.has_permission(''purchases:pay'')','app_private.has_permission(''purchases:rebates'') and app_private.has_permission(''purchases:manage'') and app_private.has_permission(''purchases:pay'')');execute s;
 -- New business MANAGER defaults must not automatically acquire sensitive grants.
 select pg_get_functiondef(oid) into s from pg_proc where oid='public.complete_account_operation(uuid)'::regprocedure;
 s:=replace(s,'r.name=''MANAGER'' and not p.owner_only', 'r.name=''MANAGER'' and not p.owner_only and p.permission_id<>all(array[''inventory:prices'',''inventory:mrp'',''inventory:buying_prices'',''inventory:adjust'',''sales:cancel'',''sales:refund'',''sales:backdate'',''purchases:cancel'',''purchases:rebates'',''logistics:retire'',''wallets:adjust'',''finance:capital'',''finance:opening'',''finance:loans:manage'',''finance:assets:manage'',''finance:obligations:manage''])');execute s;
end$$;
delete from public.role_permissions where permission_id in('finance:owner','purchases:commission');
delete from public.permissions where permission_id in('finance:owner','purchases:commission');
-- Effective permissions are part of AuthContext's cache fingerprint. Ordinary
-- account edits continue to increment their optimistic-concurrency revision.
drop function app_private.require_owner(text);
