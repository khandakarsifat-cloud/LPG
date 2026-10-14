do $$
declare id uuid; p public.purchases; before_balance numeric; payload jsonb; transit uuid;
begin
  if exists((select * from public.items except select * from legacy_stock_snapshot) union all
    (select * from legacy_stock_snapshot except select * from public.items)) then raise exception 'Migration changed historical stock'; end if;
  if exists((select * from public.wallets except select * from legacy_wallet_snapshot) union all
    (select * from legacy_wallet_snapshot except select * from public.wallets)) then raise exception 'Migration changed historical wallet balances'; end if;
  if exists((select * from public.inventory_movements except select * from legacy_movement_snapshot) union all
    (select * from legacy_movement_snapshot except select * from public.inventory_movements)) then raise exception 'Migration changed historical movements'; end if;
  if exists((select * from public.wallet_transactions except select * from legacy_transaction_snapshot) union all
    (select * from legacy_transaction_snapshot except select * from public.wallet_transactions)) then raise exception 'Migration changed historical accounting'; end if;
  perform set_config('request.jwt.claim.sub','ab000000-0000-4000-8000-000000000001',false);
  select h.* into p from public.purchases h join legacy_purchases l on l.id=h.purchase_id where l.kind='received';
  if p.payment_status<>'paid' or p.total_cost<>230 or p.company_payable<>200 or not p.legacy_record then raise exception 'Historical receipt was not retained as paid'; end if;
  select balance into before_balance from public.wallets where type='dealership';
  perform public.pay_purchase(p.purchase_id,p.revision);
  if (select balance from public.wallets where type='dealership')<>before_balance then raise exception 'Historical payment replayed'; end if;
  select l.id into id from legacy_purchases l where kind='in_transit';
  if (select payment_status from public.purchases where purchase_id=id)<>'unpaid' then raise exception 'Legacy shipment payment status incorrect'; end if;
  select jsonb_agg(jsonb_build_object('purchase_item_id',purchase_item_id,'received_quantity',quantity)) into payload from public.purchase_items where purchase_id=id;
  perform public.receive_purchase(id,payload,'Historical shipment return',1);
  if (select empty_quantity from public.items where item_id='ab000000-0000-4000-8000-000000000004')<>15 then raise exception 'Legacy empties dispatched twice'; end if;
  before_balance := (select balance from public.wallets where type='logistics');
  perform public.pay_purchase(id,2);
  if (select balance from public.wallets where type='logistics')<>before_balance then raise exception 'Legacy transport credit replayed'; end if;
  if (select balance from public.wallets where type='dealership')<>-565 then raise exception 'Legacy new payment incorrect'; end if;
  select tr.transit_id into transit from public.transits tr join legacy_purchases lp on lp.id=tr.purchase_id where lp.kind='received';
  if not exists(select 1 from public.list_transits() x where (x->>'transit_id')::uuid=transit and (x->>'legacy_completion')::boolean) then
    raise exception 'Historical received transit cannot be finalized'; end if;
  perform public.update_transit_costs(transit,5,0,0,'[]','completed');
  if (select status from public.transits where transit_id=transit)<>'completed' then raise exception 'Historical transit finalization failed'; end if;
  perform set_config('request.jwt.claim.sub','',false);
end $$;
select 'PASS: historical stock/ledger preservation, received payments, pending receipt, transport compatibility and orphan transit completion';
