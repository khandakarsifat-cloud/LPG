"""Disposable Azure customer-directory load fixture. Never targets an existing DB.

Run on the established development VPS through SSH, with source staged separately.
Creates a fresh lpg_load_* database; preserves live roles and all other databases.
JWTs are signed by a test-only key for a separate loopback PostgREST container.
"""
import argparse
import base64
import hashlib
import hmac
import json
import secrets
import shutil
import subprocess
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('action', choices=['init', 'seed', 'status', 'analyze', 'cleanup'])
parser.add_argument('--state', type=Path, required=True)
parser.add_argument('--source', type=Path)
parser.add_argument('--businesses', type=int, default=1)
args = parser.parse_args()
state = args.state.resolve()
assert str(state).startswith('/tmp/lpg-business-load.'), 'Private disposable workspace required'
manifest_path = state / 'manifest.json'
if args.action == 'init':
    assert not manifest_path.exists(), 'Refuse to reuse an existing run'
    manifest = {'database': 'lpg_load_' + secrets.token_hex(6), 'businesses': 0,
                'customers_per_business': 2000, 'sales_per_business': 20000,
                'container': 'lpg-business-load-' + secrets.token_hex(4)}
else:
    manifest = json.loads(manifest_path.read_text())
database = manifest['database']
assert database.startswith('lpg_load_') and database[9:].isalnum()
assert manifest['container'].startswith('lpg-business-load-')
base = ['docker', 'exec', '-i', 'lpg-db-1', 'psql', '-X', '-U', 'supabase_admin',
        '-qAt', '-v', 'ON_ERROR_STOP=1']


def sql(statement, db=database, timeout=300):
    result = subprocess.run(base + ['-d', db], input=statement, text=True,
                            capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(result.stderr[-2000:])
    return result.stdout.strip()


def save():
    manifest_path.write_text(json.dumps(manifest, indent=2))


def fixture_id(kind, number):
    return f'{kind}0000000-0000-4000-8000-{number:012d}'


if args.action == 'init':
    sql('create database ' + database, db='postgres')
    save()  # Retain exact cleanup identity even if a later setup step fails.
    sql('''grant all on schema public to postgres; create schema auth;
      create schema extensions; create extension "uuid-ossp" with schema extensions;
      create table auth.users(id uuid primary key,email text,is_anonymous boolean default false,
        raw_app_meta_data jsonb,raw_user_meta_data jsonb);
      create function auth.uid() returns uuid language sql stable as $$
        select coalesce(nullif(current_setting('request.jwt.claim.sub',true),''),
          nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'sub')::uuid $$;
      create function auth.jwt() returns jsonb language sql stable as $$
        select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb $$;
      grant usage on schema auth,extensions to postgres;
      grant all on auth.users to postgres; grant usage on schema auth to anon,authenticated;
      grant execute on function auth.uid(),auth.jwt() to anon,authenticated;''')
    for migration in sorted((args.source / 'supabase/migrations').glob('*.sql')):
        if 'multi_wallet_finance' in migration.name:
            sql((args.source / 'supabase/tests/finance-legacy.before.sql').read_text())
        if 'purchase_wallet_lifecycle' in migration.name:
            sql((args.source / 'supabase/tests/purchase-wallets-legacy.before.sql').read_text())
        sql(migration.read_text())
        if 'multi_wallet_finance' in migration.name:
            sql((args.source / 'supabase/tests/finance-legacy.after.sql').read_text())
        if 'purchase_wallet_lifecycle' in migration.name:
            sql((args.source / 'supabase/tests/purchase-wallets-legacy.after.sql').read_text())
    # Replay includes deliberately committed historical compatibility fixtures.
    # Remove only this new database's data, keeping the permission catalog.
    sql("do $$ declare tables text; begin "
        "select string_agg(format('%I.%I',schemaname,tablename),',') into tables "
        "from pg_tables where schemaname='public' and tablename<>'permissions'; "
        "execute 'truncate '||tables||' restart identity cascade'; end $$; "
        "truncate auth.users cascade;")
    assert sql('select count(*) from public.tenants') == '0'
    key = secrets.token_urlsafe(48)
    env_file = state / 'postgrest.env'
    # Read the established container configuration in memory; never emit credentials.
    live = json.loads(subprocess.check_output(['docker', 'inspect', 'lpg-rest-1']))[0]
    env = dict(entry.split('=', 1) for entry in live['Config']['Env'] if '=' in entry)
    uri = env['PGRST_DB_URI'].rsplit('/', 1)[0] + '/' + database
    env_file.write_text('\n'.join(['PGRST_DB_URI=' + uri, 'PGRST_JWT_SECRET=' + key,
        'PGRST_DB_SCHEMAS=public', 'PGRST_DB_ANON_ROLE=anon', 'PGRST_DB_POOL=10',
        'PGRST_DB_POOL_ACQUISITION_TIMEOUT=10', 'PGRST_SERVER_PORT=3000',
        'PGRST_DB_MAX_ROWS=1000', 'PGRST_LOG_LEVEL=error']) + '\n')
    env_file.chmod(0o600)
    networks = list(live['NetworkSettings']['Networks'])
    assert len(networks) == 1
    subprocess.run(['docker', 'run', '-d', '--name', manifest['container'],
        '--network', networks[0], '--memory', '192m', '--env-file', str(env_file),
        '--log-driver', 'json-file', '--log-opt', 'max-size=10m', '--log-opt', 'max-file=2',
        '-p', '127.0.0.1:3300:3000', live['Image']], check=True, capture_output=True)
    def encode(data):
        return base64.urlsafe_b64encode(json.dumps(data, separators=(',', ':')).encode()).rstrip(b'=')
    tokens = []
    for number in range(1, 1281):
        body = encode({'alg': 'HS256', 'typ': 'JWT'}) + b'.' + encode({
            'sub': fixture_id('b', number), 'role': 'authenticated',
            'aud': 'authenticated', 'iat': int(time.time()), 'exp': int(time.time()) + 86400})
        signature = base64.urlsafe_b64encode(hmac.new(key.encode(), body, hashlib.sha256).digest()).rstrip(b'=')
        tokens.append((body + b'.' + signature).decode())
    token_path = state / 'tokens.json'
    token_path.write_text(json.dumps(tokens))
    token_path.chmod(0o600)
    print(json.dumps({'database': database, 'container': manifest['container'], 'initialized': True}), flush=True)

elif args.action == 'seed':
    assert manifest['businesses'] < args.businesses <= 1280
    for number in range(manifest['businesses'] + 1, args.businesses + 1):
        if shutil.disk_usage('/').free < 4 * 1024**3:
            raise RuntimeError('Storage safety stop: reserve 4 GiB for the existing system')
        tenant, user, role = [fixture_id(k, number) for k in ['a', 'b', 'c']]
        sql(f'''begin; set local session_replication_role=replica;
          insert into public.tenants(tenant_id,business_name) values('{tenant}','Load business {number}');
          insert into auth.users(id,email) values('{user}','load-{number}@example.invalid');
          insert into public.user_profiles(user_id,tenant_id,email) values('{user}','{tenant}','load-{number}@example.invalid');
          insert into public.roles(tenant_id,role_id,name) values('{tenant}','{role}','OWNER');
          insert into public.role_permissions(tenant_id,role_id,permission_id)
            select '{tenant}','{role}',permission_id from public.permissions;
          insert into public.user_roles(tenant_id,user_id,role_id) values('{tenant}','{user}','{role}');
          insert into public.items(tenant_id,item_id,brand,size_kg)
            select '{tenant}',('d0000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'Load product '||n,12
            from generate_series(1,2) n;
          insert into public.customers(tenant_id,customer_id,name,phone,tier)
            select '{tenant}',('e0000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
              'Business {number} Customer '||lpad(n::text,4,'0'),'019'||lpad(n::text,8,'0'),
              case when n%3=0 then 'wholesale' else 'retail' end from generate_series(1,2000) n;
          insert into public.sales(tenant_id,sale_id,customer_id,status,sale_tier,subtotal,total_amount,
            payment_tracking,paid_amount,paid_at_checkout,created_by,created_at)
            select '{tenant}',('f0000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
              ('e0000000-0000-4000-8000-'||lpad((1+(n-1)%2000)::text,12,'0'))::uuid,
              'completed','retail',1000+n%100,1000+n%100,true,500,500,'{user}',
              '2026-01-01 00:00:00+06'::timestamptz+(n%90)*interval '1 day'
            from generate_series(1,{manifest['sales_per_business']}) n;
          insert into public.sale_items(tenant_id,sale_item_id,sale_id,item_id,type,quantity,unit_price,line_total,created_at)
            select '{tenant}',('90000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
              ('f0000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
              ('d0000000-0000-4000-8000-'||lpad((1+n%2)::text,12,'0'))::uuid,
              case when n%2=0 then 'refill' else 'package' end::public.sale_item_type,
              1,1000+n%100,1000+n%100,
              '2026-01-01 00:00:00+06'::timestamptz+(n%90)*interval '1 day'
            from generate_series(1,{manifest['sales_per_business']}) n;
          set local session_replication_role=origin; commit;''')
        manifest['businesses'] = number
        save()
        if number == 1 or number % 10 == 0 or number == args.businesses:
            print(json.dumps({'businesses': number, 'database_bytes': int(sql('select pg_database_size(current_database())')),
                              'disk_free_bytes': shutil.disk_usage('/').free}), flush=True)

elif args.action == 'analyze':
    sql('analyze public.customers; analyze public.sales; analyze public.sale_items;'
        'analyze public.user_profiles; analyze public.roles; analyze public.role_permissions; analyze public.user_roles;', timeout=600)
    print('ANALYZE complete', flush=True)

elif args.action == 'status':
    print(json.dumps({**manifest, 'database_bytes': int(sql('select pg_database_size(current_database())')),
        'relations': json.loads(sql("select jsonb_object_agg(relname,pg_total_relation_size(oid)) from pg_class where relname in ('sales','sale_items','customers') and relnamespace='public'::regnamespace")),
        'free_bytes': shutil.disk_usage('/').free}), flush=True)

elif args.action == 'cleanup':
    exists = subprocess.run(['docker', 'inspect', manifest['container']], capture_output=True)
    if exists.returncode == 0:
        subprocess.run(['docker', 'rm', '-f', manifest['container']], capture_output=True, check=True)
    # Exact run identity, not a database-name prefix or list of unrelated targets.
    sql('drop database ' + database + ' with (force)', db='postgres')
    for secret in ['tokens.json', 'postgrest.env']:
        (state / secret).unlink(missing_ok=True)
    manifest['cleaned_up'] = True
    save()
    print('Disposable container/database removed; test tokens and credentials deleted', flush=True)
