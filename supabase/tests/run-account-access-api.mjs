import assert from 'node:assert/strict';
import {readFileSync,readdirSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {parseEnv} from 'node:util';
assert(process.argv.includes('--vps'),'Explicit --vps required');
const c=parseEnv(readFileSync('deploy/.env.backend','utf8'));assert.equal(c.VPS_HOST,'144.79.249.4');assert.equal(c.VPS_PROJECT_DIR,'/opt/lpg');
const ssh=[...(c.VPS_SSH_KEY?['-i',c.VPS_SSH_KEY]:[]),'-p',c.VPS_PORT,'-o','BatchMode=yes','-o','StrictHostKeyChecking=yes',`${c.VPS_USER}@${c.VPS_HOST}`];
const migrations=readdirSync('supabase/migrations').filter(n=>/^\d{14}_.+\.sql$/.test(n)).sort().map(n=>({version:n.slice(0,14),sql:readFileSync('supabase/migrations/'+n,'utf8')}));
const payload={migrations,server:readFileSync('account-service/server.mjs','utf8'),test:readFileSync('supabase/tests/account-access-api-fixture.mjs','utf8')};
const python=`import json,os,re,subprocess,sys,tempfile,uuid
os.umask(0o077)
p=json.load(sys.stdin)
compose=['docker','compose','--project-directory','/opt/lpg','--env-file','/opt/lpg/.env','-p','lpg','-f','/opt/lpg/compose.yml','-f','/opt/lpg/compose.vps.yml']
def run(cmd,**kw):
 r=subprocess.run(cmd,stderr=subprocess.PIPE,**kw)
 if r.returncode: raise RuntimeError('Isolated integration subprocess failed: '+r.stderr.decode(errors='replace')[-4000:])
 return r.stdout
def sql(db,source):return run(compose+['exec','-T','db','psql','-X','-U','supabase_admin','-d',db,'-qAt','-v','ON_ERROR_STOP=1'],input=source.encode(),stdout=subprocess.PIPE).decode()
tag=uuid.uuid4().hex[:12];db='lpg_access_api_'+tag
auth='lpg-access-auth-'+tag;rest='lpg-access-rest-'+tag;client='lpg-access-client-'+tag
created=False;containers=[]
try:
 model=json.loads(run(compose+['--profile','*','config','--format','json'],stdout=subprocess.PIPE))
 with tempfile.TemporaryFile() as dump:
  run(compose+['exec','-T','db','pg_dump','--exclude-extension=pg_cron','--exclude-schema=cron','-U','supabase_admin','-d','postgres','-Fc'],stdout=dump)
  sql('postgres','CREATE DATABASE '+db+' TEMPLATE template0 OWNER postgres;');created=True;dump.seek(0)
  run(compose+['exec','-T','db','pg_restore','-U','supabase_admin','-d',db,'--exit-on-error','--single-transaction'],stdin=dump,stdout=subprocess.PIPE)
 applied=set(sql(db,'select version from supabase_migrations.schema_migrations;').splitlines())
 for m in p['migrations']:
  if m['version'] not in applied:sql(db,'begin;'+m['sql']+'commit;')
 # Only the disposable database loses copied platform status. Original accounts/data remain untouched.
 sql(db,'delete from app_private.admin_workspace_sessions;delete from app_private.platform_bootstrap;delete from app_private.platform_superadmins;')
 with tempfile.TemporaryDirectory(prefix='lpg-access-integration-') as directory:
  for name,service in [(auth,'auth'),(rest,'rest')]:
   env=dict(model['services'][service]['environment'])
   key='GOTRUE_DB_DATABASE_URL' if service=='auth' else 'PGRST_DB_URI'
   env[key]=re.sub(r'/postgres(?=\\?|$)','/'+db,env[key])
   assert db in env[key]
   if service=='auth':env['GOTRUE_DISABLE_SIGNUP']='true'
   file=directory+'/'+service+'.env'
   with open(file,'w') as f:f.write('\\n'.join(k+'='+str(v) for k,v in env.items())+'\\n')
   run(['docker','run','-d','--name',name,'--network','lpg_default','--memory','192m','--env-file',file,model['services'][service]['image']],stdout=subprocess.PIPE);containers.append(name)
  import time,urllib.request
  for i in range(60):
   ready=True
   for name,port in [(auth,9999),(rest,3000)]:
    state=json.loads(run(['docker','inspect',name],stdout=subprocess.PIPE))[0]
    assert state['State']['Running'],'Isolated service exited before readiness'
    ip=state['NetworkSettings']['Networks']['lpg_default']['IPAddress']
    try:
     with urllib.request.urlopen('http://'+ip+':'+str(port)+('/health' if name==auth else '/'),timeout=1):pass
    except urllib.error.HTTPError as e:ready=ready and e.code in (401,403,404)
    except Exception:ready=False
   if ready:break
   time.sleep(.5)
  else:raise RuntimeError('Isolated services failed readiness')
  gateway=model['services']['api-gw']['environment']
  cfg=dict(auth='http://'+auth+':9999',rest='http://'+rest+':3000',publicKey=gateway['ANON_KEY'],serviceKey=gateway['SERVICE_ROLE_KEY'])
  for file,source in [('server.mjs',p['server']),('test.mjs',p['test']),('fixture.json',json.dumps(cfg))]:
   with open(directory+'/'+file,'w') as f:f.write(source)
  try:
   output=run(['docker','run','--rm','--name',client,'--network','lpg_default','--memory','128m','--read-only','--cap-drop','ALL','--security-opt','no-new-privileges','-v',directory+':/run:ro','node:24.20.0-alpine','node','/run/test.mjs'],stdout=subprocess.PIPE).decode()
  except Exception:
   logs=subprocess.run(['docker','logs','--tail','30',auth],stdout=subprocess.PIPE,stderr=subprocess.STDOUT).stdout.decode(errors='replace')
   for message,code in re.findall(r'ERROR: ([A-Za-z .-]+) \\(SQLSTATE ([A-Z0-9]+)\\)',logs):print('Isolated Auth database error: '+message+' ['+code+']',flush=True)
   raise
  print(output,flush=True)
finally:
 for name in containers:
  assert re.fullmatch(r'lpg-access-(auth|rest)-[a-f0-9]{12}',name)
  subprocess.run(['docker','rm','-f',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 if created:
  assert re.fullmatch(r'lpg_access_api_[a-f0-9]{12}',db)
  sql('postgres','DROP DATABASE '+db+';')
`;
const quote=v=>"'"+v.replaceAll("'","'\"'\"'")+"'";
try{process.stdout.write(execFileSync('ssh',[...ssh,'sudo -n python3 -c '+quote(python)],{input:JSON.stringify(payload),encoding:'utf8',maxBuffer:8*1024*1024}));}
catch(error){if(error.stdout)process.stdout.write(error.stdout);console.error(error.stderr?.toString()??error.message);process.exitCode=1;}
