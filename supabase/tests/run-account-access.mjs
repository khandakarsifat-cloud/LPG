// All migration/fault-injection tests run on a named disposable VPS database.
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { parseEnv } from 'node:util';
assert(process.argv.includes('--vps'), 'Explicit --vps required');
const config = parseEnv(readFileSync('deploy/.env.backend','utf8'));
assert.equal(config.VPS_HOST,'144.79.249.4');assert.equal(config.VPS_PROJECT_DIR,'/opt/lpg');
const ssh=[...(config.VPS_SSH_KEY?['-i',config.VPS_SSH_KEY]:[]),'-p',config.VPS_PORT,'-o','BatchMode=yes','-o','StrictHostKeyChecking=yes',`${config.VPS_USER}@${config.VPS_HOST}`];
const migrations=readdirSync('supabase/migrations').filter(n=>/^\d{14}_.+\.sql$/.test(n)).sort().map(n=>({version:n.slice(0,14),sql:readFileSync('supabase/migrations/'+n,'utf8')}));
const tests=readFileSync('supabase/tests/account-access.sql','utf8');
const adapt=source=>source.replaceAll('public.setup_business(', 'pg_temp.fixture_business(').replace(/set_config\('request\.jwt\.claim\.sub',([^;]*?),true\)/g,'pg_temp.fixture_identity($1)');
const helpers=readFileSync('supabase/tests/account-access-fixtures.sql','utf8')+'\n'+adapt(readFileSync('supabase/tests/fixture-helpers.sql','utf8'));
const regressions=['authorization-current.sql','employees-current.sql','attendance-device-registration.sql'].map(name=>({name,sql:helpers+'\n'+adapt(readFileSync('supabase/tests/'+name,'utf8'))}));
// Financial contract regressions run through accounting:db:test; historical
// pre-component scenarios must never run against the latest schema.

const python=`import json,os,re,subprocess,sys,tempfile,uuid
os.umask(0o077)
p=json.load(sys.stdin)
cmd=['docker','compose','--project-directory','/opt/lpg','--env-file','/opt/lpg/.env','-p','lpg','-f','/opt/lpg/compose.yml','-f','/opt/lpg/compose.vps.yml','exec','-T','db']
def run(args,**kw):
 r=subprocess.run(cmd+args,stderr=subprocess.PIPE,**kw)
 if r.returncode: raise RuntimeError(r.stderr.decode(errors='replace')[-5000:])
 return r.stdout
def sql(db,source):return run(['psql','-X','-U','supabase_admin','-d',db,'-qAt','-v','ON_ERROR_STOP=1'],input=source.encode(),stdout=subprocess.PIPE).decode()
db='lpg_access_test_'+uuid.uuid4().hex[:16]
created=False
try:
 with tempfile.TemporaryFile() as dump:
  run(['pg_dump','--exclude-extension=pg_cron','--exclude-schema=cron','-U','supabase_admin','-d','postgres','-Fc'],stdout=dump)
  sql('postgres','CREATE DATABASE '+db+' TEMPLATE template0 OWNER postgres;');created=True;dump.seek(0)
  run(['pg_restore','-U','supabase_admin','-d',db,'--exit-on-error','--single-transaction'],stdin=dump,stdout=subprocess.PIPE)
 preservation='select jsonb_build_array('+','.join("(select md5(coalesce(jsonb_agg(to_jsonb(r) order by to_jsonb(r)::text)::text,'')) from public."+t+" r)" for t in ['items','inventory_movements','sales','sale_items','purchases','purchase_items','wallets','wallet_transactions','accounting_journals','accounting_lines','employees','employee_payments'])+');'
 before=sql(db,preservation)
 applied=set(sql(db,'select version from supabase_migrations.schema_migrations;').splitlines())
 for m in p['migrations']:
  if m['version'] not in applied:
   sql(db,'begin; set check_function_bodies=on; '+m['sql']+' commit;');print('PASS migration '+m['version'],flush=True)
 assert before==sql(db,preservation),'Migration changed original operations, stock or accounting evidence'
 print('PASS original business evidence, inventory and journal preservation',flush=True)
 for line in sql(db,p['tests']).splitlines():
  if line.startswith('PASS:'):print(line,flush=True)
 for suite in p['regressions']:
  sql(db,suite['sql']);print('PASS regression '+suite['name'],flush=True)
finally:
 if created:
  assert re.fullmatch(r'lpg_access_test_[a-f0-9]{16}',db)
  sql('postgres','DROP DATABASE '+db+';')
`;
const quote=v=>"'"+v.replaceAll("'","'\"'\"'")+"'";
try { process.stdout.write(execFileSync('ssh',[...ssh,'sudo -n python3 -c '+quote(python)],{input:JSON.stringify({migrations,tests,regressions}),encoding:'utf8',maxBuffer:8*1024*1024})); }
catch(error){ if(error.stdout)process.stdout.write(error.stdout);console.error(error.stderr?.toString()??error.message);process.exitCode=1; }
