"""Preparation only; actual domain RPCs, constraints and posting triggers stay enabled.

Runs on the verified VPS over SSH. Never emits credentials or raw database errors.
Fixture-only insert timestamp triggers exist inside one bounded seed transaction,
are removed before commit, and never change non-fixture rows or application code.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.request
import shutil

COMMAND = ['docker', 'exec', '-i', 'lpg-db-1', 'psql', '-X', '-U', 'supabase_admin',
           '-d', 'postgres', '-qAt', '-v', 'ON_ERROR_STOP=1']


def sql(query):
    result = subprocess.run(COMMAND, input=query, text=True, capture_output=True, timeout=180)
    if result.returncode:
        Path('/tmp/lpg-capacity-private-error').write_text(result.stderr)
        os.chmod('/tmp/lpg-capacity-private-error', 0o600)
        raise RuntimeError('Seed SQL failed; private error retained on verified VPS')
    return result.stdout.strip()


def uid(value):
    import uuid
    return "'%s'::uuid" % uuid.UUID(value)


def provision(payload):
    # Reuse Auth's established internal URL/key, in memory only.
    auth = json.loads(subprocess.check_output(['docker', 'inspect', 'lpg-auth-1']))[0]
    env = dict(x.split('=', 1) for x in auth['Config']['Env'] if '=' in x)
    gateway = json.loads(subprocess.check_output(['docker', 'inspect', 'lpg-api-gw-1']))[0]
    gate_env = dict(x.split('=', 1) for x in gateway['Config']['Env'] if '=' in x)
    key = gate_env.get('SERVICE_ROLE_KEY')
    if not key:
        rest = json.loads(subprocess.check_output(['docker', 'inspect', 'lpg-storage-1']))[0]
        key = dict(x.split('=', 1) for x in rest['Config']['Env'] if '=' in x)['SERVICE_KEY']
    result = []
    for account in payload['accounts']:
        data = json.dumps({'email': account['email'], 'password': account['password'],
                           'email_confirm': True}).encode()
        request = urllib.request.Request('http://127.0.0.1:54321/auth/v1/admin/users', data=data,
            headers={'apikey': key, 'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=20) as response:
            user = json.load(response)
        result.append({'index': account['index'], 'user_id': user['id']})
    print(json.dumps(result), flush=True)


def seed(p):
    memory = {x.split(':')[0]:int(x.split()[1])*1024 for x in Path('/proc/meminfo').read_text().splitlines() if x.split(':')[0]=='MemAvailable'}
    if memory['MemAvailable'] < 768*1024**2 or shutil.disk_usage('/opt/lpg').free < 15*1024**3:
        raise RuntimeError('Preparation resource safety limit reached')
    t, actor, brand, plant, truck = (uid(p[k]) for k in ['tenant_id', 'user_id', 'brand_id', 'plant_id', 'truck_id'])
    start, count = p['start'], p['count']
    assert 0 <= start < 20000 and 1 <= count <= 500 and start + count <= 20000
    tables = ['sales', 'sale_payments', 'sale_bottle_receipts', 'customer_transactions',
              'wallet_transactions', 'inventory_movements', 'purchases', 'purchase_payments',
              'purchase_activity', 'transits', 'finance_requests']
    # No persistent helper, schema, disabled trigger, or overwritten application function.
    stamp = f"""
      create function pg_temp.lpg_capacity_date() returns trigger language plpgsql as $stamp$
      begin
       if new.tenant_id={t} and nullif(current_setting('lpg.fixture_history_at',true),'') is not null then
        new.created_at:=current_setting('lpg.fixture_history_at')::timestamptz;
       end if;
       return new;
      end $stamp$;
    """
    stamp += '\n'.join(f'create trigger zzz_lpg_capacity_date before insert on public.{table} for each row execute function pg_temp.lpg_capacity_date();' for table in tables)
    unstamp = '\n'.join(f'drop trigger zzz_lpg_capacity_date on public.{table};' for table in tables)
    if p.get('parallel_dates'):
        stamp = f"select set_config('lpg.fixture_tenant',{t}::text,true);"
        unstamp = ''
    query = f"""begin; set local lock_timeout='1s'; set local statement_timeout='120s';
      do $guard$ begin
       if not exists(select 1 from public.tenants where tenant_id={t} and business_name like 'VPS Capacity %')
        or not exists(select 1 from public.user_profiles where tenant_id={t} and user_id={actor}) then
        raise exception 'Not an exact capacity fixture'; end if;
      end $guard$;
      {stamp}
      set local role authenticated;
      select set_config('request.jwt.claim.sub',{actor}::text,true);
      do $seed$
      declare n integer; c public.customers; sku uuid; sid uuid; pid uuid; w uuid; bank uuid;
       cart jsonb; result jsonb; paid numeric; amount numeric; qty integer; i integer; j integer;
      begin
       select wallet_id into w from public.wallets where tenant_id={t} and type='cash';
       select wallet_id into bank from public.wallets where tenant_id={t} and type='dealership';
       for n in {start}..{start+count-1} loop
        perform set_config('lpg.fixture_history_at',
          (date_trunc('day',now())-interval '180 days'+(n/112)*interval '1 day'+(n%112)*interval '6 minutes')::text,true);
        select * into c from public.customers where tenant_id={t} and phone='019'||lpad((n%2000)::text,8,'0');
        i:=n%6;
        sku:=(array[{','.join(uid(x) for x in p['item_ids'])}])[i+1];
        -- Replenish every 100 invoices, then exchange ordinary refill empties.
        if n%100=0 then
         cart:='[]';
         for j in 1..6 loop
          cart:=cart||jsonb_build_array(jsonb_build_object('item_id',(array[{','.join(uid(x) for x in p['item_ids'])}])[j],
           'type','package','quantity',20,'empty_dispatched',0,'unit_price',1800+(j-1)*100));
         end loop;
         result:=public.create_purchase(jsonb_build_object('plant_id',{plant},'truck_id',{truck},
          'request_id',gen_random_uuid(),'transport_cost',120,'labour_cost',80,'commission',0,'notes','Capacity historical supply','items',cart));
         pid:=(result->>'purchase_id')::uuid;
         perform public.dispatch_purchase(pid,1);
         select (value->>'revision')::integer into j from public.get_purchases_by_ids(array[pid]) value;
         perform public.receive_purchase(pid,j);
         select (value->>'total_cost')::numeric-(value->>'paid_amount')::numeric into amount from public.get_purchases_by_ids(array[pid]) value;
         perform public.record_purchase_payment(pid,jsonb_build_array(jsonb_build_object('wallet_id',bank,'amount',amount)),gen_random_uuid());
        end if;
        qty:=case when n%17=0 then 2 else 1 end;
        cart:=jsonb_build_array(jsonb_build_object('item_id',sku,'type',case when n%5=0 then 'package' else 'refill' end,
          'quantity',qty,'unit_price',case when n%5=0 then 2300+i*100 else 1200+i*100 end));
        if n%5<>0 then cart:=cart||jsonb_build_array(jsonb_build_object('item_id',sku,'type','empty_return','quantity',qty,'unit_price',0)); end if;
        amount:=qty*(case when n%5=0 then 2300+i*100 else 1200+i*100 end);
        paid:=case when n%4=0 then 0 when n%4=1 then amount/2 else amount end;
        result:=public.create_pos_sale(c.phone,null,null,null,c.tier,0,0,'Capacity historical invoice',cart,c.customer_id,gen_random_uuid(),
          case when paid=0 then '[]'::jsonb else jsonb_build_array(jsonb_build_object('wallet_id',w,'amount',paid)) end);
        sid:=(result->>'sale_id')::uuid;
        if n%4=1 then
         perform public.collect_sale_payment(sid,jsonb_build_array(jsonb_build_object('wallet_id',bank,'amount',amount-paid)),gen_random_uuid());
        end if;
       end loop;
      end $seed$;
      reset role;
      {unstamp}
      commit;
      select jsonb_build_object('sales',count(*),'seconds',0) from public.sales where tenant_id={t};
    """
    before = time.monotonic()
    result = json.loads(sql(query).splitlines()[-1])
    result['seconds'] = round(time.monotonic() - before, 2)
    print(json.dumps(result), flush=True)


if __name__ == '__main__':
    payload = json.load(sys.stdin)
    if payload['action'] == 'provision':
        provision(payload)
    elif payload['action'] == 'seed':
        seed(payload)
    else:
        raise RuntimeError('Unknown preparation operation')
