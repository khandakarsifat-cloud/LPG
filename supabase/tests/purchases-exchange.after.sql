-- Verify migration preservation before exercising saved pre-change plans.
do $$
declare id uuid; p public.purchases; lines jsonb;
begin
  if exists((select * from public.items except select * from exchange_stock_snapshot) union all
    (select * from exchange_stock_snapshot except select * from public.items)) then raise exception 'Exchange migration changed stock'; end if;
  if exists((select * from public.wallets except select * from exchange_wallet_snapshot) union all
    (select * from exchange_wallet_snapshot except select * from public.wallets)) then raise exception 'Exchange migration changed wallets'; end if;
  if exists((select * from public.inventory_movements except select * from exchange_movement_snapshot) union all
    (select * from exchange_movement_snapshot except select * from public.inventory_movements)) then raise exception 'Exchange migration changed movements'; end if;
  if exists((select * from public.wallet_transactions except select * from exchange_transaction_snapshot) union all
    (select * from exchange_transaction_snapshot except select * from public.wallet_transactions)) then raise exception 'Exchange migration changed transactions'; end if;
  if exists((select * from public.purchase_items except select * from exchange_lines_snapshot) union all
    (select * from exchange_lines_snapshot except select * from public.purchase_items)) then raise exception 'Exchange migration rewrote saved lines'; end if;
  if exists((select * from public.purchases except select * from exchange_header_snapshot) union all
    (select * from exchange_header_snapshot except select * from public.purchases)) then raise exception 'Exchange migration changed purchase headers'; end if;
  if exists((select * from public.transits except select * from exchange_transit_snapshot) union all
    (select * from exchange_transit_snapshot except select * from public.transits)) then raise exception 'Exchange migration changed transits'; end if;
  perform set_config('request.jwt.claim.sub','ac000000-0000-4000-8000-000000000001',false);
  select e.id into id from exchange_purchases e where kind='draft';
  begin
    perform public.dispatch_purchase(id,1);
    raise exception 'FAIL: unequal Created plan dispatched';
  exception when others then
    if position('one empty cylinder per refill' in sqlerrm)=0 then raise; end if;
  end;
  if (select empty_quantity from public.items where item_id='ac000000-0000-4000-8000-000000000004')<>14 then raise exception 'Rejected dispatch moved stock'; end if;
  perform public.update_purchase(id,'{"items":[{"item_id":"ac000000-0000-4000-8000-000000000004","type":"refill","quantity":4,"unit_price":100}]}',1);
  if (select empty_dispatched from public.purchase_items where purchase_id=id)<>4 then raise exception 'Draft save did not derive exchange quantity'; end if;
  perform public.dispatch_purchase(id,2);
  if (select empty_quantity from public.items where item_id='ac000000-0000-4000-8000-000000000004')<>10 then raise exception 'Canonical draft dispatch has wrong stock'; end if;
  select e.id into id from exchange_purchases e where kind='dispatched';
  select jsonb_agg(to_jsonb(pi)) into lines from public.purchase_items pi where purchase_id=id;
  lines := jsonb_set(lines,'{0,unit_price}','110');
  perform public.update_purchase(id,jsonb_build_object('items',lines),2);
  if (select empty_dispatched from public.purchase_items where purchase_id=id)<>6 then raise exception 'Saved shipment empties changed on financial edit'; end if;
  perform public.pay_purchase(id,3);
  select jsonb_agg(jsonb_build_object('purchase_item_id',purchase_item_id,'received_quantity',3)) into lines from public.purchase_items where purchase_id=id;
  perform public.receive_purchase(id,lines,'Short one refill',4);
  select * into p from public.purchases where purchase_id=id;
  if p.total_cost<>440 or p.payment_status<>'paid' or p.status<>'received' then raise exception 'Saved shipment prepaid bill changed'; end if;
  if (select empty_quantity from public.items where item_id='ac000000-0000-4000-8000-000000000004')<>10
    or (select filled_quantity from public.items where item_id='ac000000-0000-4000-8000-000000000004')<>8 then raise exception 'Saved independent shipment stock incorrect'; end if;
  perform set_config('request.jwt.claim.sub','',false);
end $$;
select 'PASS: exchange migration preserves stock, ledger and saved lines; old drafts require save; dispatched independent quantities and prepaid receipts stay compatible';
