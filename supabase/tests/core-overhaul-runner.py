"""Current core contracts on an owned disposable clone of the primary engine.

The only live queries read the deployment target and dump a consistent source.
Business deletion, migrations, fixtures and fault injection run in the clone.
"""
import concurrent.futures
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import uuid


def run(args, *, data=None, source=None, output=None, label='Test operation'):
    result = subprocess.run(args, input=data, stdin=source, stdout=output or subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=300)
    if result.returncode:
        # Only the first error line is public. PostgreSQL DETAIL can contain rows.
        error = ' '.join(line for line in result.stderr.decode(errors='replace').splitlines() if 'ERROR:' in line or line.startswith('LINE ') or 'compilation' in line)
        raise RuntimeError(label + ' failed' + (': ' + error if error else ' (private engine operation)'))
    return result.stdout.decode() if result.stdout else ''


payload = json.load(sys.stdin)
root = Path('/opt/lpg')
compose = ['docker', 'compose', '--project-directory', str(root), '--env-file', str(root / '.env'),
           '-p', 'lpg', '-f', str(root / 'compose.yml'), '-f', str(root / 'compose.vps.yml')]
model = json.loads(run(compose + ['config', '--format', 'json']))
assert model['services']['api-gw']['environment']['SUPABASE_PUBLIC_URL'] == 'https://api.lpg.144.79.249.4.sslip.io', 'Unexpected primary target'
base = ['docker', 'exec', '-i', 'lpg-db-1']
database = 'lpg_core_acceptance_' + uuid.uuid4().hex[:12]
assert re.fullmatch(r'lpg_core_acceptance_[0-9a-f]{12}', database)
created = False


def sql(text, db=None):
    return run(base + ['psql', '-X', '-U', 'supabase_admin', '-d', db or database, '-qAt', '-v', 'ON_ERROR_STOP=1'],
               data=text.encode(), label='Disposable SQL assertion')


def lit(value):
    return "'" + str(value).replace("'", "''") + "'"


def object_sql(value):
    return lit(json.dumps(value, separators=(',', ':'))) + '::jsonb'


try:
    with tempfile.TemporaryDirectory(prefix='.core-acceptance-', dir=root / 'backups') as temporary:
        folder = Path(temporary)
        assert folder.resolve().parent == root / 'backups'
        dump = folder / 'database.dump'
        with dump.open('wb') as destination:
            run(base + ['pg_dump', '-U', 'supabase_admin', '-d', 'postgres', '-Fc'], output=destination, label='Consistent source capture')
        with dump.open('rb') as source:
            toc = run(base + ['pg_restore', '--list'], source=source)
        toc = '\n'.join(line for line in toc.splitlines() if not re.search(r'\bEXTENSION(?: -)? pg_cron\b|\bSCHEMA(?: -)? cron\b| cron ', line)) + '\n'
        toc_name = '/tmp/' + database + '.toc'
        run(base + ['sh', '-c', 'umask 077; cat > "$1"', 'core-acceptance', toc_name], data=toc.encode())
        sql('create database ' + database + ' template template0;', 'postgres')
        created = True
        with dump.open('rb') as source:
            run(base + ['pg_restore', '-U', 'supabase_admin', '-d', database, '--use-list', toc_name,
                        '--section=pre-data', '--section=data', '--exit-on-error', '--single-transaction'], source=source, label='Isolated source restore')
        # Earlier disposable Auth cleanup left security rows with no Auth user.
        # Normalize those rows only in this prefix-checked clone before FK replay.
        assert re.fullmatch(r'lpg_core_acceptance_[0-9a-f]{12}', database)
        cleanup = sql("""select string_agg(format('delete from %s c where %s and not exists(select 1 from %s p where %s);',
          c.conrelid::regclass, x.nonnull, c.confrelid::regclass, x.joined), E'\n')
          from pg_constraint c cross join lateral(
           select string_agg(format('c.%I is not null', ca.attname),' and ' order by k.ord) nonnull,
            string_agg(format('p.%I=c.%I',pa.attname,ca.attname),' and ' order by k.ord) joined
           from unnest(c.conkey,c.confkey) with ordinality k(ck,pk,ord)
           join pg_attribute ca on ca.attrelid=c.conrelid and ca.attnum=k.ck
           join pg_attribute pa on pa.attrelid=c.confrelid and pa.attnum=k.pk)x
          where c.contype='f' and c.confrelid='auth.users'::regclass;""", 'postgres')
        sql(cleanup)
        with dump.open('rb') as source:
            run(base + ['pg_restore', '-U', 'supabase_admin', '-d', database, '--use-list', toc_name,
                        '--section=post-data', '--exit-on-error', '--single-transaction'], source=source, label='Isolated constraint restore')
        run(base + ['rm', '--', toc_name])
        # Rehearse the real historical upgrade before resetting this clone for
        # fixtures. Business/Auth/Storage rows remain byte-equivalent; the permission
        # catalogue is configuration intentionally changed by access migrations.
        existing_versions = set(sql('select version from supabase_migrations.schema_migrations;').splitlines())
        pending = [m for m in payload['migrations'] if m['version'] not in existing_versions]
        if pending:
            activity_conversion = any(m['name'] == 'slim_purchase_activity' for m in pending)
            fifo_cutover = any(m['name'] == 'separate_gas_bottle_fifo' for m in pending)
            before_fifo, after_fifo = payload['fifo_cutover'] if fifo_cutover else ('', '')
            if fifo_cutover:
                before_fifo = payload['access_helpers'] + '\n' + before_fifo
            permissions = """create temp table expected_role_grants as
              select tenant_id,role_id,permission_id from public.role_permissions where permission_id not in('finance:owner','purchases:commission')
              union select tenant_id,role_id,'sales:discount' from public.role_permissions where permission_id='pos:sell'
              union select tenant_id,role_id,p from public.role_permissions cross join unnest(array['finance:capital','finance:opening','finance:loans:manage','finance:assets:manage','finance:obligations:manage','finance:loans'])p where permission_id='finance:owner';
             create temp table expected_user_grants as select s.tenant_id,s.user_id,
              (select coalesce(array_agg(distinct p order by p),'{}'::text[]) from unnest(array_remove(array_remove(s.permissions,'finance:owner'),'purchases:commission')
              ||case when 'pos:sell'=any(s.permissions) then array['sales:discount'] else '{}'::text[] end
              ||case when 'finance:owner'=any(s.permissions) then array['finance:capital','finance:opening','finance:loans:manage','finance:assets:manage','finance:obligations:manage','finance:loans'] else '{}'::text[] end)p) permissions from app_private.user_permission_sets s;
            """ if any(m['name'] == 'complete_action_permissions' for m in pending) else """
             create temp table expected_role_grants as select * from public.role_permissions;
             create temp table expected_user_grants as select tenant_id,user_id,permissions from app_private.user_permission_sets;
            """
            preservation = """create temp table preserved_table_list as
             select c.oid from pg_class c join pg_namespace n on n.oid=c.relnamespace where c.relkind='r' and n.nspname in('public','app_private','auth','storage');
            """ + permissions + """
             create function pg_temp.preserved_rows() returns jsonb language plpgsql as $$
             declare r record;v jsonb;result jsonb:='{}';relation text;row_json text;begin
             for r in select n.nspname schema_name,c.relname table_name from pg_class c join pg_namespace n on n.oid=c.relnamespace
              where c.oid in(select oid from preserved_table_list) and not(n.nspname='public' and c.relname in('permissions','role_permissions')) and not(n.nspname='app_private' and c.relname='user_permission_sets') order by 1,2 loop
              relation:=r.table_name;row_json:='to_jsonb(x)';
              if r.schema_name='public' and r.table_name='items' then row_json:=row_json||'-''bottle_quantity''';
              elsif r.schema_name='public' and r.table_name='inventory_movements' then row_json:=row_json||'-''bottle_quantity_change''';
              elsif r.schema_name='app_private' and r.table_name='fifo_positions' then relation:='fifo_layers';r.table_name:='fifo_layers';
              elsif r.schema_name='app_private' and r.table_name='fifo_consumptions' and to_regclass('app_private.fifo_position_effects') is not null
                then relation:='fifo_position_effects';end if;
               execute format('select jsonb_build_object(''count'',count(*),''digest'',md5(coalesce(string_agg(digest,'''' order by digest),''''))) from(select md5((to_jsonb(x)-%L::text[])::text) digest from %I.%I x)r',
                 case when r.schema_name='app_private' and r.table_name='internal_transport_settlements' then array['wallet_id','refunded_amount'] else array['recognize_on_receipt'] end,r.schema_name,r.table_name) into v;
              result:=result||jsonb_build_object(r.schema_name||'.'||r.table_name,v);
             end loop;return result;end $$;
             create temporary table preserved_rows as select pg_temp.preserved_rows() evidence;
            """
            if activity_conversion:
                preservation += """
                 create temp table expected_purchase_activity as
                 select a.tenant_id,a.purchase_id,a.activity_id,a.created_by,a.created_at
                 from public.purchase_activity a
                 where a.action not in ('payment_recorded','refund_recorded','paid','refund_completed','financially_closed')
                   and not (a.action='cancellation_confirmed' and exists (
                     select 1 from public.purchase_activity b where b.tenant_id=a.tenant_id and b.purchase_id=a.purchase_id
                       and b.action='cancellation_initiated' and b.created_by is not distinct from a.created_by and b.created_at=a.created_at));
                 delete from preserved_table_list where oid='public.purchase_activity'::regclass;
                 update preserved_rows set evidence=evidence-'public.purchase_activity';
                """
            activity_check = """
             if exists (
               (select tenant_id,purchase_id,activity_id,created_by,created_at from public.purchase_activity except select * from expected_purchase_activity)
               union all
               (select * from expected_purchase_activity except select tenant_id,purchase_id,activity_id,created_by,created_at from public.purchase_activity)
             ) or exists(select 1 from public.purchase_activity where nullif(btrim(message),'') is null) then
               raise exception 'Purchase activity conversion changed history identities or lost a message';
             end if;
            """ if activity_conversion else ''
            sql('begin;\n' + before_fifo + '\n' + preservation + '\n' + '\n'.join(m['sql'] for m in pending) + '''
             do $$begin if (select evidence from preserved_rows) is distinct from pg_temp.preserved_rows()
             then raise exception 'Historical records changed during upgrade';end if;
             if exists((select * from public.role_permissions except select * from expected_role_grants) union all (select * from expected_role_grants except select * from public.role_permissions))
             or exists((select tenant_id,user_id,permissions from app_private.user_permission_sets except select * from expected_user_grants) union all (select * from expected_user_grants except select tenant_id,user_id,permissions from app_private.user_permission_sets)) then raise exception 'Permission configuration changed beyond specified normalization';end if;
              ''' + activity_check + '''end$$;''' + after_fifo + '\nrollback;')
            if fifo_cutover:
                print('PASS migrated open supplier custody received with original Bottle acquisitions and one new Gas layer', flush=True)
            print('PASS forward upgrade preserves business/Auth/Storage rows and journals/requests; access grants match the exact specified normalization', flush=True)
        sql(payload['reset'])
        print('PASS scoped business reset preserves administrator credentials, authority and foreign-key integrity in the clone', flush=True)
        applied = set(sql('select version from supabase_migrations.schema_migrations;').splitlines())
        baseline = None
        if payload.get('action_storage') and '20261105020000' not in applied:
            baseline = sql('begin;\n' + payload['access_helpers'] + '\n' + payload['action_storage'] + '\nrollback;')
            print('ACTION_STORAGE_BEFORE ' + json.dumps({k:v for k,v in json.loads(baseline.strip().splitlines()[-1]).items() if k != '_reports'}), flush=True)
        for migration in payload['migrations']:
            if migration['version'] not in applied:
                sql('begin;\n' + migration['sql'] + '\ncommit;')
                sql('insert into supabase_migrations.schema_migrations(version,name) values(' + lit(migration['version']) + ',' + lit(migration['name']) + ');')
                print('PASS forward migration ' + migration['version'], flush=True)
        legacy_defaults = 'alter table public.purchases alter column recognize_on_receipt set default false;\n'
        result = sql('begin;\n' + legacy_defaults + payload['access_helpers'] + '\n' + payload['functional'] + '\nrollback;')
        print('PASS complete component, exchange, return, history, treasury and dependent-module SQL lifecycle', flush=True)
        sql('begin;\n' + legacy_defaults + payload['access_helpers'] + '\n' + payload['rebate'] + '\nrollback;')
        print('PASS rebate lifecycle, unchanged prices/FIFO/COGS, corrections, refund versus company credit and independent financial positions', flush=True)
        sql('begin;\n' + legacy_defaults + payload['access_helpers'] + '\n' + payload['lending'] + '\nrollback;')
        print('PASS lending, partial/full repayments, replay, exact cents, activity filters and independent journal positions', flush=True)
        sql('begin;\n' + legacy_defaults + payload['access_helpers'] + '\n' + payload['security'] + '\nrollback;')
        print('PASS authenticated/anonymous permissions, tenant isolation, private helper boundaries and canonical contracts', flush=True)
        sql('begin;\n' + legacy_defaults + payload['access_helpers'] + '\n' + payload['visibility'] + '\nrollback;')
        print('PASS independent received-quantity/FIFO margins and authenticated per-wallet visibility, hidden-balance writes and atomic denials', flush=True)
        if payload.get('access_performance_deletion'):
            sql('begin;\n' + legacy_defaults + payload['access_helpers'] + '\n' + payload['visibility'] + '\n' + payload['access_performance_deletion'] + '\nrollback;')
            print('PASS independent historical product margins, discount rounding, dated reversals, action grants and fenced business deletion with active foreign keys', flush=True)
        if payload.get('action_storage'):
            current = sql('begin;\n' + legacy_defaults + payload['access_helpers'] + '\n' + payload['action_storage'] + '\nrollback;')
            if baseline:
                prior_reports = json.loads(baseline.strip().splitlines()[-1])['_reports']
                current_reports = json.loads(current.strip().splitlines()[-1])['_reports']
                if prior_reports != current_reports:
                    print('REPORT_DIFFERENCE ' + json.dumps({k: {'before':v,'after':current_reports.get(k)} for k,v in prior_reports.items() if v != current_reports.get(k)}), flush=True)
                    raise AssertionError('Before/after financial reports differ')
                print('PASS before/after opening, closing, totals, acquisitions, cash classifications, all business positions and daily trends match exactly', flush=True)
            print('ACTION_STORAGE_AFTER ' + json.dumps({k:v for k,v in json.loads(current.strip().splitlines()[-1]).items() if k != '_reports'}), flush=True)
            print('PASS small/large action journal counts, split settlements, delayed cross-company bottles, retries and source/FIFO controls', flush=True)
        sql('begin;\n' + payload['access_helpers'] + '\n' + payload['transport_cash'] + '\nrollback;')
        print('PASS receipt recognition, draft costs, owned custody, paired cash transport and partial refund contracts', flush=True)
        if payload.get('concurrency'):
            sql('alter table public.purchases alter column recognize_on_receipt set default false;')
            exec(payload['concurrency'], globals())
        print('PASS canonical core database suite; live business records were not changed', flush=True)
finally:
    if created:
        assert re.fullmatch(r'lpg_core_acceptance_[0-9a-f]{12}', database)
        sql('drop database ' + database + ' with (force);', 'postgres')
