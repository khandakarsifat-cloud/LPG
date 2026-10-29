import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, openSync, existsSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { createClient } from '@supabase/supabase-js';
import { createHash } from 'node:crypto';
import { state, frontend, read, save } from './common.mjs';
import { verify } from './verify.mjs';

const users=Number(process.argv[2]), label=process.argv[3]||`stage-${users}`;
const seconds=Number(process.argv[4]||300), warmup=Number(process.argv[5]||60);
assert(Number.isInteger(users) && users>0);
assert(/^[a-z0-9-]+$/.test(label));
assert(!existsSync(join(state,'stop-load')),'Stop marker present; refusing admission before any load');
const manifest=read('manifest.json');
assert(manifest.accounts.length>=users && manifest.accounts.every(a=>a.seeded===20000),'Prepare complete history before load');
assert.equal(new Set(manifest.accounts.map(a=>a.tenant_id)).size,manifest.accounts.length,'Each user must own a different business');
assert.equal(new Set(manifest.accounts.map(a=>a.user_id)).size,manifest.accounts.length,'Each business must have a distinct Auth user');
const accounts=[];
for (const a of manifest.accounts) {
  const c=createClient(frontend.VITE_SUPABASE_URL,frontend.VITE_SUPABASE_ANON_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
  const result=a.expires_at*1000>Date.now()+(seconds+warmup+240)*1000
    ? await c.auth.setSession({access_token:a.token,refresh_token:a.refresh_token})
    : await c.auth.refreshSession({refresh_token:a.refresh_token});
  assert.ifError(result.error); assert(result.data.session);
  a.token=result.data.session.access_token; a.refresh_token=result.data.session.refresh_token; a.expires_at=result.data.session.expires_at;
  const customers=await c.from('customers').select('customer_id,phone,tier').order('phone').limit(100);
  assert.ifError(customers.error); assert.equal(customers.data.length,100);
  accounts.push({...a,customers:customers.data});
  save('manifest.json',manifest);
}
save('accounts.json',accounts);
save('config.json',{url:frontend.VITE_SUPABASE_URL,anon:frontend.VITE_SUPABASE_ANON_KEY,worker:'https://floral-dew-443b.khandakarsifat.workers.dev'});
const summary=join(state,label+'-summary.json');
const executable=join(state,'tools','k6-v2.3.0-windows-amd64','k6.exe');
const before=JSON.parse(await (await fetch('http://127.0.0.1:9917/state')).text());
assert(before.server.time && Date.now()/1000-before.server.time<15,'Fresh monitoring required');
const samplerHash=createHash('sha256').update(readFileSync('supabase/tests/vps-capacity/sample.py')).digest('hex');
assert.equal(before.server.sampler_sha256,samplerHash,'Running sampler must match the checked source');
const started=Date.now()/1000;
const record={label,users,seconds,warmup,started,population:manifest.accounts.length,
  sampler_sha256:samplerHash,
  workload_sha256:createHash('sha256').update(readFileSync('supabase/tests/vps-capacity/workload.js')).digest('hex')};
save('current-stage.json',record);
const child=spawn(executable,['run','--quiet','--address=127.0.0.1:16565','--tag','stage='+label,'--out','json='+join(state,label+'-requests.jsonl'),
  '--out','experimental-prometheus-rw','supabase/tests/vps-capacity/workload.js'],{
  windowsHide:true,stdio:['ignore',openSync(join(state,label+'.stdout'),'w'),openSync(join(state,label+'.stderr'),'w')],
  env:{...process.env,USERS:String(users),STAGE:label,DURATION:String(seconds),WARMUP:String(warmup),CONFIG:join(state,'config.json'),
    ACCOUNTS:join(state,'accounts.json'),SUMMARY:summary,
    K6_PROMETHEUS_RW_SERVER_URL:'http://127.0.0.1:19090/api/v1/write',
    K6_PROMETHEUS_RW_TREND_STATS:'avg,p(95),p(99)',K6_PROMETHEUS_RW_PUSH_INTERVAL:'5s',K6_PROMETHEUS_RW_STALE_MARKERS:'true',K6_NO_USAGE_REPORT:'true'},
});
record.pid=child.pid; save('current-stage.json',record);
let stopping=false, busySamples=0, memorySamples=0, staleSamples=0;
let stopFallback;
let sampleBaseline=before.server;
async function stop(reason) {
  if (stopping) return;
  stopping=true; record.safety_stop=reason;
  if (/Windows|Monitoring|monitoring|network/i.test(reason)) record.invalid_environment=true;
  console.log('AUTOMATIC SAFETY STOP: '+reason);
  // Let k6 own shutdown and write its summary; Windows SIGINT would terminate it.
  try {
    const response=await fetch('http://127.0.0.1:16565/v1/status',{method:'PATCH',
      headers:{'Content-Type':'application/json'},signal:AbortSignal.timeout(2000),
      body:JSON.stringify({data:{type:'status',id:'default',attributes:{stopped:true}}})});
    if(!response.ok) throw Error('k6 stop endpoint rejected request');
  } catch {record.hard_stop=true;child.kill();}
  stopFallback=setTimeout(()=>{if(child.exitCode===null){record.hard_stop=true;child.kill();}},25000);
  stopFallback.unref();
}
const watchdog=setInterval(async()=>{
  try {
    const current=await (await fetch('http://127.0.0.1:9917/state',{signal:AbortSignal.timeout(2000)})).json();
    const s=current.server,w=current.windows;
    staleSamples=Date.now()/1000-s.time>20?staleSamples+1:0;
    if (staleSamples>=3) await stop('Monitoring stale for 30 seconds');
    if (s.memory.MemAvailable<512*1024**2 || s.disk_free_bytes<15*1024**3) await stop('VPS free memory/disk reserve');
    if (s.memory.SwapTotal-s.memory.SwapFree>512*1024**2) await stop('VPS swap use above 512 MiB');
    if (s.vm.oom_kill>sampleBaseline.vm.oom_kill) await stop('Host OOM event');
    for (const [name,c] of Object.entries(s.containers)) {
      if (c.events.oom_kill>(sampleBaseline.containers[name]?.events.oom_kill||0)) await stop('Container OOM event');
    }
    busySamples=s.derived.cpu_busy_pct>95?busySamples+1:0;
    if (busySamples>=6) await stop('Host CPU above 95% for 60 seconds');
    memorySamples=s.memory.MemAvailable<768*1024**2?memorySamples+1:0;
    if (memorySamples>=3) await stop('Available memory below 768 MiB for 30 seconds');
    if (s.database.longest_seconds>25 || s.database.blocked>=5) await stop('Long query or database blocking safety limit');
    if (w.cpu_pct>90 || w.available<2*1024**3) await stop('Windows generator resource limit');
    if (w.power_plugged===0 && w.battery_pct<15) await stop('Windows generator battery reserve');
    if(before.windows.network_signature && w.network_signature!==before.windows.network_signature) await stop('Windows network interface/address changed');
    if (existsSync(join(state,'stop-load'))) await stop('Manual stop marker');
  } catch {
    staleSamples++; if (staleSamples>=3) await stop('Monitoring bridge unavailable');
  }
},10000);
const code=await new Promise(resolve=>child.on('close',resolve));
clearInterval(watchdog);
clearTimeout(stopFallback);
record.ended=Date.now()/1000; record.exit=code;
// A brief Wi-Fi disconnect can recover before the sampler-staleness guard fires.
// Check the actual Windows event log once, outside measurement, before assigning
// a VPS failure bound. Export only a count, never SSIDs or interface identifiers.
if(process.platform==='win32') {
  try {
    const script=`$ErrorActionPreference='Stop'; $from=[DateTimeOffset]::FromUnixTimeMilliseconds(${Math.floor(started*1000)}).LocalDateTime; $to=[DateTimeOffset]::FromUnixTimeMilliseconds(${Math.floor(record.ended*1000)}).LocalDateTime; try { @(Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-WLAN-AutoConfig/Operational';Id=8003;StartTime=$from;EndTime=$to} -ErrorAction Stop).Count } catch { if($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*'){0}else{'unavailable'} }`;
    const count=execFileSync('powershell.exe',['-NoProfile','-NonInteractive','-Command',script],
      {encoding:'utf8',windowsHide:true,timeout:15000}).trim();
    record.windows_network_log_available=/^\d+$/.test(count);
    if(record.windows_network_log_available) {
      record.windows_wifi_disconnects=Number(count);
      if(Number(count)>0) {
        record.invalid_environment=true;
        record.safety_stop||='Windows Wi-Fi disconnected during stage';
      }
    }
  } catch {record.windows_network_log_available=false;}
}
save(label+'-run.json',record);
save('current-stage.json',{...record,users:0});
assert(existsSync(summary),'k6 stopped without summary; inspect ignored output');
const data=JSON.parse(readFileSync(summary,'utf8'));
const metrics=data.metrics;
const metric = key => metrics[key]?.values;
record.metrics={errors:metric('operation_errors{phase:measured}'),read:metric('read_latency{phase:measured}'),
  write:metric('write_latency{phase:measured}'),latency:metric('operation_latency{phase:measured}'),
  correctness:metric('correctness_failures'),idempotent_replays:metric('idempotent_replays')};
record.measured_start=metric('measurement_start_seconds')?.value;
record.pass=!record.safety_stop && code===0;
save(label+'-run.json',record);
console.log(JSON.stringify({stage:label,users,pass:record.pass,exit:code,metrics:record.metrics}));
await verify(label,{auth:!label.startsWith('smoke')});
if (!record.pass) process.exitCode=record.invalid_environment?3:2;
