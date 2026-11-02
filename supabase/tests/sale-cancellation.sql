-- Restored disposable database only. Every operation in this suite rolls back.
begin;
create function pg_temp.check_cancel(ok boolean,note text) returns void language plpgsql as $$begin if ok is not true then raise exception 'FAIL: %',note;end if;end $$;
-- Reproduce the reported retained-lab examples on the COPY, never the live lab.
do $$declare s record;failures text[]:='{}';begin
 for s in select sale_id,tenant_id from public.sales where sale_id in ('a1505e21-864a-404d-a29b-5c01172b3de5','8f7d2834-4fa7-4c22-aa0c-4c0ac30fc4b3') and status='completed' loop
  begin
   perform set_config('request.jwt.claim.sub',(select ur.user_id::text from public.user_roles ur join public.roles r using(tenant_id,role_id) where ur.tenant_id=s.tenant_id and r.name='OWNER' limit 1),true);
   perform public.reverse_sale(s.sale_id,'Disposable copy reproduction','CANCEL',gen_random_uuid());
   raise exception using errcode='ZX001',message='successful reproduction rolled back';
  exception when sqlstate 'ZX001' then null;when others then failures:=array_append(failures,left(s.sale_id::text,8)||': '||sqlerrm);
  end;
 end loop;
 if cardinality(failures)>0 then raise exception 'Reported cancellation regressions: %',array_to_string(failures,'; ');end if;
end $$;
select 'PASS: both reported sales cancel on disposable copy without modifying retained labs';
insert into auth.users(id,email,is_anonymous) values('ca110000-0000-4000-8000-000000000001','cancel-regression@example.invalid',false);
set local role authenticated;
select set_config('request.jwt.claim.sub','ca110000-0000-4000-8000-000000000001',true);
select public.setup_business('Disposable sale cancellation regression','Owner');
reset role;
do $$declare t uuid:=app_private.current_tenant_id();a uuid;b uuid;brand uuid;wallet uuid;s uuid;key uuid;result jsonb;mode text;n integer:=0;received integer;lines jsonb;receipt jsonb;paid numeric;before_cash numeric;before_other jsonb;d date:=(now() at time zone 'Asia/Dhaka')::date;full_position jsonb;begin
 select wallet_id into wallet from public.get_payment_wallets() where type='cash';
 foreach mode in array array['none','partial','full','excess','cross-product','mixed-package-refill','later-collection','consumed'] loop
  n:=n+1;brand:=pg_temp.fixture_brand(t,'Cancellation '||mode);
  insert into public.items(tenant_id,brand_id,size_kg,mouth_size) values(t,brand,12,'22mm') returning item_id into a;
  insert into public.items(tenant_id,brand_id,size_kg,mouth_size) values(t,brand,35,'22mm') returning item_id into b;
  -- Older empties cost 1000; issued cylinder shells cost 1800. Cancellation
  -- must remove this sale's received layer rather than consume the older FIFO.
  perform public.adjust_inventory(jsonb_build_object('item_id',a,'kind','opening','filled_quantity',0,'empty_quantity',10,'empty_unit_cost',1000,'reason','Older empties'),gen_random_uuid());
  perform public.adjust_inventory(jsonb_build_object('item_id',a,'kind','opening','filled_quantity',10,'empty_quantity',0,'filled_unit_cost',2500,'empty_unit_cost',1800,'reason','Filled batch with distinct shell cost'),gen_random_uuid());
  perform public.adjust_inventory(jsonb_build_object('item_id',b,'kind','opening','filled_quantity',0,'empty_quantity',10,'empty_unit_cost',1000,'reason','Cross-product empties'),gen_random_uuid());
  insert into public.price_books(tenant_id,item_id,price_type,customer_tier,price,effective_from) values(t,a,'refill','retail',1300,now()-interval '1 day'),(t,a,'package','retail',3000,now()-interval '1 day');
  received:=case mode when 'none' then 0 when 'full' then 2 when 'excess' then 0 when 'cross-product' then 0 when 'later-collection' then 0 else 1 end;
  lines:=jsonb_build_array(jsonb_build_object('item_id',a,'type','refill','quantity',2,'unit_price',1300),jsonb_build_object('item_id',a,'type','empty_return','quantity',2,'unit_price',0));
  if mode='mixed-package-refill' then lines:=lines||jsonb_build_array(jsonb_build_object('item_id',a,'type','package','quantity',1,'unit_price',3000));end if;
  receipt:=jsonb_build_object('lines',case when received=0 then '[]'::jsonb else jsonb_build_array(jsonb_build_object('received_item_id',case when mode='cross-product' then b else a end,'quantity',received,'acknowledged',true)) end);
  paid:=case when mode='full' then 2600 when mode in ('partial','excess','later-collection') then 500 else 0 end;
  s:=(public.create_pos_sale('01780000'||lpad(n::text,3,'0'),'Cancellation '||mode,null,null,'retail',0,0,null,lines,null,gen_random_uuid(),case when paid=0 then '[]'::jsonb else jsonb_build_array(jsonb_build_object('wallet_id',wallet,'amount',paid)) end,receipt)->>'sale_id')::uuid;
  if mode in ('later-collection','cross-product','excess') then perform public.collect_sale_bottles(s,jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('received_item_id',case when mode='cross-product' then b else a end,'quantity',case when mode='excess' then 3 else 1 end,'acknowledged',true)),'fee',25,'note','Later bottle receipt'),gen_random_uuid());end if;
  select balance into before_cash from public.wallets where tenant_id=t and wallet_id=wallet;
  if mode='consumed' then
   perform public.adjust_inventory(jsonb_build_object('item_id',a,'kind','other_loss','filled_quantity',0,'empty_quantity',-11,'reason','Consume actual receipt batch'),gen_random_uuid());
   perform public.adjust_inventory(jsonb_build_object('item_id',a,'kind','gain','filled_quantity',0,'empty_quantity',11,'empty_unit_cost',1800,'reason','Distinct replacement stock'),gen_random_uuid());
   select to_jsonb(i) into before_other from public.items i where tenant_id=t and item_id=a;
   begin
    perform public.reverse_sale(s,'Cannot return consumed batch','CANCEL',gen_random_uuid());
    raise exception 'FAIL: consumed original receipt was allowed';
   exception when others then if sqlerrm not like '%received bottle batch%consumed%' then raise;end if;end;
   perform pg_temp.check_cancel((select to_jsonb(i)=before_other from public.items i where tenant_id=t and item_id=a),'Rejected cancellation preserves stock');
   perform pg_temp.check_cancel((select status='completed' from public.sales where tenant_id=t and sale_id=s),'Rejected cancellation preserves sale');
   continue;
  end if;
  key:=gen_random_uuid();result:=public.reverse_sale(s,'Regression return','CANCEL',key);
  perform pg_temp.check_cancel(public.reverse_sale(s,'Regression return','CANCEL',key)=result,'Original request retry returns once');
  perform pg_temp.check_cancel((select filled_quantity=10 and empty_quantity=10 and filled_value=25000 and empty_value=10000 from public.inventory_costs where tenant_id=t and item_id=a),mode||': exact original stock and value restored');
  perform pg_temp.check_cancel((select empty_quantity=10 and empty_value=10000 from public.inventory_costs where tenant_id=t and item_id=b),mode||': exchanged SKU restored');
  perform pg_temp.check_cancel((select balance=before_cash from public.wallets where tenant_id=t and wallet_id=wallet),'Cancellation never invents a cash refund');
  perform pg_temp.check_cancel((result->>'refund_due')::numeric=paid,'Refund due equals actual payments');
  perform pg_temp.check_cancel((select coalesce(sum(amount),0)=0 from public.accounting_lines where tenant_id=t and entity_id=s and account in ('bottle_receivable','sales_revenue','customer_receivable')) or paid>0,'No outstanding sale/bottle recognition remains');
  result:=public.get_sales_directory(jsonb_build_object('status','cancelled','search',s::text),0,1);
  perform pg_temp.check_cancel((result->>'total')::integer=1 and result->'entries'->0->>'status'='voided','Cancelled status returns the cancelled sale');
  perform pg_temp.check_cancel((public.get_sales_directory(jsonb_build_object('status','paid','search',s::text))->>'total')::integer=0,'Cancelled sale is never classified as paid');
  perform pg_temp.check_cancel((public.get_sales_directory(jsonb_build_object('status','all','search',s::text))->>'total')::integer=1,'All statuses includes cancelled sales');
  perform pg_temp.check_cancel((public.get_sales_directory(jsonb_build_object('bottles','received','search',s::text))->>'total')::integer=0,'Cancelled does not mean bottles fully settled');
  if paid>0 then perform public.refund_sale(s,jsonb_build_array(jsonb_build_object('wallet_id',wallet,'amount',paid)),gen_random_uuid());end if;
 end loop;
 -- A later revaluation/rebuild must preserve exact original-layer reversals.
 perform app_private.rebuild_fifo_set(t,(select array_agg(item_id order by item_id) from public.items where tenant_id=t));
 perform pg_temp.check_cancel((public.get_sales_overview()->>'total')::integer=(select count(*) from public.sales where tenant_id=t),'Overview and directory count saved cancellations consistently');
 -- Source typing, linked details, stock/journal/layer and savepoint positions.
 perform pg_temp.check_cancel(not exists(select 1 from public.accounting_lines l join public.accounting_journals j using(tenant_id,journal_id) where l.tenant_id=t and j.source='bottle_reversal' and (l.type_id<>app_private.system_type('sale_reversal') or app_private.financial_source_link(t,j.source,j.source_id)->>'record_kind'<>'sale')),'Bottle cancellation retains fixed type and sale source link');
 perform pg_temp.check_cancel(not exists(select 1 from public.inventory_costs c where tenant_id=t and filled_value+empty_value<>(select coalesce(sum(remaining_value),0) from app_private.fifo_layers l where l.tenant_id=t and l.item_id=c.item_id)),'All FIFO layers reconcile');
 select app_private.position_from_balances(coalesce(jsonb_agg(to_jsonb(x)),'[]')) into full_position from(select l.tenant_id,l.account,l.business_category,l.entity_id,sum(l.amount) amount from public.accounting_lines l join public.accounting_journals j using(tenant_id,journal_id) where l.tenant_id=t and j.occurred_on<=d group by 1,2,3,4)x;
 perform pg_temp.check_cancel(full_position=app_private.accounting_position(array[t],d),'Cached position equals full journal recomputation');
 perform pg_temp.check_cancel(not exists(select 1 from public.accounting_journals j join public.accounting_lines l using(tenant_id,journal_id) where j.tenant_id=t group by j.journal_id having sum(l.amount)<>0 or sum(l.consolidated_amount)<>0),'All journals remain balanced');
end $$;
select 'PASS: no/partial/full/excess/cross-product/mixed/later bottle returns, paid/unpaid/refunds, exact layers, consumed guard, retries, statuses, and journal reconciliation';
rollback;
