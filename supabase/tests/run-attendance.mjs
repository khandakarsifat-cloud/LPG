// Verify on a newly named, disposable PostgreSQL database on the primary VPS.
// The application database is read only (pg_dump). Never reset or restore it.
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { parseEnv } from 'node:util';

assert(process.argv.includes('--vps'), 'Explicit --vps target required');
const config = parseEnv(readFileSync('deploy/.env.backend', 'utf8'));
assert.equal(config.VPS_HOST, '144.79.249.4'); assert.equal(config.VPS_PROJECT_DIR, '/opt/lpg');
const ssh = [...(config.VPS_SSH_KEY ? ['-i', config.VPS_SSH_KEY] : []), '-p', config.VPS_PORT, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', `${config.VPS_USER}@${config.VPS_HOST}`];
const migrations = process.argv.includes('--with-migrations') ? readdirSync('supabase/migrations').filter(name => /^\d{14}_.+\.sql$/.test(name)).sort().map(name => ({ version: name.slice(0, 14), sql: readFileSync('supabase/migrations/' + name, 'utf8') })) : [];
const tests = readFileSync('supabase/tests/attendance-history.sql', 'utf8');
const regressions = ['authorization.sql', 'employees.sql'].map(name => ({ name, source: readFileSync('supabase/tests/fixture-helpers.sql', 'utf8') + '\n' + readFileSync('supabase/tests/' + name, 'utf8') }));
const python = `import concurrent.futures,json,os,re,subprocess,sys,tempfile,uuid
os.umask(0o077)
payload=json.load(sys.stdin)
cmd=['docker','compose','--project-directory','/opt/lpg','--env-file','/opt/lpg/.env','-p','lpg','-f','/opt/lpg/compose.yml','-f','/opt/lpg/compose.vps.yml','exec','-T','db']
def run(args,**kw):
 r=subprocess.run(cmd+args,stderr=subprocess.PIPE,**kw)
 if r.returncode: raise RuntimeError(r.stderr.decode(errors='replace')[-5000:])
 return r.stdout
def sql(database,source):
 return run(['psql','-X','-U','supabase_admin','-d',database,'-qAt','-v','ON_ERROR_STOP=1'],input=source.encode(),stdout=subprocess.PIPE).decode()
db='lpg_attendance_test_'+uuid.uuid4().hex[:16]
created=False
try:
 with tempfile.TemporaryFile() as dump:
  run(['pg_dump','-U','supabase_admin','-d','postgres','-Fc'],stdout=dump)
  sql('postgres','CREATE DATABASE '+db+' TEMPLATE template0 OWNER postgres;')
  created=True
  dump.seek(0)
  run(['pg_restore','-U','supabase_admin','-d',db,'--exit-on-error','--single-transaction'],stdin=dump,stdout=subprocess.PIPE)
 applied=set(sql(db,'select version from supabase_migrations.schema_migrations;').splitlines())
 for definition in payload['migrations']:
  if definition['version'] not in applied:
   sql(db,'begin; set check_function_bodies=on; '+definition['sql']+' commit;')
 result=sql(db,'begin; set check_function_bodies=on; '+payload['tests']+' commit;')
 for line in result.splitlines():
  if line.startswith('PASS:'): print(line,flush=True)
 # Concurrent sessions operate exclusively on committed disposable fixtures.
 sql(db,"update public.attendance_devices set enabled=true where serial='ATT-HISTORY-SQL'; update public.attendance_settings set timezone='Asia/Dhaka' where tenant_id=(select tenant_id from public.attendance_devices where serial='ATT-HISTORY-SQL');")
 records=json.dumps([dict(pin='009',timestamp='2026-10-26 09:00:00',status='0',verify='1',workcode='0',key='8'*64)])
 query="select public.attendance_receive('ATT-HISTORY-SQL','upload','"+records+"','3');"
 with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
  list(pool.map(lambda _:sql(db,query),range(8)))
 result=sql(db,"select (count(*)=1)::text from public.attendance_events where device_id=(select device_id from public.attendance_devices where serial='ATT-HISTORY-SQL') and event_key=repeat('8',64);")
 if result.strip()!='true': raise RuntimeError('Concurrent replay duplicated a raw event')
 print('PASS: eight concurrent real PostgreSQL sessions commit one raw event',flush=True)
 for suite in payload['regressions']:
  result=sql(db,suite['source'])
  for line in result.splitlines():
   if 'PASS:' in line: print(suite['name']+': '+line,flush=True)
finally:
 if created:
  assert re.fullmatch(r'lpg_attendance_test_[a-f0-9]{16}',db)
  sql('postgres','DROP DATABASE '+db+';')
`;
const quote = value => "'" + value.replaceAll("'", "'\"'\"'") + "'";
try {
 const output = execFileSync('ssh', [...ssh, 'sudo -n python3 -c ' + quote(python)], { input: JSON.stringify({ migrations, tests, regressions }), encoding: 'utf8', maxBuffer: 8 * 1024 * 1024, stdio: ['pipe', 'pipe', 'pipe'] });
 assert.match(output, /PASS:/); process.stdout.write(output);
} catch (error) {
 console.error(error.stderr?.toString() ?? error.message); process.exitCode = 1;
}
