// Real Auth/PostgREST acceptance. All writes target newly created fixture businesses.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFileSync, mkdirSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { execFileSync } from 'node:child_process';
assert(process.argv.includes('--vps'), 'Explicit --vps target required');
const f=parseEnv(readFileSync('deploy/.env.frontend','utf8')), b=parseEnv(readFileSync('deploy/.env.backend','utf8'));
assert.equal(f.VITE_SUPABASE_URL,'https://api.lpg.144.79.249.4.sslip.io');assert.equal(b.VPS_PROJECT_DIR,'/opt/lpg');
const { createClient }=await import('@supabase/supabase-js');
const clients=[],users=[],tenants=[];let browser;
const client=()=>{const c=createClient(f.VITE_SUPABASE_URL,f.VITE_SUPABASE_ANON_KEY,{auth:{persistSession:false,autoRefreshToken:false}});clients.push(c);return c;};
const sql=q=>execFileSync('ssh',[...(b.VPS_SSH_KEY ? ['-i', b.VPS_SSH_KEY] : []),'-p',b.VPS_PORT,'-o','BatchMode=yes','-o','StrictHostKeyChecking=yes',`${b.VPS_USER}@${b.VPS_HOST}`,'sudo -n docker compose --project-directory /opt/lpg --env-file /opt/lpg/.env -p lpg -f /opt/lpg/compose.yml -f /opt/lpg/compose.vps.yml exec -T db psql -X -U supabase_admin -d postgres -qAt -v ON_ERROR_STOP=1'],{input:q,encoding:'utf8'}).trim();
const uuid=x=>{assert.match(x,/^[0-9a-f-]{36}$/i);return `'${x}'::uuid`;};
const checked=async request=>{const {data,error}=await request;if(error)throw Error(`${error.code}: ${error.message}`);return data;};
const denied=async request=>{const {error}=await request;assert(error,'Expected rejection');assert.match(error.code,/^(P0001|42501|23503|23514|22P02)$/,'A gateway/network failure cannot establish authorization or validation');return error;};
const preservation="select jsonb_build_object('stock',(select md5(coalesce(jsonb_agg(to_jsonb(i) order by tenant_id,item_id)::text,'')) from public.items i),'wallets',(select md5(coalesce(jsonb_agg(to_jsonb(w) order by tenant_id,wallet_id)::text,'')) from public.wallets w),'sales',(select md5(coalesce(jsonb_agg(to_jsonb(s) order by tenant_id,sale_id)::text,'')) from public.sales s),'customers',(select md5(coalesce(jsonb_agg(to_jsonb(c) order by tenant_id,customer_id)::text,'')) from public.customers c),'ledger',(select md5(coalesce(jsonb_agg(to_jsonb(w) order by tenant_id,transaction_id)::text,'')) from public.wallet_transactions w),'purchases',(select md5(coalesce(jsonb_agg(to_jsonb(p) order by tenant_id,purchase_id)::text,'')) from public.purchases p));";
const before=sql(preservation);
async function account(label){const c=client();const a=await checked(c.auth.signUp({email:`bottles-${label}-${randomUUID()}@example.invalid`,password:randomUUID()+'Aa1!'}));assert(a.user&&a.session);users.push(a.user.id);const t=await checked(c.rpc('setup_business',{p_business_name:'Bottle API fixture '+label,p_owner_name:'Bottle fixture operator'}));tenants.push(t.tenant_id);return {client:c,session:a.session,id:a.user.id,tenant:t.tenant_id};}
try {
 const env={...parseEnv(readFileSync('.env.live-test','utf8')),...process.env};assert.equal(env.LPG_TEST_EMAIL,'sifatsiam244@gmail.com');
 const burner=client(),auth=await checked(burner.auth.signInWithPassword({email:env.LPG_TEST_EMAIL,password:env.LPG_TEST_PASSWORD}));
 const trusted=await checked(burner.from('user_profiles').select('tenant_id,is_active,tenants(business_name)').eq('user_id',auth.user.id).single());assert(trusted.is_active&&trusted.tenant_id);
 console.log('PASS: burner authenticated; trusted membership inspected read-only');
 const owner=await account('owner'),foreign=await account('foreign'),c=owner.client;
 const a=randomUUID(),other=randomUUID(),small=randomUUID();const t=uuid(owner.tenant);
 const brandIds=[randomUUID(),randomUUID(),randomUUID()];
 sql(`insert into public.lpg_brands(tenant_id,brand_id,brand_name) values(${t},${uuid(brandIds[0])},'Bottle fixture Bashundhara'),(${t},${uuid(brandIds[1])},'Bottle fixture Jamuna'),(${t},${uuid(brandIds[2])},'Bottle fixture small');
 insert into public.items(tenant_id,item_id,brand_id,size_kg,mouth_size,filled_quantity,empty_quantity)values(${t},${uuid(a)},${uuid(brandIds[0])},12,'22mm',0,0),(${t},${uuid(other)},${uuid(brandIds[1])},12,'22mm',0,0),(${t},${uuid(small)},${uuid(brandIds[2])},5,'20mm',0,0);
 insert into public.price_books(tenant_id,item_id,customer_tier,price_type,price,effective_from)values(${t},${uuid(a)},'retail','refill',100,now()-interval '1 day');`);

 for(const item_id of [a,other,small])await checked(c.rpc('adjust_inventory',{p_payload:{item_id,kind:'opening',filled_quantity:100,empty_quantity:10,filled_unit_cost:80,empty_unit_cost:50,reason:'Verified bottle workflow fixture stock'},p_request_id:randomUUID()}));
 const customer=await checked(c.from('customers').insert({tenant_id:owner.tenant,name:'Bottle fixture customer',phone:'01700000000',tier:'retail'}).select().single());
 const cash=(await checked(c.rpc('get_payment_wallets'))).find(w=>w.type==='cash');assert(cash);
 const cart=[{item_id:a,type:'refill',quantity:5,unit_price:100},{item_id:a,type:'empty_return',quantity:5,unit_price:0}];
 const args={p_customer_id:customer.customer_id,p_customer_phone:customer.phone,p_customer_name:null,p_customer_shop_name:null,p_customer_address:null,p_customer_tier:'retail',p_discount_amount:0,p_exchange_fee:0,p_notes:'Disposable bottle workflow acceptance',p_items:cart,p_payments:[]};
 const receipt=(received,qty,extra={})=>({received_item_id:received,quantity:qty,...extra});
 const create=bottles=>checked(c.rpc('create_pos_sale',{...args,p_request_id:randomUUID(),...(bottles===undefined?{}:{p_bottles:bottles})}));
 const state=sid=>checked(c.rpc('get_sale_bottles',{p_sale_id:sid}));
 const collect=(sid,lines,cost=0,request=randomUUID())=>checked(c.rpc('collect_sale_bottles',{p_sale_id:sid,p_payload:{lines,fee:cost},p_request_id:request}));
 const normal=await create();assert.equal((await state(normal.sale_id)).outstanding,0);
 const zero=await create({lines:[],note:'All five empties due from customer'});assert.equal((await state(zero.sale_id)).outstanding,5);
 const partial=await create({lines:[receipt(a,2)],note:'Three bottles remain at customer'});const sid=partial.sale_id;assert.equal((await state(sid)).outstanding,3);
 const initialMismatch=await create({lines:[receipt(a,3)]});assert.equal((await state(initialMismatch.sale_id)).outstanding,2);
 const request=randomUUID();const repeated=await Promise.all(Array.from({length:4},()=>collect(sid,[receipt(other,1,{acknowledged:true})],50,request)));
 assert.equal(new Set(repeated.map(r=>r.receipt_id)).size,1);assert.equal((await state(sid)).outstanding,2);
 const settlement=await checked(c.rpc('get_sale_settlement',{p_sale_id:sid}));assert.equal(settlement.total,550);assert.equal(settlement.original_total,500);assert.equal(settlement.due,550);assert.equal(settlement.paid_at_checkout,0);
 assert.equal(Number(sql(`select balance from public.wallets where tenant_id=${t} and wallet_id=${uuid(cash.wallet_id)}`)),0);
 await denied(c.rpc('collect_sale_bottles',{p_sale_id:sid,p_payload:{lines:[receipt(small,1)],note:'Different dimensions require explicit acceptance'},p_request_id:randomUUID()}));
 await collect(sid,[receipt(small,1,{acknowledged:true})],25);
 const finalRace=await Promise.all([0,1].map(async()=>c.rpc('collect_sale_bottles',{p_sale_id:sid,p_payload:{lines:[receipt(a,1)],note:'Final matching bottle physical return'},p_request_id:randomUUID()})));
 assert.equal(finalRace.filter(r=>!r.error).length,1);assert.equal((await state(sid)).outstanding,0);
 assert.equal((await checked(c.rpc('get_sale_settlement',{p_sale_id:sid}))).due,575);
 const bank=(await checked(c.rpc('get_payment_wallets'))).find(w=>w.type==='dealership');assert(bank);
 const paymentKey=randomUUID(),split=[{wallet_id:cash.wallet_id,amount:25},{wallet_id:bank.wallet_id,amount:25}];
 const payment=await checked(c.rpc('collect_sale_payment',{p_sale_id:sid,p_payments:split,p_request_id:paymentKey}));
 assert.deepEqual(await checked(c.rpc('collect_sale_payment',{p_sale_id:sid,p_payments:split,p_request_id:paymentKey})),payment);
 assert.equal((await checked(c.rpc('get_sale_settlement',{p_sale_id:sid}))).due,525);
 await checked(c.rpc('collect_sale_payment',{p_sale_id:sid,p_payments:[{wallet_id:cash.wallet_id,amount:525}],p_request_id:randomUUID()}));
 assert.equal((await checked(c.rpc('get_sale_settlement',{p_sale_id:sid}))).due,0);
 assert.equal((await checked(c.rpc('get_finance_dues'))).due,1500);
 assert.equal(await checked(c.rpc('get_customer_bottle_balance',{p_customer_id:customer.customer_id})),7);
 assert.equal((await checked(c.rpc('get_customer_directory',{p_customer_id:customer.customer_id}))).entries[0].total_due,1500);
 for(const sort of ['date_desc','date_asc','amount_desc','amount_asc','due_desc','bottles_desc']){
  const full=await checked(c.rpc('get_sales_directory',{p_filters:{sort}})),p0=await checked(c.rpc('get_sales_directory',{p_filters:{sort},p_limit:1})),p1=await checked(c.rpc('get_sales_directory',{p_filters:{sort},p_limit:1,p_offset:1}));
  assert.deepEqual([p0.entries[0].sale_id,p1.entries[0].sale_id],full.entries.slice(0,2).map(s=>s.sale_id));
 }
 assert.equal((await checked(c.rpc('get_sales_directory',{p_filters:{payment:'unpaid',bottles:'partial',search:'customer Bashundhara, impossible'}}))).total,1);
 assert.equal((await checked(foreign.client.rpc('get_sales_directory'))).total,0);await denied(foreign.client.rpc('get_sale_bottles',{p_sale_id:sid}));await denied(foreign.client.rpc('collect_sale_bottles',{p_sale_id:sid,p_payload:{lines:[receipt(a,1)],note:'Foreign attempt'},p_request_id:randomUUID()}));
 await denied(client().rpc('get_sales_directory'));
 await denied(client().rpc('get_sale_receipt',{p_sale_id:sid}));
 await denied(foreign.client.rpc('get_sale_receipt',{p_sale_id:sid}));
 // Checkout redistribution and cumulative acknowledgement remain aggregate-only.
 const mixedCart=[{item_id:a,type:'refill',quantity:5,unit_price:100},{item_id:a,type:'empty_return',quantity:3,unit_price:0},{item_id:other,type:'empty_return',quantity:2,unit_price:0}];
 await denied(c.rpc('create_pos_sale',{...args,p_items:mixedCart,p_request_id:randomUUID(),p_bottles:{lines:[receipt(a,4)]}}));
 const mixed=await checked(c.rpc('create_pos_sale',{...args,p_items:mixedCart,p_request_id:randomUUID(),p_bottles:{lines:[receipt(a,4,{acknowledged:true})]}}));
 await denied(c.rpc('collect_sale_bottles',{p_sale_id:mixed.sale_id,p_payload:{lines:[receipt(a,1)]},p_request_id:randomUUID()}));
 await collect(mixed.sale_id,[receipt(a,1,{acknowledged:true})]);
 const mixedState=await state(mixed.sale_id);assert.equal(mixedState.outstanding,0);assert.equal(mixedState.received,5);assert.equal(mixedState.obligations.find(o=>o.item_id===other).received,0);
 const costs=await checked(c.rpc('get_wallet_ledger',{p_filters:{type:'sale_bottle_expense'}}));assert.equal(costs.total,0);assert.equal(costs.paid_out,0);
 const currentReceipt=await checked(c.rpc('get_sale_receipt',{p_sale_id:sid}));assert.equal(currentReceipt.settlement.additional_charges,75);assert.equal(currentReceipt.settlement.paid,575);assert.equal(currentReceipt.bottles.received,5);
 const over=await create({lines:[receipt(a,7,{acknowledged:true})]});assert.equal((await state(over.sale_id)).received,7);assert.equal((await state(over.sale_id)).outstanding,0);
 await denied(c.rpc('create_pos_sale',{...args,p_request_id:randomUUID(),p_bottles:{lines:[receipt(small,6,{acknowledged:true})]}}));
 const alternate=await create({lines:[]});await collect(alternate.sale_id,[receipt(small,6,{acknowledged:true})]);assert.equal((await state(alternate.sale_id)).received,6);assert.equal((await state(alternate.sale_id)).outstanding,0);
 assert.equal(sql(`select count(*) from public.sale_bottle_receipt_lines where tenant_id=${t} and quantity<=0`),'0');
 // Capability independence: bottle-only staff can collect, cannot charge or receive money.
 sql(`delete from public.role_permissions where tenant_id=${t} and permission_id not in ('sales:view','sales:collect_bottles');`);
 await collect(zero.sale_id,[receipt(a,1)]);
 await denied(c.rpc('collect_sale_bottles',{p_sale_id:zero.sale_id,p_payload:{lines:[receipt(a,1)],fee:1},p_request_id:randomUUID()}));
 await denied(c.rpc('collect_sale_bottles',{p_sale_id:zero.sale_id,p_payload:{lines:[receipt(a,1)],expense:1,expense_wallet_id:cash.wallet_id},p_request_id:randomUUID()}));
 await denied(c.rpc('collect_sale_payment',{p_sale_id:zero.sale_id,p_payments:[{wallet_id:cash.wallet_id,amount:1}],p_request_id:randomUUID()}));assert.deepEqual(await checked(c.from('wallets').select('*')),[]);
 sql(`delete from public.role_permissions where tenant_id=${t} and permission_id='sales:collect_bottles';`);
 await denied(c.rpc('collect_sale_bottles',{p_sale_id:zero.sale_id,p_payload:{lines:[receipt(a,1)],note:'View access cannot collect'},p_request_id:randomUUID()}));
 sql(`insert into public.role_permissions(tenant_id,role_id,permission_id) select r.tenant_id,r.role_id,p.permission_id from public.roles r cross join public.permissions p where r.tenant_id=${t} on conflict do nothing;`);
 assert.equal(sql(`select count(*) from public.wallets w where tenant_id=${t} and balance<>opening_balance+coalesce((select sum(amount) from public.wallet_transactions x where x.tenant_id=w.tenant_id and x.wallet_id=w.wallet_id),0)`),'0');
 console.log('PASS: real receipts, cross-brand/size and overcollections, customer costs and split/partial payments, retries, contention, independent balances, paging/sorting/search, and tenant/capability denial');
 if(process.argv.includes('--browser')){
  const {chromium}=await import('playwright');browser=await chromium.launch({channel:'chrome',headless:true});
  const context=await browser.newContext({viewport:{width:1440,height:1000}});await context.addInitScript(s=>localStorage.setItem('sb-api.lpg.144.79.249.4.sslip.io-auth-token',JSON.stringify(s)),owner.session);
  const page=await context.newPage();const errors=[];page.on('pageerror',e=>errors.push(e.message));
  let automaticPrints=0;
  await page.exposeFunction('__automaticPrintAttempt',()=>{automaticPrints++;});
  await context.addInitScript(()=>{window.print=()=>{window.top.__automaticPrintAttempt();throw Error('Unexpected automatic print');};});
  await page.route('http://127.0.0.1:17891/print',route=>{automaticPrints++;return route.abort('blockedbyclient');});
  await page.goto('https://floral-dew-443b.khandakarsifat.workers.dev/?bottle-acceptance=1#/sales');await page.locator('.sale-card').first().waitFor();
  for(const width of [320,390,768,1440]){await page.setViewportSize({width,height:950});assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),`Page overflow ${width}`);mkdirSync('.temp/bottles-live',{recursive:true});await page.screenshot({path:`.temp/bottles-live/sales-${width}.png`,fullPage:true});}
  await page.locator(`[data-sale-id="${zero.sale_id}"]`).click();const detail=page.getByRole('dialog',{name:/Transaction #/});
  const inspectPrint=async(expectedLine)=>{
   assert.equal(await detail.getByLabel('Receipt printer',{exact:true}).count(),0);
   await detail.getByRole('button',{name:'Print receipt',exact:true}).click();
   const print=page.getByRole('dialog',{name:'Print receipt',exact:true});await print.getByLabel('80mm receipt preview').waitFor();
   for(const width of ['58','80']){
    await print.getByLabel('Browser receipt width',{exact:true}).selectOption(width);
    const preview=print.getByLabel(`${width}mm receipt preview`);await preview.waitFor();
    const content=await preview.innerText();assert(!/Free|BOTTLE SETTLEMENT|Collected later:/.test(content));
    if(expectedLine)assert(content.includes(expectedLine),'Receipt did not reflect current received quantities');
   }
   assert.equal(await print.getByRole('heading',{name:/^(Payments|Bottle settlement|Transaction history)$/}).count(),0);
   await page.setViewportSize({width:320,height:900});assert(await print.locator('.modal-body').evaluate(e=>e.scrollWidth<=e.clientWidth));
   await page.screenshot({path:'.temp/bottles-live/receipt-preview-320.png'});
   await print.getByRole('button',{name:'Close',exact:true}).click();assert(await detail.isVisible());assert.equal(automaticPrints,0);
  };
  await inspectPrint('Expected 5 | Received 1');
  await detail.getByRole('button',{name:'Collect bottles',exact:true}).click();
  const dialog=page.getByRole('dialog',{name:'Collect bottles',exact:true});await dialog.getByLabel('Received quantity for Bottle fixture Jamuna 12kg 22mm',{exact:true}).fill('1');await dialog.getByRole('checkbox',{name:/I accept/}).check();await dialog.getByLabel('Additional Settlement Cost (Tk, optional)',{exact:true}).fill('10');assert.equal(await dialog.getByLabel('Expense wallet',{exact:true}).count(),0);
  await dialog.getByRole('button',{name:'Record bottle collection',exact:true}).click();await dialog.waitFor({state:'hidden'});assert(await detail.isVisible());await detail.locator('.bottle-summary strong').nth(2).filter({hasText:'3'}).waitFor();await detail.getByText('Unexpected product',{exact:true}).waitFor();
  const after=await checked(c.rpc('get_sale_settlement',{p_sale_id:zero.sale_id}));assert.equal(after.due,510);
  await inspectPrint('Expected 0 | Received 1');
  await detail.getByRole('button',{name:'Collect payment',exact:true}).click();const money=page.getByRole('dialog',{name:/Collect payment ·/});await money.getByRole('button',{name:/Pay remaining/}).click();await money.getByRole('button',{name:'Record payment',exact:true}).click();await money.waitFor({state:'hidden'});assert(await detail.isVisible());assert.equal((await state(zero.sale_id)).outstanding,3);
  await page.setViewportSize({width:320,height:900});assert(await detail.evaluate(e=>e.scrollWidth<=e.clientWidth));await page.screenshot({path:'.temp/bottles-live/details-320.png'});
  await detail.getByRole('button',{name:'Back to Sales',exact:true}).click();
  await page.goto('https://floral-dew-443b.khandakarsifat.workers.dev/?bottle-acceptance=1#/');
  await page.getByText('Bottle fixture customer',{exact:true}).first().click();await detail.getByRole('heading',{name:'Payments',exact:true}).waitFor();await inspectPrint();
  await detail.getByRole('button',{name:'Close',exact:true}).click();
  await page.goto('https://floral-dew-443b.khandakarsifat.workers.dev/?aggregate-final=1#/sales');
  await page.locator(`[data-sale-id="${mixed.sale_id}"]`).click();
  assert(await detail.getByRole('button',{name:'Collect bottles',exact:true}).isDisabled());
  const comparison=detail.getByRole('region',{name:'Received bottles',exact:true});
  await comparison.getByRole('listitem').filter({hasText:'Bottle fixture Bashundhara'}).locator('b').filter({hasText:'5'}).waitFor();
  await detail.getByText('Bottle settled.',{exact:false}).waitFor();
  await page.setViewportSize({width:1440,height:1000});await page.screenshot({path:'.temp/bottles-live/aggregate-settled-desktop.png'});
  await page.setViewportSize({width:390,height:900});await page.screenshot({path:'.temp/bottles-live/aggregate-settled-phone.png'});
  await detail.getByRole('button',{name:'Back to Sales',exact:true}).click();
  await page.goto('https://floral-dew-443b.khandakarsifat.workers.dev/?aggregate-pos=1#/pos');
  await page.getByRole('button',{name:'Refill for Bottle fixture Bashundhara 12kg',exact:true}).click();
  await page.getByRole('button',{name:'Return Empty for Bottle fixture Bashundhara 12kg',exact:true}).click();
  await page.getByPlaceholder('Phone, name, shop, address...').fill(customer.phone);await page.getByText(customer.name,{exact:true}).click();
  await page.getByRole('button',{name:'Complete Checkout',exact:true}).click();
  const checkout=page.getByRole('dialog',{name:'Confirm Sale',exact:true});
  assert.equal(await checkout.getByRole('button',{name:/Received bottles/}).getAttribute('aria-expanded'),'false');
  await checkout.getByRole('button',{name:/Received bottles/}).click();
  assert.equal(await checkout.getByText('Other received products',{exact:true}).count(),0);
  assert.equal(await checkout.getByLabel('Received quantity 1',{exact:true}).inputValue(),'1');
  await checkout.getByRole('button',{name:/Decrease Bottle fixture Bashundhara/}).click();
  assert(await checkout.getByRole('button',{name:'Confirm',exact:true}).isEnabled());
  await page.screenshot({path:'.temp/bottles-live/checkout-zero-phone.png'});
  const savedResponse=page.waitForResponse(r=>r.url().endsWith('/create_pos_sale')&&r.request().method()==='POST');
  await checkout.getByRole('button',{name:'Confirm',exact:true}).click();
  const saved=await (await savedResponse).json();assert(saved.sale_id);await checkout.waitFor({state:'hidden'});
  const savedState=await state(saved.sale_id);assert.equal(savedState.expected,1);assert.equal(savedState.received,0);assert.equal(savedState.outstanding,1);
  assert.equal(automaticPrints,0);
  console.log('PASS: published POS defaults, quantity steppers, zero receipt without note; aggregate-settled mismatched products disable further collection');
  console.log('PASS: published Dashboard/Sales share normal sale details; receipt-only preview preserves parent, fits 320px and dispatches no automatic printing');
  assert.deepEqual(errors,[]);await context.close();console.log('PASS: published browser 320/390/768/1440px, cross-brand customer settlement cost, current reprint, independent payment, retained refreshed details');
 }
} finally {
 if(browser)await browser.close();
 if(tenants.length){const ids=tenants.map(uuid).join(',');const tables=sql("select c.table_name from information_schema.columns c join information_schema.tables t using(table_catalog,table_schema,table_name) where c.table_schema='public' and c.column_name='tenant_id' and t.table_type='BASE TABLE' order by c.table_name;").split('\n');assert(tables.every(t=>/^[a-z_]+$/.test(t)));
  sql(`begin;do $$begin if exists(select 1 from public.tenants where tenant_id in (${ids}) and business_name not like 'Bottle API fixture %') then raise exception 'Not a bottle fixture';end if;end$$;set local session_replication_role=replica;delete from app_private.accounting_source_state where tenant_id in (${ids});${tables.map(t=>`delete from public.${t} where tenant_id in (${ids});`).join('\n')}commit;`);
 }
 if(users.length)sql(`delete from auth.users where id in (${users.map(uuid).join(',')});`);
 for(const c of clients)await c.auth.signOut();
 assert.equal(sql(preservation),before,'Existing business data changed');console.log('PASS: fixture cleanup and original business-data fingerprints; burner retained');
}
