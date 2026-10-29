import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { openSync } from 'node:fs';
import { join } from 'node:path';
import { state, frontend, read, save } from './common.mjs';

const users=Number(process.argv[2]||80);
assert(Number.isInteger(users)&&users>0);
// A single light request from each VU validates transport separately from the
// history-heavy mixed workload. It cannot establish business-user capacity.
save('transport-config.json',{url:frontend.VITE_SUPABASE_URL,anon:frontend.VITE_SUPABASE_ANON_KEY,
  worker:'https://floral-dew-443b.khandakarsifat.workers.dev'});
const started=Date.now()/1000;
const child=spawn(join(state,'tools','k6-v2.3.0-windows-amd64','k6.exe'),
  ['run','--quiet','supabase/tests/vps-capacity/transport.js'],{windowsHide:true,
    stdio:['ignore',openSync(join(state,'transport.stdout'),'w'),openSync(join(state,'transport.stderr'),'w')],
    env:{...process.env,USERS:String(users),CONFIG:join(state,'transport-config.json'),
      SUMMARY:join(state,'transport-summary.json'),K6_NO_USAGE_REPORT:'true'}});
const code=await new Promise((resolve,reject)=>{child.on('error',reject);child.on('close',resolve);});
const metrics=read('transport-summary.json').metrics;
const result={users,started,ended:Date.now()/1000,pass:code===0,
  requests:metrics.http_reqs.values.count,errors:metrics.http_req_failed.values.rate,
  http_duration:metrics.http_req_duration.values,connecting:metrics.http_req_connecting.values,
  tls:metrics.http_req_tls_handshaking.values};
save('transport-control.json',result);
assert.equal(code,0,'Lightweight transport control failed; investigate before interpreting VPS capacity');
assert.equal(result.requests,users);
console.log(JSON.stringify({transport_users:users,requests:result.requests,pass:result.pass,p99_ms:result.http_duration['p(99)']}));
