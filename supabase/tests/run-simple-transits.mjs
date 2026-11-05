// Apply pending SQL and verify on a disposable copy of the primary VPS database.
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { parseEnv } from 'node:util';
assert(process.argv.includes('--vps'), 'Explicit --vps required');
const config = parseEnv(readFileSync('deploy/.env.backend', 'utf8'));
assert.equal(config.VPS_HOST, '144.79.249.4');
assert.equal(config.VPS_PROJECT_DIR, '/opt/lpg');
const ssh = [...(config.VPS_SSH_KEY ? ['-i', config.VPS_SSH_KEY] : []), '-p', config.VPS_PORT, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', `${config.VPS_USER}@${config.VPS_HOST}`];
const migrations = readdirSync('supabase/migrations').filter(n => /^\d{14}_.+\.sql$/.test(n)).sort().map(n => ({version:n.slice(0,14),sql:readFileSync('supabase/migrations/'+n,'utf8')}));
const python = `import concurrent.futures,json,os,re,subprocess,sys,tempfile,uuid
os.umask(0o077)
p=json.load(sys.stdin)
cmd=['docker','compose','--project-directory','/opt/lpg','--env-file','/opt/lpg/.env','-p','lpg','-f','/opt/lpg/compose.yml','-f','/opt/lpg/compose.vps.yml','exec','-T','db']
def run(args,**kw):
 r=subprocess.run(cmd+args,stderr=subprocess.PIPE,**kw)
 if r.returncode:raise RuntimeError(r.stderr.decode(errors='replace')[-6000:])
 return r.stdout
def sql(db,source):return run(['psql','-X','-U','supabase_admin','-d',db,'-qAt','-v','ON_ERROR_STOP=1'],input=source.encode(),stdout=subprocess.PIPE).decode()
db='lpg_transit_test_'+uuid.uuid4().hex[:16]
created=False
try:
 with tempfile.TemporaryFile() as dump:
  run(['pg_dump','--exclude-extension=pg_cron','--exclude-schema=cron','-U','supabase_admin','-d','postgres','-Fc'],stdout=dump)
  sql('postgres','CREATE DATABASE '+db+' TEMPLATE template0 OWNER postgres;');created=True;dump.seek(0)
  run(['pg_restore','-U','supabase_admin','-d',db,'--exit-on-error','--single-transaction'],stdin=dump,stdout=subprocess.PIPE)
 applied=set(sql(db,'select version from supabase_migrations.schema_migrations;').splitlines())
 preservation="select jsonb_build_array("+','.join("(select md5(coalesce(jsonb_agg(to_jsonb(r) order by to_jsonb(r)::text)::text,'')) from public."+t+" r)" for t in ['transits','wallets','wallet_transactions','employee_payments','purchases','items','inventory_movements'])+");"
 before=sql(db,preservation)
 for m in p['migrations']:
  if m['version'] not in applied:
   sql(db,'begin;set check_function_bodies=on;'+m['sql']+'commit;')
   print('PASS migration '+m['version'],flush=True)
 assert sql(db,preservation)==before,'Migration changed existing business evidence'
 print('PASS migration preserves existing transit, wallet, employee, purchase and stock evidence',flush=True)
 print(sql(db,p['test'].rsplit('rollback;',1)[0]+'commit;'),flush=True)
 fixture=json.loads(sql(db,"select json_build_object('transit',tr.transit_id,'revision',tr.revision,'wallet',w.wallet_id,'balance',w.balance,'tenant',tr.tenant_id) from public.transits tr join public.wallets w on w.tenant_id=tr.tenant_id and w.type='cash' join public.tenants t on t.tenant_id=tr.tenant_id where tr.client_name='Race fixture' and t.business_name='Simple transit disposable fixture';").strip())
 def complete(_):
  return sql(db,p['helpers']+"begin;set local role authenticated;select pg_temp.fixture_identity('bf910000-0000-4000-8000-000000000001');select public.transition_transit('"+fixture['transit']+"','complete',"+str(fixture['revision'])+");commit;")
 with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:list(pool.map(complete,range(4)))
 assert sql(db,"select balance="+str(fixture['balance'])+"-100 from public.wallets where wallet_id='"+fixture['wallet']+"';").strip()=='t','Concurrent completion debited more than once'
 assert sql(db,"select count(*) from public.employee_payments where transit_id='"+fixture['transit']+"';").strip()=='2'
 assert sql(db,"select count(*) from public.operating_payments where transit_id='"+fixture['transit']+"' and kind='expense';").strip()=='1'
 assert sql(db,"select count(*) from public.wallets w where balance<>opening_balance+coalesce((select sum(amount) from public.wallet_transactions x where x.tenant_id=w.tenant_id and x.wallet_id=w.wallet_id),0);").strip()=='0'
 print('PASS four competing completions: one payment per crew member, one expense payment, exact wallet reconciliation',flush=True)
 for test in p['extraTests']:
  print(sql(db,p['helpers']+test),flush=True)
finally:
 if created:
  assert re.fullmatch(r'lpg_transit_test_[a-f0-9]{16}',db)
  sql('postgres','DROP DATABASE '+db+';')
`;
const quote = v => "'"+v.replaceAll("'", "'\"'\"'")+"'";
try {
 const helpers=readFileSync('supabase/tests/account-access-fixtures.sql','utf8');
 const adapt=source=>source.replaceAll('public.setup_business(', 'pg_temp.fixture_business(').replace(/set_config\('request\.jwt\.claim\.sub',([^;]*?),true\)/g,'pg_temp.fixture_identity($1)');
 const extraTests=['financial-stove-transport.sql','accounting-overview.sql'].map(n=>adapt(readFileSync('supabase/tests/'+n,'utf8')));
 const output = execFileSync('ssh',[...ssh,'sudo -n python3 -c '+quote(python)],{input:JSON.stringify({migrations,helpers,extraTests,test:helpers+'\n'+readFileSync('supabase/tests/simple-transits.sql','utf8')}),encoding:'utf8',maxBuffer:8*1024*1024});
 process.stdout.write(output);
} catch(error) { console.error(error.stdout?.toString()??''); console.error(error.stderr?.toString()??error.message); process.exitCode=1; }
