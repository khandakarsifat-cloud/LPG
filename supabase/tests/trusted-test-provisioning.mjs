// Trusted SSH fixture arrangement only; never shipped with the application.
// Public signup stays disabled. Existing users/businesses are never adopted.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { parseEnv } from 'node:util';

export async function provisionTestIdentity({email,password,businessName,ownerName='Disposable fixture owner',platform=false}) {
 assert(email.endsWith('@example.invalid'),'Fixture emails must use example.invalid');
 assert(password.length>=12,'Use a generated fixture password');
 if(!platform)assert(/fixture|disposable|test|acceptance|lab/i.test(businessName),'A clearly named new fixture business is required');
 const c=parseEnv(readFileSync('deploy/.env.backend','utf8'));assert.equal(c.VPS_HOST,'144.79.249.4');assert.equal(c.VPS_PROJECT_DIR,'/opt/lpg');
 const ssh=[...(c.VPS_SSH_KEY?['-i',c.VPS_SSH_KEY]:[]),'-p',c.VPS_PORT,'-o','BatchMode=yes','-o','StrictHostKeyChecking=yes',`${c.VPS_USER}@${c.VPS_HOST}`];
 const source=`import json,subprocess,sys
p=json.load(sys.stdin)
cmd=['docker','compose','--project-directory','/opt/lpg','--env-file','/opt/lpg/.env','-p','lpg','-f','/opt/lpg/compose.yml','-f','/opt/lpg/compose.vps.yml']
js="""const fs=require('node:fs');let input='';process.stdin.on('data',b=>input+=b);process.stdin.on('end',async()=>{try{const p=JSON.parse(input),c=JSON.parse(fs.readFileSync('/run/account-service.json','utf8'));const r=await fetch(c.apiURL+'/auth/v1/admin/users',{method:'POST',headers:{apikey:c.publicKey,Authorization:'Bearer '+c.serviceKey,'Content-Type':'application/json'},body:JSON.stringify({email:p.email,password:p.password,email_confirm:true})});const d=await r.json();if(!r.ok)throw Error('Fixture Auth creation refused');process.stdout.write(JSON.stringify({id:d.id}));}catch{console.error('Trusted fixture Auth operation failed');process.exitCode=1;}});"""
r=subprocess.run(cmd+['exec','-T','account-service','node','-e',js],input=json.dumps(p).encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
if r.returncode:raise RuntimeError('Trusted fixture Auth creation failed')
u=json.loads(r.stdout)['id']
def lit(v):return "'"+v.replace("'","''")+"'"
uid=lit(u)+'::uuid'
if p['platform']:
 sql="begin;insert into app_private.platform_superadmins(user_id) values("+uid+");insert into app_private.account_security(user_id) values("+uid+");select json_build_object('user_id',"+uid+");commit;"
else:
 sql='begin;'+p['helpers']+"select set_config('request.jwt.claim.sub',"+lit(u)+",true);select pg_temp.fixture_business("+lit(p['businessName'])+','+lit(p['ownerName'])+');commit;'
r=subprocess.run(cmd+['exec','-T','db','psql','-X','-U','supabase_admin','-d','postgres','-qAt','-v','ON_ERROR_STOP=1'],input=sql.encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
if r.returncode:
 subprocess.run(cmd+['exec','-T','db','psql','-X','-U','supabase_admin','-d','postgres','-qAt','-v','ON_ERROR_STOP=1'],input=('delete from auth.users where id='+uid+' and not exists(select 1 from public.user_profiles where user_id='+uid+');').encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 raise RuntimeError('Trusted fixture membership creation failed; only its newly created unassigned Auth identity was eligible for cleanup')
print(r.stdout.decode().strip().splitlines()[-1])
`;
 const quote=v=>"'"+v.replaceAll("'","'\"'\"'")+"'";
 let output;try{output=execFileSync('ssh',[...ssh,'sudo -n python3 -c '+quote(source)],{input:JSON.stringify({email,password,businessName,ownerName,platform,helpers:readFileSync('supabase/tests/account-access-fixtures.sql','utf8')}),encoding:'utf8',maxBuffer:1024*1024});}
 catch{throw Error('Trusted fixture provisioning failed; inspect only its newly created fixture identity privately.');}
 return JSON.parse(output.trim());
}
export async function provisionTestBusiness(client,params) {
 const {data:current}=await client.auth.getSession();assert(!current.session,'Never repurpose an already signed-in account for a fixture');
 const result=await provisionTestIdentity(params);
 const {data,error}=await client.auth.signInWithPassword({email:params.email,password:params.password});if(error)throw Error('Fixture sign-in failed');
 return {...data,tenant_id:result.tenant_id};
}
