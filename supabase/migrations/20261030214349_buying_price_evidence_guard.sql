-- Keep intentional manual prices when no receipt calculation exists. Missing
-- price evidence must never become a zero external cost through GREATEST.
create or replace function public.set_product_buying_price(p_payload jsonb,p_request_id uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare t uuid:=app_private.require_permission('inventory:manage');prior public.finance_requests;body jsonb:=jsonb_build_object('action','buying_price','actor',auth.uid(),'body',p_payload);
 id uuid:=(p_payload->>'item_id')::uuid;kind text:=p_payload->>'price_type';manual boolean:=(p_payload->>'is_manual')::boolean;
 prev public.product_buying_price_history;price numeric;external numeric;r jsonb;hid uuid;begin
 if not app_private.can_manage_inventory_prices() then raise exception 'Only the owner can edit buying prices' using errcode='42501';end if;
 if p_request_id is null then raise exception 'Request ID is required';end if;
 perform pg_advisory_xact_lock(hashtextextended(t::text||p_request_id::text,0));select * into prior from public.finance_requests where tenant_id=t and request_id=p_request_id;
 if found then if prior.payload<>body then raise exception 'Request ID was already used with different details';end if;return prior.result;end if;
 if kind is null or kind not in ('refill','package') or manual is null or nullif(trim(p_payload->>'reason'),'') is null or length(p_payload->>'reason')>1000 then raise exception 'Choose a price type, mode and reason';end if;
 perform 1 from public.items where tenant_id=t and item_id=id for update;if not found then raise exception 'Product not found';end if;
 select * into prev from public.product_buying_price_history where tenant_id=t and item_id=id and price_type=kind order by effective_at desc,entry_no desc limit 1;
 if prev.history_id is distinct from nullif(p_payload->>'expected','')::uuid then raise exception 'Buying price changed. Reload before saving.';end if;
 if not manual and prev.automatic_price is null then raise exception 'No automatic buying price is available. Receive a purchase before restoring automatic pricing.';end if;
 price:=case when manual then app_private.purchase_money((p_payload->>'price')::numeric) else prev.automatic_price end;
 external:=greatest(0,round(price-coalesce(prev.transport_per_unit,0),2));
 insert into public.product_buying_price_history(tenant_id,item_id,price_type,previous_price,new_price,automatic_price,is_manual,external_cost,bottle_cost,overhead_per_unit,transport_per_unit,commission_per_unit,purchase_id,commission_id,source,reason,effective_at,created_by)
 values(t,id,kind,prev.new_price,price,prev.automatic_price,manual,external,prev.bottle_cost,prev.overhead_per_unit,prev.transport_per_unit,prev.commission_per_unit,prev.purchase_id,prev.commission_id,
 case when manual then 'manual' else 'restore_automatic' end,trim(p_payload->>'reason'),clock_timestamp(),auth.uid()) returning history_id into hid;
 r:=jsonb_build_object('history_id',hid);insert into public.finance_requests(tenant_id,request_id,payload,result,created_by) values(t,p_request_id,body,r,auth.uid());return r;
end $$;
revoke all on function public.set_product_buying_price(jsonb,uuid) from public,anon,authenticated;
grant execute on function public.set_product_buying_price(jsonb,uuid) to authenticated;
notify pgrst,'reload schema';
