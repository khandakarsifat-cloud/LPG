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
        current_versions = set(sql('select version from supabase_migrations.schema_migrations;').splitlines())
        # Reset only this verified owned clone; preserve the live acceptance business.
        sql(payload['reset'])
        for migration in payload['migrations']:
            if migration['version'] not in current_versions:
                sql('begin;\n' + migration['sql'] + '\ncommit;')
                sql('insert into supabase_migrations.schema_migrations(version,name) values(' + lit(migration['version']) + ',' + lit(migration['name']) + ');')
                print('PASS forward migration ' + migration['version'], flush=True)
        sql('begin;\n' + payload['access_helpers'] + '\n' + payload['canonical_components'] + '\nrollback;')
        print('PASS canonical Gas/Bottle component lifecycle and schema contracts', flush=True)
        sql('begin;\n' + payload['access_helpers'] + '\n' + payload['visibility'] + '\n' + payload['access_deletion'] + '\nrollback;')
        print('PASS independent FIFO reports, wallet visibility, capability boundaries and guarded business deletion', flush=True)
        for suite in payload['finance_actions']:
            sql('begin;\n' + payload['access_helpers'] + '\n' + suite['sql'] + '\nrollback;')
            print('PASS current financial source contract ' + suite['name'], flush=True)
        exec(payload['component_concurrency'], globals())

finally:
    if created:
        assert re.fullmatch(r'lpg_core_acceptance_[0-9a-f]{12}', database)
        sql('drop database ' + database + ' with (force);', 'postgres')
