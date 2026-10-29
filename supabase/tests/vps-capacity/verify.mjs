import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { createClient } from '@supabase/supabase-js';
import { randomUUID } from 'node:crypto';
import { state, frontend, read, save, sql, uuid } from './common.mjs';

export function preservation(originalIds) {
  const ids=originalIds.map(uuid).join(',')||'null::uuid';
  return JSON.parse(sql(`begin; set local statement_timeout='300s'; create temporary table capacity_preserve(name text,n bigint,hash text);
    create temporary table capacity_original as select tenant_id from public.tenants where tenant_id in (${ids});
    analyze capacity_original;
    do $preserve$ declare r record; condition text; begin
     for r in select table_name from information_schema.tables where table_schema='public' and table_type='BASE TABLE' order by table_name loop
      condition:=case when exists(select 1 from information_schema.columns where table_schema='public' and table_name=r.table_name and column_name='tenant_id') then ' where tenant_id in (select tenant_id from capacity_original)' else '' end;
      execute format('insert into capacity_preserve select %L,count(*),md5(coalesce(string_agg(md5(to_jsonb(r)::text),'''' order by md5(to_jsonb(r)::text)),'''')) from public.%I r%s',r.table_name,r.table_name,condition);
     end loop;
    end $preserve$;
    select jsonb_agg(to_jsonb(p) order by name) from capacity_preserve p; rollback;`).split('\n').at(-1));
}

export async function verify(label, { minimumSales=20000, auth=true }={}) {
  const manifest=read('manifest.json');
  const tenants=manifest.accounts.filter(a=>a.tenant_id).map(a=>a.tenant_id);
  const ids=tenants.map(uuid).join(',');
  const list = `(values ${tenants.map(t=>`(${uuid(t)})`).join(',')})`;
  const result=JSON.parse(sql(`begin; set local statement_timeout='300s';
   create temporary table ct as select column1 as tenant_id from ${list} t;
   analyze ct;
   create temporary table capacity_checks(name text,failures bigint);
   insert into capacity_checks select 'customer_count',count(*) from ct where (select count(*) from public.customers c where c.tenant_id=ct.tenant_id)<>2000;
   insert into capacity_checks select 'historical_sale_count',count(*) from ct where (select count(*) from public.sales s where s.tenant_id=ct.tenant_id)<${minimumSales};
   insert into capacity_checks
   select 'wallet_balance',count(*) from public.wallets w join ct using(tenant_id) where w.balance<>w.opening_balance+coalesce((select sum(amount) from public.wallet_transactions x where x.tenant_id=w.tenant_id and x.wallet_id=w.wallet_id),0);
   insert into capacity_checks
   select 'running_wallet_balance',count(*) from (select x.balance_after,w.opening_balance+sum(x.amount) over(partition by x.tenant_id,x.wallet_id order by x.entry_no) expected
    from public.wallet_transactions x join ct using(tenant_id) join public.wallets w using(tenant_id,wallet_id)) v where balance_after<>expected;
   insert into capacity_checks
   select 'stock_movement_reconciliation',count(*) from public.items i join ct using(tenant_id)
    left join (select m.tenant_id,m.item_id,sum(m.filled_quantity_change) filled,sum(m.empty_quantity_change) empty from public.inventory_movements m join ct using(tenant_id) group by m.tenant_id,m.item_id) m using(tenant_id,item_id)
    where i.filled_quantity<>coalesce(m.filled,0) or i.empty_quantity<>coalesce(m.empty,0);
   insert into capacity_checks
   select 'sale_header_payments',count(*) from public.sales s join ct using(tenant_id)
    left join (select p.tenant_id,p.sale_id,sum(p.amount) paid,sum(p.amount) filter(where p.phase='checkout') checkout from public.sale_payments p join ct using(tenant_id) group by p.tenant_id,p.sale_id) p using(tenant_id,sale_id)
    left join (select l.tenant_id,l.sale_id,sum(l.line_total) subtotal from public.sale_items l join ct using(tenant_id) group by l.tenant_id,l.sale_id) l using(tenant_id,sale_id)
    where s.paid_amount<>coalesce(p.paid,0)
     or s.paid_at_checkout<>coalesce(p.checkout,0)
     or s.total_amount<>s.subtotal-s.discount_amount+s.exchange_fee
     or s.subtotal<>coalesce(l.subtotal,0)
     or s.paid_amount<0 or s.paid_amount>s.total_amount+s.additional_charges;
   insert into capacity_checks
   select 'payment_wallet_customer_attribution',count(*) from public.sale_payments p join ct using(tenant_id)
    join public.sales s using(tenant_id,sale_id)
    left join public.wallet_transactions x on x.tenant_id=p.tenant_id and x.payment_id=p.payment_id
    left join public.customer_transactions c on c.tenant_id=p.tenant_id and c.payment_id=p.payment_id
    where x.transaction_id is null or c.transaction_id is null or x.wallet_id<>p.wallet_id or x.amount<>p.amount or c.amount<>p.amount
     or c.customer_id<>s.customer_id or c.reference_id is distinct from p.sale_id or x.reference_id is distinct from p.sale_id
     or c.type<>'payment_receipt' or x.type<>case when p.phase='checkout' then 'pos_sale_income' else 'customer_collection' end;
   insert into capacity_checks
   select 'customer_dues_ledger',count(*) from public.customers c join ct using(tenant_id)
    left join (select x.tenant_id,x.customer_id,sum(x.amount) balance from public.customer_transactions x join ct using(tenant_id) group by x.tenant_id,x.customer_id) x using(tenant_id,customer_id)
    left join (select s.tenant_id,s.customer_id,sum(s.total_amount+s.additional_charges-s.paid_amount) due from public.sales s join ct using(tenant_id) where status='completed' group by s.tenant_id,s.customer_id) s using(tenant_id,customer_id)
    where coalesce(x.balance,0)<>-coalesce(s.due,0);
   insert into capacity_checks
   select 'purchase_paid_evidence',count(*) from public.purchases p join ct using(tenant_id)
    left join (select x.tenant_id,x.reference_id purchase_id,sum(x.amount) amount from public.wallet_transactions x
      join ct using(tenant_id) join public.wallets w using(tenant_id,wallet_id)
      join public.purchases pr on pr.tenant_id=x.tenant_id and pr.purchase_id=x.reference_id
      where w.kind<>'logistics' group by x.tenant_id,x.reference_id) x using(tenant_id,purchase_id)
    where p.status<>'cancelled' and p.paid_amount<>-coalesce(x.amount,0);
   insert into capacity_checks
   select 'negative_stock',count(*) from public.items i join ct using(tenant_id) where i.filled_quantity<0 or i.empty_quantity<0;
   insert into capacity_checks
   select 'bottle_receipt_obligations',count(*) from public.sales s join ct using(tenant_id)
    left join (select l.tenant_id,l.sale_id,sum(l.quantity) expected from public.sale_items l join ct using(tenant_id) where type='empty_return' group by l.tenant_id,l.sale_id) l using(tenant_id,sale_id)
    left join (select r.tenant_id,r.sale_id,sum(r.quantity) received from public.sale_bottle_receipt_lines r join ct using(tenant_id) group by r.tenant_id,r.sale_id) r using(tenant_id,sale_id)
    where coalesce(l.expected,0)<>coalesce(r.received,0);
   insert into capacity_checks select 'leftover_fixture_date_triggers',count(*) from pg_trigger where tgname='zzz_lpg_capacity_date';
   select jsonb_build_object('checks',(select jsonb_object_agg(name,failures) from capacity_checks),
    'counts',(select jsonb_build_object('businesses',count(*),'customers',(select count(*) from public.customers join ct using(tenant_id)),
      'sales',(select count(*) from public.sales join ct using(tenant_id)), 'lines',(select count(*) from public.sale_items join ct using(tenant_id)),
      'purchases',(select count(*) from public.purchases join ct using(tenant_id)), 'payments',(select count(*) from public.sale_payments join ct using(tenant_id)),
      'wallet_entries',(select count(*) from public.wallet_transactions join ct using(tenant_id)),
      'inventory_movements',(select count(*) from public.inventory_movements join ct using(tenant_id))) from ct),
    'database_bytes',pg_database_size(current_database()),'time',extract(epoch from now())); rollback;`).split('\n').at(-1));
  save(`verification-${label}.json`,result);
  assert(Object.values(result.checks).every(n=>n===0),'Database reconciliation failed: '+JSON.stringify(result.checks));
  if (auth && manifest.accounts.length>1) {
    let probes=0;
    for (let i=0;i<Math.min(manifest.accounts.length,5);i++) {
      const a=manifest.accounts[i], foreign=manifest.accounts[(i+1)%manifest.accounts.length];
      const client=createClient(frontend.VITE_SUPABASE_URL,frontend.VITE_SUPABASE_ANON_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
      const token=await client.auth.setSession({access_token:a.token,refresh_token:a.refresh_token});
      assert.ifError(token.error);
      if (token.data.session) {
        a.token=token.data.session.access_token; a.refresh_token=token.data.session.refresh_token; a.expires_at=token.data.session.expires_at;
      }
      const profile=await client.from('user_profiles').select('tenant_id,is_active').eq('user_id',a.user_id).single();
      assert.ifError(profile.error); assert.equal(profile.data.tenant_id,a.tenant_id); assert(profile.data.is_active);
      const direct=await client.from('items').select('item_id').eq('tenant_id',foreign.tenant_id);
      assert.ifError(direct.error); assert.deepEqual(direct.data,[]);
      const rpc=await client.rpc('get_product_inventory',{p_item_id:foreign.item_ids[0]});
      assert(rpc.error || rpc.data===null,'Foreign item RPC unexpectedly returned data');
      const foreignSale=sql(`select sale_id from public.sales where tenant_id=${uuid(foreign.tenant_id)} order by sale_id limit 1;`);
      if(foreignSale) {
        const settlement=await client.rpc('get_sale_settlement',{p_sale_id:foreignSale});
        assert(settlement.error,'Foreign settlement read succeeded');
        const collection=await client.rpc('collect_sale_payment',{p_sale_id:foreignSale,
          p_payments:[{wallet_id:a.cash.wallet_id,amount:1}],p_request_id:randomUUID()});
        assert(collection.error,'Foreign sale collection succeeded');
      }
      const transfer=await client.rpc('move_wallet_money',{p_payload:{action:'transfer',wallet_id:foreign.cash.wallet_id,
        destination_id:a.bank.wallet_id,amount:1,reason:'Capacity denied isolation probe'},p_request_id:randomUUID()});
      assert(transfer.error,'Foreign source wallet transfer succeeded');
      probes++;
    }
    result.auth_isolation_probes=probes; save(`verification-${label}.json`,result); save('manifest.json',manifest);
  }
  if (existsSync(resolve(state,'original-businesses.json'))) {
    const after=preservation(read('original-businesses.json'));
    assert.deepEqual(after,read('preservation-before.json'),'Non-fixture business fingerprints changed');
    save(`preservation-${label}.json`,after);
  }
  console.log(`PASS ${label}: ${result.counts.businesses} businesses; ${result.counts.sales} sales; all ${Object.keys(result.checks).length} reconciliation checks and preservation passed.`);
  return result;
}

if (process.argv[1]?.endsWith('verify.mjs')) {
  if (process.argv[2]==='baseline') {
    const fixtureIds=read('manifest.json').accounts.filter(a=>a.tenant_id).map(a=>a.tenant_id);
    const original=JSON.parse(sql(`select coalesce(jsonb_agg(tenant_id),'[]') from public.tenants where business_name not like 'VPS Capacity ${read('manifest.json').run}%' and ${fixtureIds.length?'tenant_id not in ('+fixtureIds.map(uuid).join(',')+')':'true'};`));
    save('original-businesses.json',original); save('preservation-before.json',preservation(original));
    console.log(`Fingerprinted all public tables for ${original.length} non-fixture businesses.`);
  } else await verify(process.argv[2]||'manual',{minimumSales:Number(process.argv[3]||20000),auth:!process.argv.includes('--no-auth')});
}
