import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { openSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { state, read, save, sql } from './common.mjs';
import { verify } from './verify.mjs';

const pause = ms => new Promise(resolve=>setTimeout(resolve,ms));
const events=[];
function progress(message,details={}) {
  const event={time:new Date().toISOString(),message,...details};events.push(event);
  save('suite-progress.json',events);console.log(JSON.stringify(event));
}
async function command(name,args,{allowPerformanceFailure=false}={}) {
  const child=spawn(name,args,{windowsHide:true,stdio:['ignore',openSync(join(state,'suite-commands.stdout'),'a'),openSync(join(state,'suite-commands.stderr'),'a')]});
  const code=await new Promise(resolve=>child.on('close',resolve));
  if (!(code===0 || allowPerformanceFailure && code===2)) throw Error(`Command failed (${code}): ${name} ${args.slice(0,2).join(' ')}`);
  return code;
}
async function quiet() {
  progress('Draining and analyzing prepared data; benchmark measurements remain stopped.');
  sql('set lock_timeout=\'2s\'; set statement_timeout=\'180s\'; vacuum (analyze) public.sales,public.sale_items,public.sale_payments,public.wallet_transactions,public.customer_transactions,public.inventory_movements,public.purchases,public.purchase_items,public.customers,public.items,public.sale_bottle_receipts,public.sale_bottle_receipt_lines;');
  await pause(60000);
}
async function stage(users,label,seconds=300,warmup=60) {
  if(existsSync(join(state,'stop-load'))) throw Error('Stop marker present');
  progress('Starting stage',{users,label,seconds,warmup,population:read('manifest.json').accounts.length});
  await command('node',['supabase/tests/vps-capacity/stage.mjs',String(users),label,String(seconds),String(warmup)],{allowPerformanceFailure:true});
  await command('python',['supabase/tests/vps-capacity/analyze.py',label]);
  const result=read(label+'-run.json');
  progress('Stage finished',{users,label,pass:result.pass,safety_stop:result.safety_stop});
  await pause(30000);
  return result;
}

try {
  progress('Waiting for the first five complete isolated businesses.');
  while (!read('manifest.json').accounts.every(a=>a.seeded===20000)) await pause(15000);
  await quiet();
  await verify('preflight');
  await command('node',['supabase/tests/vps-capacity/metadata.mjs']);
  const smoke=await stage(1,'smoke-1',90,0);
  const smokeData=read('smoke-1-analysis.json');
  assert(smokeData.error_rate===0 && smokeData.correctness_failures===0 && !smoke.safety_stop,'Correct workload contract before benchmarking');
  const sequence=[1,2,5];
  let highest=0,failed;
  let cursor=0;
  while (!failed) {
    const users=cursor<sequence.length?sequence[cursor]:5+(cursor-2)*5;
    cursor++;
    if(read('manifest.json').accounts.length<users) {
      progress('Preparing more isolated businesses before the next stage',{population:users});
      await command('node',['supabase/tests/vps-capacity/prepare.mjs','accounts',String(users)]);
      await command('node',['supabase/tests/vps-capacity/seed-parallel.mjs','3']);
      await quiet();await verify('prepared-'+users);
    }
    const result=await stage(users,'discovery-'+users);
    if(result.pass) highest=users;
    else failed=users;
  }
  progress('Discovery bracket identified',{highest,failed});
  // Repeat the passing sequence against the same final stored population.
  const fixed=[1,2,5,...Array.from({length:Math.max(0,(highest-5)/5)},(_,i)=>10+i*5)].filter(n=>n<=highest);
  let confirmed=0,upper=failed;
  for(const users of fixed) {
    const result=await stage(users,'fixed-'+users);
    if(result.pass) confirmed=users;
    else {upper=users;break;}
  }
  while(upper-confirmed>1) {
    const users=Math.floor((upper+confirmed)/2);
    const result=await stage(users,'fine-'+users);
    if(result.pass) confirmed=users;else upper=users;
  }
  assert(confirmed>0,'No concurrency passed the acceptance thresholds');
  let endurance;
  do {
    endurance=await stage(confirmed,'endurance-'+confirmed,1800,60);
    if(!endurance.pass) confirmed--;
  } while(!endurance.pass && confirmed>0);
  await verify('post-endurance');
  save('suite-result.json',{finished:new Date().toISOString(),discovery_highest:highest,first_failed:failed,
    confirmed,endurance_pass:endurance.pass,fine_failure:upper,population:read('manifest.json').accounts.length});
  progress('Capacity measurements complete; cleanup and reporting remain.',read('suite-result.json'));
} catch(error) {
  progress('Suite stopped for investigation',{error:error.message});
  save('suite-error.json',{time:new Date().toISOString(),error:error.message});
  process.exitCode=1;
}
