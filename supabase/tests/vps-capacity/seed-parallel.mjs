import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { state, remote, read, save, sql, uuid, sshArgs } from './common.mjs';

const manifest=read('manifest.json');
assert(manifest.accounts.every(a=>a.tenant_id),'Finish account provisioning first');
const workers=Number(process.argv[2]||3);
assert(workers>=1 && workers<=4);
remote('umask 077; cat > /tmp/lpg-capacity-fixture.py',readFileSync(new URL('./fixture.py',import.meta.url),'utf8'));
const tables=['sales','sale_payments','sale_bottle_receipts','customer_transactions','wallet_transactions','inventory_movements',
  'purchases','purchase_payments','purchase_activity','transits','finance_requests'];
// Private preparation hooks let independent fixture tenants seed in parallel.
// Exact UUID registration plus a session-only GUC prevents non-fixture changes.
sql(`begin; set local lock_timeout='2s'; create schema lpg_capacity_fixture;
 create table lpg_capacity_fixture.tenants(tenant_id uuid primary key references public.tenants(tenant_id));
 insert into lpg_capacity_fixture.tenants values ${manifest.accounts.map(a=>`(${uuid(a.tenant_id)})`).join(',')};
 revoke all on schema lpg_capacity_fixture from public,anon,authenticated;
 create function lpg_capacity_fixture.stamp() returns trigger language plpgsql security definer set search_path='' as $stamp$
 begin
  if new.tenant_id::text=current_setting('lpg.fixture_tenant',true) and nullif(current_setting('lpg.fixture_history_at',true),'') is not null
   and exists(select 1 from lpg_capacity_fixture.tenants f where f.tenant_id=new.tenant_id) then
   new.created_at:=current_setting('lpg.fixture_history_at')::timestamptz;
  end if;
  return new;
 end $stamp$;
 revoke all on function lpg_capacity_fixture.stamp() from public,anon,authenticated;
 ${tables.map(table=>`create trigger zzz_lpg_capacity_date before insert on public.${table} for each row execute function lpg_capacity_fixture.stamp();`).join('\n')}
 commit;`);
let failure;
const busy=new Set();
async function worker() {
  while (!failure) {
    const a=manifest.accounts.filter(a=>a.seeded<20000 && !busy.has(a.index))
      .sort((a,b)=>a.seeded-b.seeded || a.index-b.index)[0];
    if (!a) return;
    busy.add(a.index);
    if(existsSync(join(state,'stop-load'))) { failure=Error('Preparation stopped by marker');busy.delete(a.index);return; }
      const payload={...a,action:'seed',start:a.seeded,count:Math.min(500,20000-a.seeded),parallel_dates:true};
      const encoded=Buffer.from(JSON.stringify(payload)).toString('base64');
      const program=`import base64,json,runpy,io,sys; sys.stdin=io.StringIO(base64.b64decode('${encoded}').decode()); runpy.run_path('/tmp/lpg-capacity-fixture.py',run_name='__main__')`;
      try {
        const result=await new Promise((resolve,reject)=>{
          const child=spawn('ssh',[...sshArgs,'sudo -n python3 -'],{windowsHide:true,stdio:['pipe','pipe','pipe']});
          let out='',err=''; child.stdout.on('data',data=>out+=data);child.stderr.on('data',data=>err+=data);
          child.on('close',code=>{if (code===0) resolve(JSON.parse(out)); else {writeFileSync(join(state,'private-seed-error.txt'),err);reject(Error('Private seed operation failed'));}});
          child.stdin.end(program);
        });
        a.seeded=result.sales;save('manifest.json',manifest);
        console.log(`Seed business ${a.index}: ${a.seeded}/20000 sales; batch ${result.seconds}s`);
      } catch (error) {failure=error;}
      finally {busy.delete(a.index);}
  }
}
try { await Promise.all(Array.from({length:workers},worker)); }
finally {
  sql(`begin; set local lock_timeout='5s'; ${tables.map(table=>`drop trigger zzz_lpg_capacity_date on public.${table};`).join('\n')} drop schema lpg_capacity_fixture cascade; commit;`);
}
if(failure) throw failure;
console.log('Preparation complete; private fixture schema and all timestamp hooks removed.');
