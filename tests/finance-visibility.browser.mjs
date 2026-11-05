// Published app and real backend. No routes or financial responses are intercepted.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
import {parseEnv} from 'node:util';
import {chromium} from 'playwright';
import {createClient} from '@supabase/supabase-js';
assert(process.argv.includes('--vps'));
const folder='.temp/finance-visibility-live',file=`${folder}/manifest.json`;
const m=JSON.parse(readFileSync(file,'utf8')),secrets=JSON.parse(readFileSync(`${folder}/credentials.json`,'utf8'));
assert(m.setup_at&&!m.cleaned_at);
const f=parseEnv(readFileSync('deploy/.env.frontend','utf8')),url='https://floral-dew-443b.khandakarsifat.workers.dev';
assert.equal(f.VITE_SUPABASE_URL,'https://api.lpg.144.79.249.4.sslip.io');
const checked=async p=>{const {data,error}=await p;if(error)throw Error(error.message);return data;};
const browser=await chromium.launch({channel:'chrome',headless:true});
const owner=await browser.newContext({viewport:{width:1440,height:1000},serviceWorkers:'block'});
const staff=await browser.newContext({viewport:{width:1440,height:1000},serviceWorkers:'block'});
const errors=[];const op=await owner.newPage(),sp=await staff.newPage();
for(const p of [op,sp]){p.setDefaultTimeout(25000);p.on('pageerror',e=>errors.push(e.message));}
const settled=async p=>{await p.waitForLoadState('networkidle');};
const login=async(p,secret)=>{await p.goto(`${url}/?finance-visibility=${Date.now()}#/login`);await p.getByLabel('Email Address',{exact:true}).fill(secret.email);await p.getByLabel('Password',{exact:true}).fill(secret.password);await p.getByRole('button',{name:'Sign In',exact:true}).click();await p.waitForURL(u=>!u.hash.includes('/login'));await settled(p);};
const fit=async(p,label)=>assert(await p.evaluate(()=>[document.documentElement,...document.querySelectorAll('dialog[open]')].every(e=>e.scrollWidth<=e.clientWidth+2)),label+' horizontal overflow');
const client=createClient(f.VITE_SUPABASE_URL,f.VITE_SUPABASE_ANON_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
try{
 await login(op,secrets.owner);
 await op.goto(`${url}/#/finance`);await op.getByRole('button',{name:'Product performance & FIFO',exact:true}).click();await settled(op);
 const quantity=op.locator('.performance-table').first();await quantity.getByText('Jamuna acceptance',{exact:true}).waitFor();assert.match(await quantity.innerText(),/70/);assert.match(await quantity.innerText(),/30/);
 await op.getByRole('button',{name:'Jamuna acceptance · 12 kg · 22mm',exact:true}).click();await op.getByText(/Available: 97 filled/).waitFor();await fit(op,'Desktop product report');await op.screenshot({path:`${folder}/desktop-performance.png`});
 await op.getByRole('combobox',{name:/Selling price tier/}).selectOption('wholesale');await op.getByText(/Retail fallback/).first().waitFor();assert.match(await op.locator('.performance-table').last().innerText(),/Package margin/);
 await op.getByRole('combobox',{name:/Selling price tier/}).selectOption('retail');await op.getByText(/Available: 97 filled/).waitFor();
 await op.setViewportSize({width:393,height:852});await settled(op);await fit(op,'Android-sized FIFO');assert.equal(await quantity.locator('thead').evaluate(e=>getComputedStyle(e).display),'table-header-group');assert.equal(await quantity.locator('tbody tr').first().evaluate(e=>getComputedStyle(e).display),'table-row');await op.screenshot({path:`${folder}/phone-performance.png`});await op.locator('.performance-table').last().locator('thead').scrollIntoViewIfNeeded();await op.screenshot({path:`${folder}/phone-fifo.png`});
 await op.setViewportSize({width:1440,height:1000});
 if(!m.permissions_at){
  await op.goto(`${url}/#/users`);const card=op.locator('.access-user-card').filter({hasText:secrets.staff.email});await card.getByRole('button',{name:'Manage access',exact:true}).click();const dialog=op.getByRole('dialog').last();
  await dialog.getByRole('checkbox',{name:/Customize this user/}).check();
  const all=dialog.getByRole('checkbox',{name:/^View all financial entries/});await dialog.locator('details').filter({hasText:'View all financial entries'}).locator('summary').click();await all.uncheck();
  await dialog.getByRole('checkbox',{name:/^View loans and lending/}).uncheck();
  for(const name of ['Cash Register','bKash','Nagad','Primary Bank Account'])await dialog.getByRole('checkbox',{name:`${name} Balance`,exact:true}).uncheck();
  await dialog.getByRole('checkbox',{name:'Primary Bank Account Use',exact:true}).uncheck();await dialog.getByRole('checkbox',{name:'Primary Bank Account History',exact:true}).uncheck();
  await fit(op,'Desktop wallet access editor');await op.screenshot({path:`${folder}/desktop-wallet-access.png`});
  await op.setViewportSize({width:393,height:852});await fit(op,'Android-sized wallet editor');await op.screenshot({path:`${folder}/phone-wallet-access.png`});
  const save=op.waitForResponse(r=>r.url().endsWith('/rpc/manage_business_user'));await dialog.getByRole('button',{name:'Save access',exact:true}).click();const r=await save;assert(r.ok(),await r.text());await dialog.waitFor({state:'detached'});
  m.permissions_at=new Date().toISOString();writeFileSync(file,JSON.stringify(m,null,2));
 }
 if(m.permissions_at){
  await op.goto(`${url}/#/users`);await op.locator('.access-user-card').filter({hasText:secrets.staff.email}).getByRole('button',{name:'Manage access',exact:true}).click();const d=op.getByRole('dialog').last();const matrix=d.locator('.wallet-access-table');await matrix.getByRole('checkbox',{name:'Cash Register Balance',exact:true}).waitFor();await op.setViewportSize({width:393,height:852});await matrix.scrollIntoViewIfNeeded();await fit(op,'Android-sized wallet matrix');assert.equal(await matrix.locator('thead').evaluate(e=>getComputedStyle(e).display),'table-header-group');await op.screenshot({path:`${folder}/phone-wallet-access.png`});await d.getByRole('button',{name:'Cancel',exact:true}).click();await op.setViewportSize({width:1440,height:1000});
 }
 await checked(client.auth.signInWithPassword(secrets.staff));const access=await checked(client.rpc('get_access_context'));assert.equal(access.tenant_id,m.tenant_id);
 for(const permission of ['reports:view','finance:activity','finance:loans','finance:entries:all'])assert(!access.permissions.includes(permission),permission+' must be absent');
 const wallets=await checked(client.rpc('get_finance_wallets'));assert(wallets.every(w=>w.balance===null&&w.opening_balance===null));assert.equal(wallets.find(w=>w.wallet_id===m.bank),undefined);
 assert.equal((await client.from('wallets').select('*')).error?.code,'42501');assert.equal((await client.from('wallet_transactions').select('*')).error?.code,'42501');
 const ledger=await checked(client.rpc('get_wallet_ledger'));assert(ledger.entries.every(e=>e.balance_after===null&&e.wallet_id!==m.bank));
 const denied=await client.rpc('move_wallet_money',{p_payload:{action:'transfer',wallet_id:m.cash,destination_id:m.bank,amount:5,reason:'Unauthorized destination acceptance'},p_request_id:crypto.randomUUID()});assert.equal(denied.error?.code,'42501');
 assert.equal((await client.rpc('get_accounting_register',{p_kind:'loans'})).error?.code,'42501');assert.equal((await client.rpc('get_finance_analysis',{p_filters:{from:'2026-11-01',to:'2026-11-05'}})).error?.code,'42501');
 await login(sp,secrets.staff);await sp.goto(`${url}/#/finance`);await settled(sp);const nav=sp.getByRole('navigation',{name:'Finance',exact:true});
 for(const name of ['Analysis','Accounting activity','Loans & lending'])assert.equal(await nav.getByRole('button',{name,exact:true}).count(),0);
 assert.equal(await sp.getByText('Balance hidden',{exact:true}).count(),3);assert.equal(await sp.getByText('Primary Bank Account',{exact:true}).count(),0);
 if(!m.entry_id){
  await sp.getByRole('button',{name:'Financial entry',exact:true}).click();const d=sp.getByRole('dialog').last();
  await d.getByRole('button',{name:/^Type /}).click();await d.getByRole('option',{name:/Visibility acceptance expense/}).click();
  await d.getByLabel('Paid from wallet',{exact:true}).selectOption(m.cash);assert.equal(await d.getByLabel('Paid from wallet').locator(`option[value="${m.bank}"]`).count(),0);
  await d.getByLabel('Amount (Tk)',{exact:true}).fill('37.5');await d.getByLabel('Description / asset name',{exact:true}).fill('Published UI hidden wallet expense');
  await d.getByRole('button',{name:'Review entry',exact:true}).click();const response=sp.waitForResponse(r=>r.url().endsWith('/rpc/record_financial_entry'));await sp.getByRole('dialog').last().getByRole('button',{name:'Record entry',exact:true}).click();const r=await response;const result=await r.json();assert(r.ok(),result.message);m.entry_id=result.entry_id;writeFileSync(file,JSON.stringify(m,null,2));await sp.getByRole('dialog').last().waitFor({state:'detached'});
 }
 await nav.getByRole('button',{name:'Financial entries',exact:true}).click();await sp.getByText('Published UI hidden wallet expense',{exact:true}).waitFor();assert.equal((await checked(client.rpc('get_financial_entries'))).total,1);
 await sp.setViewportSize({width:393,height:852});await fit(sp,'Android-sized restricted finance');await sp.screenshot({path:`${folder}/phone-restricted-finance.png`});
 await nav.getByRole('button',{name:'Product performance & FIFO',exact:true}).click();await settled(sp);await fit(sp,'Android-sized restricted stock report');
 const ownerClient=createClient(f.VITE_SUPABASE_URL,f.VITE_SUPABASE_ANON_KEY,{auth:{persistSession:false,autoRefreshToken:false}});
 await checked(ownerClient.auth.signInWithPassword(secrets.owner));
 const record=async()=>(await checked(ownerClient.rpc('get_business_users'))).entries.find(u=>u.user_id===m.staff_id);
 const original=await record(),scopes=await checked(ownerClient.rpc('get_business_wallet_access',{p_user_id:m.staff_id}));
 const save=async(permissions,wallets)=>{const current=await record();return checked(ownerClient.rpc('manage_business_user',{p_user_id:m.staff_id,p_name:current.full_name,p_role:current.role,p_active:true,p_expected_revision:current.revision,p_permissions:permissions,p_wallet_access:wallets.map(({wallet_id,can_use,can_balance,can_history})=>({wallet_id,can_use,can_balance,can_history}))}));};
 try{
  const posScopes=scopes.map(w=>({...w,can_use:w.wallet_id===m.cash,can_balance:w.wallet_id===m.cash,can_history:false}));
  await save(['pos:sell','preferences:manage'],posScopes);
  await sp.goto(`${url}/#/pos`);await sp.reload();await sp.locator('.topbar-wallet').getByText('Tk -37.50',{exact:true}).waitFor();
  assert.equal(await sp.getByRole('link',{name:'Finance',exact:true}).count(),0);
  const posAccess=await checked(client.rpc('get_access_context'));assert(!posAccess.permissions.includes('finance:view'));
  const visible=await checked(client.rpc('get_finance_wallets'));assert.equal(visible.length,1);assert.equal(visible[0].wallet_id,m.cash);assert.equal(Number(visible[0].balance),-37.5);
  await save(['pos:sell','preferences:manage'],posScopes.map(w=>({...w,can_balance:false})));
  const revoked=await checked(client.rpc('get_access_context'));assert.deepEqual(revoked.permissions,posAccess.permissions);assert(revoked.access_revision>posAccess.access_revision);
  // Observe the normal access-context polling and revision-driven query reset, without reloading.
  await sp.locator('.topbar-wallet').waitFor({state:'detached',timeout:35000});
 }finally{await save(original.custom_permissions,scopes);await ownerClient.auth.signOut({scope:'local'});}
 assert.deepEqual(errors,[]);m.browser_at=new Date().toISOString();m.browser={desktop:true,phone:true,real_ui_write:true,hidden_api:true,permissions_editor:true,pos_only_balance:true,live_scope_revocation:true};writeFileSync(file,JSON.stringify(m,null,2));console.log('PASS actual published desktop/phone reports, owner wallet permission editor, staff hidden-wallet expense, restricted API/tabs and live POS-only wallet visibility/revocation');
}catch(error){for(const [p,name] of [[op,'owner'],[sp,'staff']])if(await p.locator('input[type=password]').count()===0)await p.screenshot({path:`${folder}/${name}-failure.png`}).catch(()=>{});throw error;}finally{await client.auth.signOut({scope:'local'});await browser.close();}
