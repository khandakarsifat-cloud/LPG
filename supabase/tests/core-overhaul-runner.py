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
        # fixtures. Every application/Auth/Storage row must remain byte-equivalent.
        existing_versions = set(sql('select version from supabase_migrations.schema_migrations;').splitlines())
        pending = [m for m in payload['migrations'] if m['version'] not in existing_versions]
        if pending:
            preservation = """create function pg_temp.preserved_rows() returns jsonb language plpgsql as $$
            declare r record;v jsonb;result jsonb:='{}';begin
             for r in select n.nspname schema_name,c.relname table_name from pg_class c join pg_namespace n on n.oid=c.relnamespace
              where c.relkind='r' and n.nspname in ('public','app_private','auth','storage') order by 1,2 loop
              execute format('select jsonb_build_object(''count'',count(*),''digest'',md5(coalesce(string_agg(digest,'''' order by digest),''''))) from(select md5(to_jsonb(x)::text) digest from %I.%I x)r',r.schema_name,r.table_name) into v;
              result:=result||jsonb_build_object(r.schema_name||'.'||r.table_name,v);
             end loop;return result;end $$;
             create temporary table preserved_rows as select pg_temp.preserved_rows() evidence;
            """
            sql('begin;\n' + preservation + '\n' + '\n'.join(m['sql'] for m in pending) + '''
             do $$begin if (select evidence from preserved_rows) is distinct from pg_temp.preserved_rows()
              then raise exception 'Historical records changed during upgrade';end if;end$$;rollback;''')
            print('PASS forward upgrade preserves every existing application/Auth/Storage row, including historical journals and request evidence', flush=True)
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
        result = sql('begin;\n' + payload['access_helpers'] + '\n' + payload['functional'] + '\nrollback;')
        print('PASS complete component, exchange, return, history, treasury and dependent-module SQL lifecycle', flush=True)
        sql('begin;\n' + payload['access_helpers'] + '\n' + payload['rebate'] + '\nrollback;')
        print('PASS rebate lifecycle, unchanged prices/FIFO/COGS, corrections, refund versus company credit and independent financial positions', flush=True)
        sql('begin;\n' + payload['access_helpers'] + '\n' + payload['lending'] + '\nrollback;')
        print('PASS lending, partial/full repayments, replay, exact cents, activity filters and independent journal positions', flush=True)
        sql('begin;\n' + payload['access_helpers'] + '\n' + payload['security'] + '\nrollback;')
        print('PASS authenticated/anonymous permissions, tenant isolation, private helper boundaries and canonical contracts', flush=True)
        sql('begin;\n' + payload['access_helpers'] + '\n' + payload['visibility'] + '\nrollback;')
        print('PASS independent received-quantity/FIFO margins and authenticated per-wallet visibility, hidden-balance writes and atomic denials', flush=True)
        if payload.get('action_storage'):
            current = sql('begin;\n' + payload['access_helpers'] + '\n' + payload['action_storage'] + '\nrollback;')
            if baseline:
                prior_reports = json.loads(baseline.strip().splitlines()[-1])['_reports']
                current_reports = json.loads(current.strip().splitlines()[-1])['_reports']
                if prior_reports != current_reports:
                    print('REPORT_DIFFERENCE ' + json.dumps({k: {'before':v,'after':current_reports.get(k)} for k,v in prior_reports.items() if v != current_reports.get(k)}), flush=True)
                    raise AssertionError('Before/after financial reports differ')
                print('PASS before/after opening, closing, totals, acquisitions, cash classifications, all business positions and daily trends match exactly', flush=True)
            print('ACTION_STORAGE_AFTER ' + json.dumps({k:v for k,v in json.loads(current.strip().splitlines()[-1]).items() if k != '_reports'}), flush=True)
            print('PASS small/large action journal counts, split settlements, delayed cross-company bottles, retries and source/FIFO controls', flush=True)
        if payload.get('concurrency'):
            exec(payload['concurrency'], globals())
        print('PASS canonical core database suite; live business records were not changed', flush=True)
finally:
    if created:
        assert re.fullmatch(r'lpg_core_acceptance_[0-9a-f]{12}', database)
        sql('drop database ' + database + ' with (force);', 'postgres')
