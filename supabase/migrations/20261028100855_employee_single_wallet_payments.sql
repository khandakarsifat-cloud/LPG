-- Keep historical wallet attribution and reversals intact. New salary/bonus
-- payments use one wallet; independent partial payments can use other wallets.
do $$ declare definition text; old_guard text; begin
 old_guard:='if jsonb_typeof(item->''payments'') is distinct from ''array'' or jsonb_array_length(item->''payments'') not between 1 and 20 then raise exception ''Use one to twenty payment entries''; end if;';
 definition:=pg_get_functiondef('public.employee_payment_operation(jsonb,uuid)'::regprocedure);
 if position(old_guard in definition)=0 then raise exception 'Unexpected employee payment validation'; end if;
 definition:=replace(definition,old_guard,old_guard||E'\n if kind in (''salary'',''bonus'') and jsonb_array_length(item->''payments'')<>1 then raise exception ''Choose one wallet per salary or bonus payment''; end if;');
 execute definition;
end $$;
notify pgrst,'reload schema';
