-- Individual wallet visibility does not require access to the Finance workspace.
CREATE OR REPLACE FUNCTION public.get_finance_wallets()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare t uuid:=app_private.current_tenant_id();begin
 if t is null then raise insufficient_privilege;end if;
 return coalesce((select jsonb_agg((to_jsonb(w)-'balance'-'opening_balance') || jsonb_build_object(
 'balance',case when app_private.wallet_allowed(w.wallet_id,'balance') then w.balance end,
 'opening_balance',case when app_private.wallet_allowed(w.wallet_id,'balance') then w.opening_balance end,
 'can_use',app_private.wallet_allowed(w.wallet_id,'use'),'can_balance',app_private.wallet_allowed(w.wallet_id,'balance'),'can_history',app_private.wallet_allowed(w.wallet_id,'history')) order by w.created_at,w.wallet_id)
 from public.wallets w where w.tenant_id=t and (app_private.wallet_allowed(w.wallet_id,'use') or app_private.wallet_allowed(w.wallet_id,'balance') or app_private.wallet_allowed(w.wallet_id,'history'))),'[]');end$function$

;
notify pgrst,'reload schema';
