import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { openSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { state, read, save, sql } from './common.mjs';
import { verify } from './verify.mjs';

// Resume prepared data; never replace the manifest or replay committed seed batches.
const start = Number(process.argv[2] || 80);
const prefix = process.argv[3] || 'bracket';
const verifiedAt = process.argv.indexOf('--verified');
const verifiedLabel = verifiedAt < 0 ? null : process.argv[verifiedAt + 1];
assert(Number.isInteger(start) && start > 0);
assert(/^[a-z0-9-]+$/.test(prefix));
if(verifiedAt>=0) assert(verifiedLabel && /^[a-z0-9-]+$/.test(verifiedLabel));
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const events = [];
function note(message, detail = {}) {
  const event = { time: new Date().toISOString(), message, ...detail };
  events.push(event);
  save('bracket-progress.json', events);
  console.log(JSON.stringify(event));
}
async function command(program, args, allowPerformanceFailure = false) {
  const child = spawn(program, args, { windowsHide: true,
    stdio: ['ignore', openSync(join(state, 'bracket.stdout'), 'a'), openSync(join(state, 'bracket.stderr'), 'a')] });
  const code = await new Promise((resolve, reject) => {
    child.on('error', reject);
    child.on('close', resolve);
  });
  if (code !== 0 && !(allowPerformanceFailure && code === 2)) {
    throw Error(`Command failed (${code}): ${args.slice(0, 2).join(' ')}`);
  }
}
async function stage(users, label, seconds = 300) {
  assert(!existsSync(join(state, label + '-run.json')), 'Use a fresh label prefix when restarting; preserve earlier evidence');
  note('Starting stage', { users, label, seconds });
  await command('node', ['supabase/tests/vps-capacity/stage.mjs', String(users), label, String(seconds), '60'], true);
  await command('python', ['supabase/tests/vps-capacity/analyze.py', label]);
  const run = read(label + '-run.json');
  note('Stage complete', { users, label, pass: run.pass, safety_stop: run.safety_stop });
  await delay(30000);
  return run.pass;
}

try {
  note('Waiting for complete prepared businesses; no measured load', { start });
  while (read('manifest.json').accounts.length < start || !read('manifest.json').accounts.every(a => a.seeded === 20000)) {
    await delay(15000);
  }
  if(verifiedLabel) {
    const audit=read(`verification-${verifiedLabel}.json`);
    assert(Object.values(audit.checks).every(n=>n===0));
    assert.equal(audit.counts.businesses,read('manifest.json').accounts.length);
    assert(audit.counts.sales>=20000*audit.counts.businesses && audit.auth_isolation_probes>=Math.min(5,audit.counts.businesses));
    assert(Date.now()/1000-audit.time<900,'A fresh completed audit is required');
    assert(existsSync(join(state,`preservation-${verifiedLabel}.json`)),'Completed preservation check required');
    assert.equal(sql("select count(*) from pg_trigger where tgname='zzz_lpg_capacity_date'"),'0');
    note('Reusing fresh completed post-stage audit; histories are already prepared', { audit: verifiedLabel });
    await delay(30000);
  } else {
    sql("set statement_timeout='300s'; vacuum(analyze) public.sales, public.sale_items, public.sale_payments, public.wallet_transactions, public.customer_transactions, public.inventory_movements, public.customers, public.purchases;");
    // Finish preparation's dirty-page/WAL work before the quiet recovery window.
    sql("set statement_timeout='300s'; checkpoint;");
    await delay(60000);
    await verify('bracket-preflight');
  }
  note('Checking lightweight public HTTPS transport separately', { connections: start });
  await command('node', ['supabase/tests/vps-capacity/transport.mjs', String(start)]);
  await delay(30000);
  let low = 0, upper = start;
  if (await stage(start, `${prefix}-start-${start}`)) {
    low = start;
    upper = start * 2;
    for (;;) {
      note('Preparing larger bracket', { businesses: upper });
      await command('node', ['supabase/tests/vps-capacity/prepare.mjs', 'accounts', String(upper)]);
      await command('node', ['supabase/tests/vps-capacity/seed-parallel.mjs', '3']);
      await delay(60000);
      await verify('bracket-prepared-' + upper);
      if (!await stage(upper, `${prefix}-expand-${upper}`)) {
        // Stored population grew: the earlier lower bound must pass again here.
        if (!await stage(low, `${prefix}-fixed-${low}`)) {
          upper = low;
          low = 0;
        }
        break;
      }
      low = upper;
      upper *= 2;
    }
  }
  // At 80 failure: 40, then 60 if 40 passes; continue to an integer bracket.
  while (upper - low > 1) {
    const users = Math.floor((low + upper) / 2);
    if (await stage(users, `${prefix}-search-${users}`)) low = users;
    else upper = users;
  }
  if (!low) throw Error('No passing active-user point');
  while (!await stage(low, `${prefix}-endurance-${low}`, 1800)) {
    upper = Math.min(upper, low);
    if (--low === 0) throw Error('No endurance pass');
  }
  await verify('bracket-final');
  save('bracket-result.json', { initial: start, confirmed: low, first_failing: upper,
    population: read('manifest.json').accounts.length, finished: new Date().toISOString() });
  note('Measurements finished; cleanup, health checks and reporting remain', read('bracket-result.json'));
} catch (error) {
  save('bracket-error.json', { error: error.message, time: new Date().toISOString() });
  note('Stopped for investigation', { error: error.message });
  process.exitCode = 1;
}
