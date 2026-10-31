// Real Auth/API and published UI acceptance on explicitly created disposable businesses.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFileSync, mkdirSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { execFileSync } from 'node:child_process';
import { createClient } from '@supabase/supabase-js';
import { chromium } from 'playwright';
assert(process.argv.includes('--vps'), 'Explicit --vps is required');
const frontend = parseEnv(readFileSync('deploy/.env.frontend', 'utf8'));
const backend = parseEnv(readFileSync('deploy/.env.backend', 'utf8'));
const secret = {
  ...parseEnv(readFileSync('.env.live-test', 'utf8')),
  ...process.env,
};
const api = 'https://api.lpg.144.79.249.4.sslip.io';
const worker = 'https://floral-dew-443b.khandakarsifat.workers.dev';
assert.equal(frontend.VITE_SUPABASE_URL, api);
assert.equal(backend.VPS_HOST, '144.79.249.4');
assert.equal(backend.VPS_PROJECT_DIR, '/opt/lpg');
assert.equal(secret.LPG_TEST_EMAIL, 'sifatsiam244@gmail.com');
const ssh = [
  ...(backend.VPS_SSH_KEY ? ['-i', backend.VPS_SSH_KEY] : []),
  '-p',
  backend.VPS_PORT,
  '-o',
  'BatchMode=yes',
  '-o',
  'StrictHostKeyChecking=yes',
  `${backend.VPS_USER}@${backend.VPS_HOST}`,
];
const sql = (input) =>
  execFileSync(
    'ssh',
    [
      ...ssh,
      'sudo -n docker compose --project-directory /opt/lpg --env-file /opt/lpg/.env -p lpg -f /opt/lpg/compose.yml -f /opt/lpg/compose.vps.yml exec -T db psql -X -U supabase_admin -d postgres -qAt -v ON_ERROR_STOP=1',
    ],
    { input, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 },
  ).trim();
const uuid = (v) => {
  assert.match(v, /^[a-f0-9-]{36}$/i);
  return `'${v}'::uuid`;
};
const checked = async (request) => {
  const { data, error } = await request;
  if (error) throw Error(`${error.code}: ${error.message}`);
  return data;
};
const tables=sql("select c.table_name from information_schema.columns c join information_schema.tables t using(table_catalog,table_schema,table_name) where c.table_schema='public' and c.column_name='tenant_id' and t.table_type='BASE TABLE' order by c.table_name;").split('\n');
assert(tables.every(t=>/^[a-z_]+$/.test(t)));
const preservation =
  'select jsonb_build_array(' +
  tables
    .map(
      (t) =>
        `(select md5(coalesce(jsonb_agg(to_jsonb(r) order by to_jsonb(r)::text)::text,'')) from ${t === 'attendance_devices' ? '(select tenant_id,device_id,serial,name,enabled,approved_at,removed_at,created_at from public.attendance_devices)' : 'public.' + t} r)`,
    )
    .join(',') +
  ');';
const before = sql(preservation);
const clients = [],
  users = [],
  tenants = [];
const fixtureAccounts = [];
let browser;const browserErrors=[];
const client = () => {
  const c = createClient(api, frontend.VITE_SUPABASE_ANON_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  clients.push(c);
  return c;
};
async function account(label) {
  const c = client();
  const auth = await checked(
    c.auth.signUp({
      email: `accounting-${randomUUID()}@example.invalid`,
      password: randomUUID() + 'Aa1!',
    }),
  );
  assert(auth.user && auth.session);
  users.push(auth.user.id);
  const b = await checked(
    c.rpc('setup_business', {
      p_business_name: 'Unified accounting API fixture ' + label + ' ' + randomUUID(),
      p_owner_name: 'Accounting acceptance operator',
    }),
  );
  tenants.push(b.tenant_id);
  fixtureAccounts.push({c,tenant:b.tenant_id});
  return { c, user: auth.user, session: auth.session, tenant: b.tenant_id };
}
try {
  // Inspect trusted membership before authenticating the retained burner.
  const trusted=JSON.parse(sql("select jsonb_build_object('tenant',p.tenant_id,'active',p.is_active,'business_active',t.status='active','owner',exists(select 1 from public.user_roles ur join public.roles r using(tenant_id,role_id) where ur.user_id=p.user_id and ur.tenant_id=p.tenant_id and r.name='OWNER')) from auth.users u join public.user_profiles p on p.user_id=u.id join public.tenants t using(tenant_id) where u.email='sifatsiam244@gmail.com';"));
  assert(trusted.active&&trusted.business_active&&trusted.owner);
  const burner=client();const auth=await checked(burner.auth.signInWithPassword({email:secret.LPG_TEST_EMAIL,password:secret.LPG_TEST_PASSWORD}));
  const membership=await checked(burner.from('user_profiles').select('tenant_id,is_active').eq('user_id',auth.user.id).single());assert(membership.is_active&&membership.tenant_id===trusted.tenant);
  const burnerToday=new Intl.DateTimeFormat('sv-SE',{timeZone:'Asia/Dhaka'}).format(new Date());
  const previousDay=new Date(`${burnerToday}T00:00:00Z`);previousDay.setUTCDate(previousDay.getUTCDate()-1);
  const existingReport=await checked(burner.rpc('get_finance_analysis',{p_filters:{business_id:trusted.tenant,from:burnerToday,to:burnerToday,grain:'day'}}));
  assert(existingReport.complete&&existingReport.estimated);assert.equal(existingReport.totals.profit,existingReport.totals.position_profit);
  const beforeCoverage=await checked(burner.rpc('get_finance_analysis',{p_filters:{business_id:trusted.tenant,from:previousDay.toISOString().slice(0,10),to:burnerToday,grain:'day'}}));
  assert.equal(beforeCoverage.complete,true);assert.equal(beforeCoverage.totals.profit,beforeCoverage.totals.position_profit);
  console.log('PASS: active VPS / Worker target, burner trusted membership, reconstructed historical coverage and period reconciliation');
  const owner=await account('owner'),foreign=await account('foreign');const c=owner.c;
  const rpc=(name,args={})=>checked(c.rpc(name,args)).catch(e=>{throw Error(`${name}: ${e.message}`);});
  const today=new Intl.DateTimeFormat('sv-SE',{timeZone:'Asia/Dhaka'}).format(new Date());
  const wallets=await rpc('get_payment_wallets');const cash=wallets.find(w=>w.type==='cash').wallet_id,bank=wallets.find(w=>w.type==='dealership').wallet_id;
  const operation=p=>rpc('accounting_operation',{p_payload:{date:today,...p},p_request_id:randomUUID()});
  await operation({action:'opening_cash',wallet_id:cash,amount:10000,description:'Verified fixture opening cash'});
  const type=(await rpc('get_stove_product_types')).find(t=>t.name==='Single Stove');assert(type);
  const product=(await rpc('save_stove_product',{p_payload:{name:'Unified API stove',type_id:type.type_id},p_request_id:randomUUID()})).item_id;
  const picture=readFileSync('public/icons/app-192.png');const imagePath=`${owner.tenant}/${randomUUID()}.png`;
  await checked(c.storage.from('product-images').upload(imagePath,picture,{contentType:'image/png',upsert:false}));
  const signed=await checked(c.storage.from('product-images').createSignedUrl(imagePath,60));assert.equal((await fetch(signed.signedUrl)).status,200);
  const publicUrl=c.storage.from('product-images').getPublicUrl(imagePath).data.publicUrl;assert.notEqual((await fetch(publicUrl)).status,200,'Private images must not have anonymous public access');
  assert((await foreign.c.storage.from('product-images').download(imagePath)).error,'Other tenant downloaded image');
  assert((await foreign.c.storage.from('product-images').createSignedUrl(imagePath,60)).error,'Other tenant signed image');
  assert((await foreign.c.storage.from('product-images').upload(`${owner.tenant}/${randomUUID()}.png`,picture,{contentType:'image/png'})).error,'Other tenant uploaded into owner folder');
  assert((await c.storage.from('product-images').upload(`${owner.tenant}/${randomUUID()}.svg`,Buffer.from('<svg/>'),{contentType:'image/svg+xml'})).error,'SVG upload accepted');
  assert((await c.storage.from('product-images').upload(`${owner.tenant}/${randomUUID()}.png`,Buffer.alloc(1048577),{contentType:'image/png'})).error,'Oversized upload accepted');
  await rpc('set_product_image',{p_item_id:product,p_image_path:imagePath});
  await c.storage.from('product-images').remove([imagePath]);assert(!(await c.storage.from('product-images').download(imagePath)).error,'Referenced image was deleted');
  const foreignAttach=await foreign.c.rpc('set_product_image',{p_item_id:product,p_image_path:imagePath});assert(foreignAttach.error);
  console.log('PASS: private image Auth/Storage upload/read, anonymous and foreign-tenant denial, raster/size restrictions and referenced-image deletion protection');
  const adjustment={item_id:product,kind:'opening',filled_quantity:10,empty_quantity:0,filled_unit_cost:100,reason:'Verified fixture opening stock'};const adjustmentKey=randomUUID();
  const adjusted=await rpc('adjust_inventory',{p_payload:adjustment,p_request_id:adjustmentKey});assert.deepEqual(await rpc('adjust_inventory',{p_payload:adjustment,p_request_id:adjustmentKey}),adjusted);
  await rpc('save_product_prices',{p_item_id:product,p_customer_tier:'retail',p_prices:{refill:{price:0,mrp:null},package:{price:200,mrp:null}},p_expected:{refill:null,package:null}});
  const purchase=(await rpc('create_purchase',{p_payload:{business_category:'stove',supplier_name:'Unified API supplier',request_id:randomUUID(),items:[{item_id:product,type:'package',quantity:10,unit_price:300}]}})).purchase_id;
  await rpc('record_purchase_payment',{p_purchase_id:purchase,p_payments:[{wallet_id:cash,amount:500},{wallet_id:bank,amount:200}],p_request_id:randomUUID()});
  await rpc('receive_purchase',{p_purchase_id:purchase,p_revision:2});
  assert.equal((await rpc('get_inventory_cost_history',{p_item_id:product})).pool.filled_value,4000);
  const sale=(await rpc('create_pos_sale',{p_customer_phone:'01700000591',p_customer_name:'Unified API buyer',p_customer_shop_name:null,p_customer_address:null,p_customer_tier:'retail',p_discount_amount:0,p_exchange_fee:0,p_notes:'Disposable acceptance sale',p_items:[{item_id:product,type:'package',quantity:2,unit_price:200}],p_customer_id:null,p_request_id:randomUUID(),p_payments:[{wallet_id:cash,amount:150}],p_bottles:null})).sale_id;
  await rpc('collect_sale_payment',{p_sale_id:sale,p_payments:[{wallet_id:bank,amount:250}],p_request_id:randomUUID()});
  const receipt=await rpc('get_sale_receipt',{p_sale_id:sale});assert.equal(receipt.sale.sale_items[0].items.product_name,'Unified API stove');assert.equal(receipt.bottles.expected,0);
  await rpc('adjust_inventory',{p_payload:{item_id:product,kind:'damaged',filled_quantity:-1,empty_quantity:0,reason:'Fixture inventory loss'},p_request_id:randomUUID()});
  const loan=(await operation({action:'loan_create',lender:'Unified API lender',wallet_id:cash,amount:1000,description:'Recorded fixture loan'})).id;
  await operation({action:'loan_repay',loan_id:loan,wallet_id:bank,amount:200,description:'Partial fixture principal repayment'});
  const driver=(await rpc('save_employee',{p_payload:{name:'Unified API driver',employee_type_name:'Driver',business_unit:'truck_business',phones:[{phone:'01700000592',is_primary:true}],terms:{monthly_salary:0,effective_from:today,is_active:true}},p_request_id:randomUUID()})).employee_id;
  const vehicle=(await rpc('save_vehicle',{p_payload:{name:'Unified API vehicle',serial_no:'UNIFIED-'+randomUUID().slice(0,6),capacity:100,driver_employee_id:driver,book_value:50000,funding:'opening'},p_request_id:randomUUID()})).vehicle_id;
  await rpc('set_vehicle_availability',{p_vehicle_id:vehicle,p_available:false,p_reason:'Temporary fixture service',p_request_id:randomUUID()});
  const denied=await c.rpc('create_custom_transit',{p_payload:{vehicle_id:vehicle,fee:500,client_name:'Blocked fixture',destination:'Dhaka'},p_request_id:randomUUID()});assert(denied.error&&denied.error.message.includes('out of service'));
  await rpc('set_vehicle_availability',{p_vehicle_id:vehicle,p_available:true,p_reason:'Service complete',p_request_id:randomUUID()});
  const transit=(await rpc('create_custom_transit',{p_payload:{vehicle_id:vehicle,fee:500,client_name:'Unified API client',destination:'Dhaka'},p_request_id:randomUUID()})).transit_id;
  await rpc('save_transit_costs',{p_transit_id:transit,p_costs:{driver_cost:50,helper_cost:0,oil_cost:20,others_cost:0,additional_costs:[]},p_revision:1});
  await rpc('record_operating_payment',{p_payload:{transit_id:transit,kind:'client_receipt',payment_date:today,payments:[{wallet_id:cash,amount:300}]},p_request_id:randomUUID()});
  await rpc('record_operating_payment',{p_payload:{transit_id:transit,kind:'expense',payment_date:today,payments:[{wallet_id:cash,amount:20}]},p_request_id:randomUUID()});
  await rpc('employee_payment_operation',{p_payload:{action:'pay',items:[{employee_id:driver,kind:'trips',trip_count:1,transit_id:transit,trip_role:'driver',payment_date:today,payments:[{wallet_id:cash,amount:50}]}]},p_request_id:randomUUID()});
  await rpc('transition_transit',{p_transit_id:transit,p_action:'return',p_revision:(await rpc('get_transit',{p_transit_id:transit})).revision});
  const asset=(await rpc('get_vehicle',{p_vehicle_id:vehicle})).asset.asset_id;
  await operation({action:'asset_depreciate',asset_id:asset,amount:1000,description:'Vehicle depreciation'});
  await operation({action:'asset_dispose',asset_id:asset,method:'sold',proceeds:49000,expense:100,wallet_id:cash,description:'Vehicle disposal with remaining book value'});
  const commission=(await operation({action:'commission_earn',supplier_name:'Unified API supplier',business_category:'stove',amount:200,description:'Earned supplier credit'})).id;
  await operation({action:'commission_apply',commission_id:commission,purchase_id:purchase,amount:100,description:'Apply previously earned credit'});
  await rpc('reverse_sale',{p_sale_id:sale,p_reason:'Returned fixture products',p_confirmation:'CANCEL',p_request_id:randomUUID()});
  for(const [wallet,amount] of [[cash,150],[bank,250]])await rpc('refund_sale',{p_sale_id:sale,p_payments:[{wallet_id:wallet,amount}],p_request_id:randomUUID()});
  const p=(await rpc('get_purchases_by_ids',{p_ids:[purchase]}))[0];await rpc('initiate_purchase_cancellation',{p_purchase_id:purchase,p_revision:p.revision,p_confirmation:'CANCEL',p_request_id:randomUUID()});
  const settlement=await rpc('get_purchase_settlement',{p_purchase_id:purchase});assert.equal(settlement.refund_due,700);
  await rpc('refund_purchase',{p_purchase_id:purchase,p_obligation_id:settlement.obligations[0].obligation_id,p_payments:[{wallet_id:cash,amount:700}],p_request_id:randomUUID()});
  const filters={from:today,to:today,business_id:owner.tenant,grain:'day',category:'all'};
  let report=await rpc('get_finance_analysis',{p_filters:filters});assert.equal(report.totals.profit,-670);assert.equal(report.totals.profit,report.totals.position_profit);
  const foreignRead=await foreign.c.rpc('get_finance_analysis',{p_filters:filters});assert(foreignRead.error&&foreignRead.error.code==='42501');
  const foreignWrite=await foreign.c.rpc('adjust_inventory',{p_payload:adjustment,p_request_id:randomUUID()});assert(foreignWrite.error);
  console.log('PASS: real Auth/PostgREST weighted stock, split/partial purchase and POS payments, loss, loans, logistics, depreciation/disposal, commissions, cancellations/refunds and tenant denial');
  if(process.argv.includes('--browser')) {
    mkdirSync('.temp/unified-accounting',{recursive:true});browser=await chromium.launch({channel:'chrome',headless:true});const context=await browser.newContext({viewport:{width:1440,height:1050},acceptDownloads:true});
    await context.addInitScript(({session})=>localStorage.setItem('sb-api.lpg.144.79.249.4.sslip.io-auth-token',JSON.stringify(session)),{session:owner.session});
    const page=await context.newPage();page.setDefaultTimeout(20000);const errors=browserErrors;page.on('pageerror',e=>errors.push(e.message));
    for(const width of [1440,768,390,320]){await page.setViewportSize({width,height:1050});await page.goto(worker+'/#/finance',{waitUntil:'domcontentloaded',timeout:45000});await page.getByRole('heading',{name:'Revenue, expenses & profit',exact:true}).waitFor();assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),`Finance overflow at ${width}`);await page.screenshot({path:`.temp/unified-accounting/live-finance-${width}.png`,fullPage:true});}
    await page.setViewportSize({width:1440,height:1050});await page.getByRole('button',{name:'Assets & liabilities',exact:true}).click();await page.getByRole('heading',{name:'Closing position',exact:true}).waitFor();
    await page.getByText('Advanced journal audit',{exact:true}).click();await page.locator('.journal-entry').first().locator('summary').click();await page.getByRole('columnheader',{name:'Debit',exact:true}).waitFor();
    const download=page.waitForEvent('download');await page.getByRole('button',{name:'Export report PDF',exact:true}).click();await(await download).saveAs('.temp/unified-accounting/live-report.pdf');assert(readFileSync('.temp/unified-accounting/live-report.pdf').subarray(0,5).toString()==='%PDF-');
    await page.getByRole('tab',{name:'Loans, assets & capital',exact:true}).click();await page.getByRole('heading',{name:'Unified API lender',exact:true}).waitFor();await page.getByRole('button',{name:'Repay principal',exact:true}).click();await page.getByRole('dialog').getByLabel('Amount (Tk)').waitFor();await page.getByRole('dialog').getByRole('button',{name:'Cancel',exact:true}).click();
    await page.goto(worker+'/#/inventory',{waitUntil:'domcontentloaded',timeout:45000});await page.getByRole('button',{name:'Stove Business',exact:true}).click();await page.getByRole('button',{name:'Add Item',exact:true}).click();let dialog=page.getByRole('dialog').last();await dialog.getByLabel('Product name',{exact:true}).fill('Unified browser stove');await dialog.getByLabel('Product type',{exact:true}).selectOption(type.type_id);
    await dialog.getByLabel('Upload product photo',{exact:true}).setInputFiles('public/icons/app-192.png');
    await dialog.getByRole('button',{name:'Save product',exact:true}).click();await dialog.getByRole('heading',{name:'Selling prices',exact:true}).waitFor();
    await dialog.locator('.product-photo-preview img').waitFor();assert(await dialog.locator('.product-photo-preview img').evaluate(async img=>{await img.decode();return img.naturalWidth>0;}));
    await page.screenshot({path:'.temp/unified-accounting/live-product-photo-desktop.png'});await page.setViewportSize({width:390,height:844});await page.screenshot({path:'.temp/unified-accounting/live-product-photo-phone.png'});await page.setViewportSize({width:1440,height:1050});
    const imageBefore=(await checked(c.from('items').select('image_url').eq('product_name','Unified browser stove').single())).image_url;
    await dialog.getByLabel('Upload product photo',{exact:true}).dispatchEvent('cancel');assert(await dialog.isVisible(),'Cancelling the file chooser closed its product dialog');
    await dialog.getByLabel('Upload product photo',{exact:true}).setInputFiles('public/icons/app-192.png');await dialog.getByRole('button',{name:'Save product',exact:true}).click();await page.waitForFunction(()=>!Array.from(document.querySelectorAll('dialog button')).some(b=>b.textContent.includes('Saving')));
    const imageAfter=(await checked(c.from('items').select('image_url').eq('product_name','Unified browser stove').single())).image_url;assert(imageAfter&&imageBefore!==imageAfter);assert((await c.storage.from('product-images').download(imageBefore)).error,'Replacement left old image behind');
    await dialog.getByRole('button',{name:'Remove',exact:true}).click();await dialog.getByRole('button',{name:'Save product',exact:true}).click();await dialog.getByRole('button',{name:'Save product',exact:true}).waitFor();await dialog.getByRole('button',{name:'Add product photo',exact:true}).waitFor();assert.equal((await checked(c.from('items').select('image_url').eq('product_name','Unified browser stove').single())).image_url,null);assert((await c.storage.from('product-images').download(imageAfter)).error,'Removed image remained in Storage');
    await dialog.getByLabel('Upload product photo',{exact:true}).setInputFiles('public/icons/app-192.png');await dialog.getByRole('button',{name:'Save product',exact:true}).click();await dialog.locator('.product-photo-preview img').waitFor();
    await dialog.getByLabel('Selling price (Tk)',{exact:true}).fill('500');await dialog.getByRole('button',{name:'Save selling price',exact:true}).click();await dialog.getByText('Current selling price: Tk 500',{exact:true}).waitFor();await dialog.getByRole('button',{name:'Close',exact:true}).click();
    const uiProduct=await checked(c.from('items').select('item_id').eq('product_name','Unified browser stove').single());
    await page.getByRole('button',{name:'Adjustment',exact:true}).click();dialog=page.getByRole('dialog').last();await dialog.getByLabel('Product',{exact:true}).selectOption(uiProduct.item_id);await dialog.getByLabel('Quantity',{exact:true}).fill('4');await dialog.getByLabel('Unit cost (Tk)',{exact:true}).fill('25.50');await dialog.getByLabel('Description',{exact:true}).fill('Browser valued opening stock');await dialog.getByRole('button',{name:'Review adjustment',exact:true}).click();await page.getByRole('dialog').last().getByRole('button',{name:'Record adjustment',exact:true}).click();await page.waitForFunction(()=>document.querySelectorAll('dialog[open]').length===0);
    await page.goto(worker+'/#/pos',{waitUntil:'domcontentloaded',timeout:45000});await page.getByRole('button',{name:'Stove Business',exact:true}).click();await page.getByRole('button',{name:/Unified browser stove/}).click();await page.getByPlaceholder('Phone, name, shop, address...').fill('01700000591');await page.getByText('Unified API buyer',{exact:true}).click();await page.getByRole('button',{name:'Complete Checkout',exact:true}).click();dialog=page.getByRole('dialog').last();await dialog.getByText('Unified browser stove',{exact:true}).waitFor();assert.equal(await dialog.getByRole('button',{name:/Received bottles/}).count(),0);await dialog.getByRole('button',{name:'Confirm',exact:true}).click();await page.waitForFunction(()=>document.querySelectorAll('dialog[open]').length===0);
    assert.equal((await rpc('get_inventory_cost_history',{p_item_id:uiProduct.item_id})).pool.filled_quantity,3);
    await page.goto(worker+'/#/purchases',{waitUntil:'domcontentloaded',timeout:45000});await page.getByRole('button',{name:'Stove Business',exact:true}).click();await page.getByRole('button',{name:'New Purchase',exact:true}).click();dialog=page.getByRole('dialog').last();await dialog.getByLabel('Supplier name',{exact:true}).fill('Unified browser supplier');await dialog.getByLabel('Product',{exact:true}).selectOption(uiProduct.item_id);await dialog.getByRole('button',{name:'Add product',exact:true}).click();await dialog.getByLabel('Quantity',{exact:true}).fill('2');await dialog.getByLabel('Unit purchase price (Tk)',{exact:true}).fill('30');await dialog.getByRole('button',{name:'Review purchase',exact:true}).click();await page.getByRole('dialog').last().getByRole('button',{name:'Create purchase',exact:true}).click();await page.waitForFunction(()=>document.querySelectorAll('dialog[open]').length===0);
    await page.getByRole('button',{name:/Unified browser supplier/}).click();dialog=page.getByRole('dialog').last();await dialog.getByRole('button',{name:'Receive shipment',exact:true}).click();await page.getByRole('dialog').last().getByRole('button',{name:'Receive shipment',exact:true}).click();await page.getByRole('dialog').last().getByRole('button',{name:'Close',exact:true}).click();
    assert.equal((await rpc('get_inventory_cost_history',{p_item_id:uiProduct.item_id})).pool.filled_quantity,5);assert.deepEqual(errors,[]);
    const brand=(await rpc('create_lpg_brand',{p_brand_name:'Unified browser LPG',p_description:null})).brand_id;
    const plant=(await rpc('create_gas_plant',{p_plant_name:'Unified browser plant',p_brand_id:brand,p_location:'Dhaka'})).plant_id;
    const truck=(await rpc('save_vehicle',{p_payload:{name:'Unified browser truck',serial_no:'BROWSER-'+randomUUID().slice(0,6),capacity:100,driver_employee_id:driver,book_value:0,funding:'opening'},p_request_id:randomUUID()})).vehicle_id;
    await page.setViewportSize({width:390,height:844});await page.goto(worker+'/?lpg-browser-fixture=1#/inventory',{waitUntil:'networkidle'});await page.getByRole('button',{name:'Add Item',exact:true}).click();dialog=page.getByRole('dialog').last();
    await dialog.getByLabel('Brand *',{exact:true}).selectOption(brand);await dialog.getByLabel('Cylinder Weight (KG) *',{exact:true}).selectOption('12');await dialog.getByLabel('Upload product photo',{exact:true}).setInputFiles('public/icons/app-192.png');await dialog.getByRole('button',{name:'Create Item',exact:true}).click();await dialog.waitFor({state:'hidden'});
    const lpg=await checked(c.from('items').select('item_id,image_url').eq('brand_id',brand).single());assert(lpg.image_url);
    await page.getByRole('button',{name:'Add Item',exact:true}).click();dialog=page.getByRole('dialog').last();await dialog.getByRole('button',{name:'Add product photo',exact:true}).waitFor();assert.equal(await dialog.locator('.product-photo-preview img').count(),0,'A new product inherited the previous photo');await dialog.getByRole('button',{name:'Cancel',exact:true}).click();
    await rpc('adjust_inventory',{p_payload:{item_id:lpg.item_id,kind:'opening',filled_quantity:0,empty_quantity:5,filled_unit_cost:0,empty_unit_cost:50,reason:'Verified LPG browser fixture empties'},p_request_id:randomUUID()});
    await page.goto(worker+'/#/purchases',{waitUntil:'networkidle'});await page.getByRole('button',{name:'New Purchase',exact:true}).click();dialog=page.getByRole('dialog').last();await dialog.getByLabel('Destination plant',{exact:true}).selectOption(plant);await dialog.getByLabel('Vehicle (optional until dispatch)',{exact:true}).selectOption(truck);await dialog.getByRole('button',{name:'Add product',exact:true}).click();await dialog.getByLabel('Product 1',{exact:true}).selectOption(lpg.item_id);await dialog.locator('.purchase-line-product img').evaluate(async img=>{await img.decode();if(!img.naturalWidth)throw Error('Purchase product photo failed to load');});await dialog.getByLabel('Expected refills',{exact:true}).fill('2');await dialog.getByLabel('Unit price (Tk)',{exact:true}).fill('100');await dialog.getByLabel('Transport cost (Tk)',{exact:true}).fill('40');await dialog.getByLabel('Labour cost (Tk)',{exact:true}).fill('10');await page.screenshot({path:'.temp/unified-accounting/live-lpg-purchase-phone.png'});
    await dialog.getByRole('button',{name:'Create purchase',exact:true}).click();await page.getByRole('dialog').last().getByRole('button',{name:'Create purchase',exact:true}).click();await page.waitForFunction(()=>document.querySelectorAll('dialog[open]').length===0);await page.getByRole('button',{name:/Unified browser plant/}).click();dialog=page.getByRole('dialog').last();await dialog.getByRole('button',{name:'Dispatch vehicle',exact:true}).click();await page.getByRole('dialog').last().getByRole('button',{name:'Dispatch vehicle',exact:true}).click();await dialog.getByRole('button',{name:'Receive shipment',exact:true}).click();await page.getByRole('dialog').last().getByRole('button',{name:'Receive shipment',exact:true}).click();await page.getByRole('dialog').last().getByRole('button',{name:'Close',exact:true}).click();
    const pool=(await rpc('get_inventory_cost_history',{p_item_id:lpg.item_id})).pool;assert.equal(pool.filled_quantity,2);assert.equal(pool.empty_quantity,3);assert.equal(pool.filled_value,310);
    const pricingBefore=await rpc('get_finance_analysis',{p_filters:filters});await page.goto(worker+'/#/inventory',{waitUntil:'networkidle'});await page.locator('.inv-tile').filter({hasText:'Unified browser LPG'}).first().click();dialog=page.getByRole('dialog').last();await dialog.locator('.product-heading img').evaluate(async img=>{await img.decode();if(!img.naturalWidth)throw Error('LPG product header photo failed to load');});await dialog.getByRole('button',{name:'Edit approximate price',exact:true}).first().click();let nested=page.getByRole('dialog',{name:'Approximate refill buying price',exact:true});await nested.getByLabel('Approximate price (Tk)',{exact:true}).fill('110');await nested.getByLabel('Reason for change',{exact:true}).fill('Browser operational reference');await nested.getByRole('button',{name:'Save approximate price',exact:true}).click();await nested.waitFor({state:'hidden'});
    await dialog.getByRole('button',{name:'Edit commission',exact:true}).click();nested=page.getByRole('dialog',{name:'Edit commission',exact:true});await nested.getByLabel('Refill commission / unit',{exact:true}).fill('5');await nested.getByRole('button',{name:'Save commission',exact:true}).click();await nested.waitFor({state:'hidden'});assert.deepEqual(await rpc('get_finance_analysis',{p_filters:filters}),pricingBefore);await page.screenshot({path:'.temp/unified-accounting/live-lpg-pricing-phone.png'});
    console.log('PASS: published phone LPG photo creation and fresh form, purchase creation / dispatch / receipt, actual carrying value, manual approximate price and commission changes with financial independence');
    await context.close();console.log('PASS: published responsive Finance / journal / PDF and real browser stove creation, decimal opening valuation, POS checkout and direct purchase receipt');
  }
  report=await rpc('get_finance_analysis',{p_filters:filters});assert.equal(report.totals.profit,report.totals.position_profit);
  const discrepancies=JSON.parse(sql(`select jsonb_build_object('wallets',(select count(*) from public.wallets w where tenant_id=${uuid(owner.tenant)} and balance<>coalesce((select sum(amount) from public.accounting_lines l where l.tenant_id=w.tenant_id and l.account='cash' and l.entity_id=w.wallet_id),0)),'inventory',(select count(*) from public.inventory_costs c join public.items i using(tenant_id,item_id) where c.tenant_id=${uuid(owner.tenant)} and (c.filled_quantity<>i.filled_quantity or c.empty_quantity<>i.empty_quantity or c.filled_value+c.empty_value<>coalesce((select sum(amount) from public.accounting_lines l where l.tenant_id=c.tenant_id and l.entity_id=c.item_id and l.account in ('inventory_lpg','inventory_stove')),0))));`));assert.deepEqual(discrepancies,{wallets:0,inventory:0});
  console.log('PASS: live journal / stock / wallets and period-profit reconciliation after API and browser operations');
} catch(error) {
 if(browser){const p=browser.contexts().flatMap(c=>c.pages()).at(-1);if(p&&!await p.locator('input[type="password"]').count()){await p.screenshot({path:'.temp/unified-accounting/live-failure.png'});console.error('Browser errors:',browserErrors);console.error('UI diagnostics:',await p.locator('dialog[open]').evaluateAll(ds=>ds.map(d=>({title:d.querySelector('h2')?.textContent,buttons:Array.from(d.querySelectorAll('button')).map(b=>({text:b.textContent,disabled:b.disabled})),alerts:Array.from(d.querySelectorAll('[role="alert"]')).map(a=>a.textContent)}))));}}
 console.error(String(error?.stack??error).replaceAll(secret.LPG_TEST_PASSWORD,'[redacted]').replace(/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g,'[redacted JWT]'));process.exitCode=1;
} finally {
  if (browser) await browser.close();
  for(const fixture of fixtureAccounts) {
    const pictured=await checked(fixture.c.from('items').select('item_id,image_url').not('image_url','is',null));
    for(const item of pictured)await checked(fixture.c.rpc('set_product_image',{p_item_id:item.item_id,p_image_path:null}));
    const objects=await checked(fixture.c.storage.from('product-images').list(fixture.tenant,{limit:100}));
    if(objects.length)await checked(fixture.c.storage.from('product-images').remove(objects.map(o=>`${fixture.tenant}/${o.name}`)));
    assert.equal((await checked(fixture.c.storage.from('product-images').list(fixture.tenant,{limit:100}))).length,0,'Fixture image cleanup incomplete');
  }
  if (tenants.length) {
    const ids = tenants.map(uuid).join(',');
    const cleanupTables = sql(
      "select c.table_name from information_schema.columns c join information_schema.tables t using(table_catalog,table_schema,table_name) where c.table_schema='public' and c.column_name='tenant_id' and t.table_type='BASE TABLE' order by c.table_name;",
    ).split('\n');
    assert(cleanupTables.every((t) => /^[a-z_]+$/.test(t)));
    sql(
      `begin;do $$begin if exists(select 1 from public.tenants where tenant_id in (${ids}) and business_name not like 'Unified accounting API fixture %') then raise exception 'Not an accounting fixture';end if;end$$;set local session_replication_role=replica;delete from app_private.accounting_source_state where tenant_id in (${ids});${cleanupTables.map((t) => `delete from public.${t} where tenant_id in (${ids});`).join('\n')}commit;`,
    );
  }
  if (users.length)
    sql(`delete from auth.users where id in (${users.map(uuid).join(',')});`);
  for (const c of clients) await c.auth.signOut({ scope: 'local' });
  assert.equal(
    sql(preservation),
    before,
    'Original business accounting/stock fingerprints changed',
  );
  console.log(
    'PASS: only explicitly created fixtures cleaned; original businesses unchanged and burner retained',
  );
}
