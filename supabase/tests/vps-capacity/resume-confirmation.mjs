// Resume a stopped run without replacing prior evidence or provisioning accounts twice.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { existsSync, openSync } from 'node:fs';
import { join } from 'node:path';
import { state, read, save, sql } from './common.mjs';
import { verify } from './verify.mjs';

const pause=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const events=[];
function progress(message,detail={}) {const e={time:new Date().toISOString(),message,...detail};events.push(e);save('resume-progress.json',events);console.log(JSON.stringify(e));}
async function command(program,args,performance=false) {
  const child=spawn(program,args,{windowsHide:true,stdio:['ignore',openSync(join(state,'resume-commands.stdout'),'a'),openSync(join(state,'resume-commands.stderr'),'a')]});
  const code=await new Promise(resolve=>child.on('close',resolve));
  assert(code===0 || performance && code===2,`Command failed (${code}); inspect ignored resume output`);
}
async function stage(users,label,seconds=300) {
  assert(!existsSync(join(state,label+'-run.json')),'Preserve the prior run; choose a new stage label');
  progress('Starting corrected confirmation stage',{users,label,seconds,population:read('manifest.json').accounts.length});
  await command('node',['supabase/tests/vps-capacity/stage.mjs',String(users),label,String(seconds),'60'],true);
  await command('python',['supabase/tests/vps-capacity/analyze.py',label]);
  const r=read(label+'-run.json');progress('Confirmation stage finished',{users,label,pass:r.pass,safety_stop:r.safety_stop});
  await pause(30000);return r;
}
async function prepare(users) {
  await command('node',['supabase/tests/vps-capacity/prepare.mjs','accounts',String(users)]);
  await command('node',['supabase/tests/vps-capacity/seed-parallel.mjs','3']);
  sql("set lock_timeout='2s';set statement_timeout='180s';vacuum (analyze) public.sales,public.sale_items,public.sale_payments,public.wallet_transactions,public.customer_transactions,public.inventory_movements,public.purchases,public.customers;");
  await pause(60000);await verify('resume-prepared-'+users);
}

try {
  progress('Checking recovered monitoring and correctness; no measured load running.');
  await verify('network-recovered');
  let high=0,upper;
  for(const users of [1,2,5,10,15]) {
    const r=await stage(users,'confirm-'+users);
    if(r.pass)high=users;else{upper=users;break;}
  }
  if(!upper) {
    for(let users=20;!upper;users+=5) {
      progress('Preparing the next requested concurrency',{users});await prepare(users);
      const r=await stage(users,'confirm-'+users);
      if(r.pass)high=users;else upper=users;
    }
    // Stored population grew beyond fifteen; repeat passing points at fixed population.
    const sequence=[1,2,5,...Array.from({length:Math.max(0,(high-5)/5)},(_,i)=>10+i*5)];
    high=0;
    for(const users of sequence) {const r=await stage(users,'final-fixed-'+users);if(r.pass)high=users;else{upper=users;break;}}
  }
  const correctedFailure=upper;
  while(upper-high>1) {
    const users=Math.floor((upper+high)/2),r=await stage(users,'fine-'+users);
    if(r.pass)high=users;else upper=users;
  }
  assert(high>0,'No passing concurrency');
  let endurance;
  do {endurance=await stage(high,'endurance-'+high,1800);if(!endurance.pass){upper=Math.min(upper,high);high--;}} while(!endurance.pass && high>0);
  assert(endurance.pass,'No endurance stage passed');
  await verify('post-endurance');
  save('suite-result.json',{finished:new Date().toISOString(),discovery_highest:high,first_failed:15,
    corrected_first_failed:correctedFailure,confirmed:high,endurance_pass:true,fine_failure:upper,
    population:read('manifest.json').accounts.length,network_setup_interruption:true,
    note:'Final confirmation uses the corrected workload, fixed stored population and recovered network path.'});
  progress('Measurements complete; final cleanup and reporting remain.',read('suite-result.json'));
} catch(error) {progress('Confirmation stopped for investigation',{error:error.message});save('resume-error.json',{error:error.message,time:new Date().toISOString()});process.exitCode=1;}
