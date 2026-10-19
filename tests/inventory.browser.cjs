// playwright-cli run-code --filename=tests/inventory.browser.cjs on local Vite.
// Isolated Auth/API fixtures. No live database writes or physical print jobs.
async page => {
  await page.unroute('**/rest/v1/**');
  await page.unroute('**/auth/v1/**');
  const origin = new URL(page.url()).origin;
  const tenant = 'ab100000-0000-4000-8000-000000000001';
  const sku = 'ab100000-0000-4000-8000-000000000003';
  const user = { id: 'ab100000-0000-4000-8000-000000000002', aud: 'authenticated', role: 'authenticated', email: 'inventory@example.invalid', app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() };
  const payload = btoa(JSON.stringify({ sub: user.id, exp: Math.floor(Date.now() / 1000) + 86400, aud: 'authenticated', role: 'authenticated' })).replaceAll('=', '').replaceAll('+', '-').replaceAll('/', '_');
  const token = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.' + payload + '.Zml4dHVyZQ';
  await page.context().addInitScript(({ user, token }) => {
    const session = JSON.stringify({ access_token: token, refresh_token: 'fixture-refresh', token_type: 'bearer', expires_in: 86400, expires_at: Math.floor(Date.now() / 1000) + 86400, user });
    for (const host of ['api', '127', 'localhost']) localStorage.setItem(`sb-${host}-auth-token`, session);
  }, { user, token });
  const brandA = 'brand-beximco', brandB = 'brand-omera', brandC = 'brand-bashundhara';
  let brands = [
    {brand_id:brandA,brand_name:'Beximco LPG',is_active:true},
    {brand_id:brandB,brand_name:'Omera',is_active:true},
    {brand_id:brandC,brand_name:'Bashundhara',is_active:true},
    {brand_id:'dormant',brand_name:'Dormant',is_active:false},
  ];
  const items = [{ tenant_id: tenant, item_id: sku, brand_id: brandA, brand: 'Beximco LPG', size_kg: 12, mouth_size: '22mm', filled_quantity: 42, empty_quantity: 18, lpg_brands: { brand_name: 'Beximco LPG' } },
    { tenant_id: tenant, item_id: 'sku-two', brand_id: brandB, brand: 'Omera', size_kg: 12, mouth_size: '20mm', filled_quantity: 3, empty_quantity: 0, lpg_brands: { brand_name: 'Omera' } },
    { tenant_id: tenant, item_id: 'sku-three', brand_id: brandC, brand: 'Bashundhara', size_kg: 25, mouth_size: '22mm', filled_quantity: 0, empty_quantity: 5, lpg_brands: { brand_name: 'Bashundhara' } },
    {tenant_id:tenant,item_id:'sku-small',brand_id:brandA,brand:'Beximco LPG',size_kg:5,mouth_size:'22mm',filled_quantity:20,empty_quantity:7,lpg_brands:{brand_name:'Beximco LPG'}}];
  let version = '2026-10-01T00:00:00Z';
  let prices = [{ item_id: sku, customer_tier: 'retail', price_type: 'refill', price: 1250, mrp: 1500, effective_from: version },
    { item_id: sku, customer_tier: 'retail', price_type: 'package', price: 2500, mrp: 3000, effective_from: version }];
  const start = new Date('2026-10-17T12:00:00Z');
  const weeks = Array.from({ length: 8 }, (_, i) => {
    const from = new Date(start); from.setUTCDate(from.getUTCDate() - i * 7);
    const to = new Date(from); to.setUTCDate(to.getUTCDate() + 6);
    return { start_date: from.toISOString().slice(0, 10), end_date: to.toISOString().slice(0, 10), sold_refill: i === 7 ? 1234 : i === 6 ? 0 : i ? 14 : 7,
      sold_package: i === 6 ? 0 : i ? 3 : 1, empty_return: i === 6 ? 0 : i ? 14 : 7,
      bought_package: i === 6 ? 0 : i ? 8 : 0, bought_refill: i === 7 ? 12345 : i === 6 ? 0 : i ? 20 : 0 };
  });
  let failDetails = false, failSave = false, viewer = false, manager = false, saves = 0;
  let commission = {refill_rate:0,package_rate:0,version:null}, commissionSaves = 0, failCommission = false, failOrder = false;
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.route('**/auth/v1/**', route => route.fulfill({ json: user }));
  await page.route('**/rest/v1/**', async route => {
    const request = route.request();
    const name = new URL(request.url()).pathname.split('/').pop();
    let data = [];
    switch (name) {
      case 'user_profiles': data = [{ tenant_id: tenant, full_name: 'Operator', email: user.email, tenants: { business_name: 'Inventory verification' } }]; break;
      case 'get_my_permissions': data = ['inventory:view', 'pos:sell', 'customers:view', ...(!viewer ? ['inventory:manage','settings:manage'] : [])]; break;
      case 'items': data = items; break;
      case 'list_lpg_brands': data = brands; break;
      case 'set_lpg_brand_order': {
        if(failOrder)return route.fulfill({status:409,json:{message:'Brand order changed. Reload brands before reordering.'}});
        const body=request.postDataJSON();
        if(JSON.stringify(body.p_expected)!==JSON.stringify(brands.map(b=>b.brand_id)))throw Error('Incorrect expected brand order');
        data=null;brands=body.p_brand_ids.map(id=>brands.find(b=>b.brand_id===id));break;
      }
      case 'set_product_commissions': {
        if(viewer||manager)throw Error('Non-owner attempted commission write');
        commissionSaves++;
        if(failCommission)return route.fulfill({status:409,json:{message:'Commission changed. Reload the saved rate before saving.',code:'40001'}});
        const body=request.postDataJSON();
        if(body.p_item_id!==sku||body.p_expected!==commission.version)throw Error('Incorrect expected commission version');
        commission={refill_rate:body.p_refill_rate,package_rate:body.p_package_rate,version:crypto.randomUUID()};data=null;break;
      }
      case 'price_books': data = prices; break;
      case 'wallets': data = []; break;
      case 'customers': data = []; break;
      case 'get_product_inventory':
        if (failDetails) return route.fulfill({ status: 500, json: { message: 'Fixture detail error' } });
        data = { can_manage_prices:!viewer&&!manager, commission, prices, weeks, buying_costs: [
          { type: 'refill', received_at: '2026-10-15T10:00:00Z', bottle_cost: 1100, overhead_per_unit: 20, commission_per_unit:commission.refill_rate, estimated_unit_cost: 1120-commission.refill_rate },
          { type: 'package', received_at: '2026-10-14T10:00:00Z', bottle_cost: 2100, overhead_per_unit: 25, commission_per_unit:commission.package_rate, estimated_unit_cost: 2125-commission.package_rate },
        ] }; break;
      case 'save_product_prices': {
        saves++;
        if (failSave) return route.fulfill({ status: 409, json: { message: 'Prices changed. Reload saved prices before saving.', code: '40001' } });
        const body = request.postDataJSON();
        if (body.p_item_id !== sku || body.p_expected.refill !== version) throw Error('Incorrect fixture product/version: ' + JSON.stringify({ body, version }));
        version = new Date().toISOString();
        prices = Object.entries(body.p_prices).map(([kind, value]) => ({ ...value, price_type: kind, item_id: sku, customer_tier: body.p_customer_tier, effective_from: version }));
        data = null; break;
      }
      default: throw Error('Unexpected fixture endpoint ' + name);
    }
    await route.fulfill({ json: data });
  });
  const check = (ok, label) => { if (!ok) throw Error('FAIL: ' + label); };
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.goto(origin + '/?inventory-fixtures=' + Date.now() + '#/inventory');
  await page.getByRole('button', { name: /Beximco LPG.*12.*Product details/ }).click();
  const modal = page.getByRole('dialog');
  await modal.getByRole('heading', { name: 'Current pricing' }).waitFor();
  check(await modal.locator('.product-week').count() === 8, 'eight weekly entries');
  check(JSON.stringify(await modal.locator('.product-week').first().locator('dd').allTextContents()) === JSON.stringify(['-7', '-1', '+7', '0', '0']), 'signed sale and incoming quantities with neutral zeroes');
  check(JSON.stringify(await modal.locator('.product-week').nth(6).locator('dd').allTextContents()) === JSON.stringify(['0', '0', '0', '0', '0']), 'zero week retains all five fields');
  check(await modal.locator('.product-history-labels').count() === 1, 'shared column labels appear once');
  check(JSON.stringify(await modal.locator('.product-week').first().locator('dt').allTextContents()) === JSON.stringify(['Sold refill', 'Sold package', 'Empty return', 'Bought package', 'Bought refill']), 'complete labels retained for screen readers');
  await modal.getByLabel('About weekly history', { exact: true }).click();
  check(await modal.locator('.product-history-info').getAttribute('open') !== null, 'keyboard-accessible history explanation');
  await modal.getByLabel('About weekly history', { exact: true }).click();
  check(await modal.getByText('Tk 1,120.00', { exact: true }).count() === 1, 'buying estimate visible');
  check(await page.locator('.inv-overview-box').count() === 4, 'four compact summary boxes');
  check(await page.locator('.inv-overview-filled').first().innerText() === '65', 'filled total');
  check(await page.locator('.inv-overview-empty').first().innerText() === '30', 'empty total');
  check(await page.locator('.inv-overview-box').nth(1).innerText().then(t => t.includes('1') && t.includes('filled') && t.includes('empty')), 'independent low-stock counts');
  check(await page.locator('.inv-overview-box').nth(2).innerText().then(t => t.includes('1') && t.includes('filled') && t.includes('empty')), 'independent zero-stock counts');
  check(await page.getByLabel('Total items: 4',{exact:true}).count()===1,'total products counted');
  check(await page.getByLabel('Total active brands: 3',{exact:true}).count()===1,'inactive brands excluded from active total');
  check(JSON.stringify(await page.locator('.inv-brand-heading').allTextContents())===JSON.stringify(['Beximco LPG','Omera','Bashundhara']),'product sections follow brand order');
  check(await page.getByRole('region',{name:'Beximco LPG products'}).locator('.inv-tile').count()===2,'one section per company');
  check((await page.getByRole('region',{name:'Beximco LPG products'}).locator('.inv-tile-size').first().innerText()).startsWith('5'),'weights ascend within brand');
  const summaryHeight = await page.locator('.inv-overview').evaluate(element => element.getBoundingClientRect().height);
  check(summaryHeight < 65, 'compact desktop summary');
  await modal.getByRole('button', { name: 'Wholesale', exact: true }).click();
  check(await modal.getByText('Retail price applies', { exact: true }).count() === 2, 'wholesale fallback explained');
  await modal.getByRole('button', { name: 'Retail', exact: true }).click();
  await modal.getByRole('button', { name: 'Edit prices', exact: true }).click();
  await modal.getByRole('spinbutton', { name: 'Refill MRP', exact: true }).fill('1700');
  await modal.getByRole('spinbutton', { name: 'Refill selling price', exact: true }).fill('1300');
  await modal.getByRole('spinbutton', { name: 'Package MRP', exact: true }).fill('');
  await modal.getByRole('spinbutton', { name: 'Package selling price', exact: true }).fill('2600');
  // Background refetch must leave edited values and their original version intact.
  await page.evaluate(() => window.dispatchEvent(new Event('focus')));
  check(await modal.getByRole('spinbutton', { name: 'Refill selling price', exact: true }).inputValue() === '1300', 'draft preserved');
  failSave = true;
  await modal.getByRole('button', { name: 'Save prices', exact: true }).click();
  await modal.getByRole('alert').filter({ hasText: 'Prices changed' }).waitFor();
  check(await modal.getByRole('spinbutton', { name: 'Refill selling price', exact: true }).inputValue() === '1300', 'failed save preserves draft');
  failSave = false;
  await modal.getByRole('button', { name: 'Save prices', exact: true }).click();
  await modal.getByRole('button', { name: 'Edit prices', exact: true }).waitFor();
  check(await modal.getByText('Tk 1,300.00', { exact: true }).count() === 1 && saves === 2, 'saved selling price, modal stays open');
  await modal.getByRole('button', { name: 'Edit prices', exact: true }).click();
  await modal.getByRole('spinbutton', { name: 'Refill selling price', exact: true }).fill('9');
  await modal.getByRole('button', { name: 'Reload saved prices', exact: true }).click();
  await page.waitForFunction(() => document.querySelector('[aria-label="Refill selling price"]')?.value === '1300');
  await modal.getByRole('button', { name: 'Cancel', exact: true }).click();

  // Separate manual commissions reduce their respective buying estimates and never exposes its history.
  await modal.getByRole('button',{name:'Edit commission',exact:true}).click();
  const commissionDialog=page.getByRole('dialog',{name:'Edit commission',exact:true});
  check(await modal.locator('[aria-labelledby="product-commission-title"]').count()===0,'no separate commission box');
  await commissionDialog.getByLabel('Refill commission / unit',{exact:true}).fill('15');
  await commissionDialog.getByLabel('Package commission / unit',{exact:true}).fill('35');
  failCommission=true;
  await commissionDialog.getByRole('button',{name:'Save commission',exact:true}).click();
  await commissionDialog.getByRole('alert').filter({hasText:'Commission changed'}).waitFor();
  check(await commissionDialog.getByLabel('Refill commission / unit',{exact:true}).inputValue()==='15' && await commissionDialog.getByLabel('Package commission / unit',{exact:true}).inputValue()==='35','commission conflict preserves both drafts');
  failCommission=false;
  await commissionDialog.getByRole('button',{name:'Save commission',exact:true}).click();
  await commissionDialog.waitFor({state:'detached'});
  check(commissionSaves===2 && (await modal.locator('.product-commission-rate').first().innerText()).includes('15') && (await modal.locator('.product-commission-rate').last().innerText()).includes('35'),'current rate saved without closing modal');
  check(await modal.getByText('Tk 1,105.00',{exact:true}).count()===1,'refill manual commission deducted');
  check(await modal.getByText('Tk 2,090.00',{exact:true}).count()===1,'package manual commission deducted separately');
  await modal.getByRole('button',{name:'Edit commission',exact:true}).click();
  await commissionDialog.getByLabel('Refill commission / unit',{exact:true}).fill('16');
  await page.setViewportSize({width:320,height:850});
  check(await commissionDialog.evaluate(el=>el.scrollWidth<=el.clientWidth+1),'commission popup fits mobile');
  await page.screenshot({path:'.temp/inventory-history/commission-popup-320.png',animations:'disabled'});
  await page.evaluate(()=>window.dispatchEvent(new Event('focus')));
  check(await commissionDialog.getByLabel('Refill commission / unit',{exact:true}).inputValue()==='16','commission draft survives refresh');
  await commissionDialog.getByRole('button',{name:'Reload saved rates',exact:true}).click();
  await page.waitForFunction(()=>document.querySelector('.product-commission-form input')?.value==='15');
  await commissionDialog.getByRole('button',{name:'Cancel',exact:true}).click();
  await modal.getByRole('button',{name:'Edit commission',exact:true}).click();
  await page.keyboard.press('Escape');
  check(await commissionDialog.count()===0 && await page.locator('.product-dialog[open]').count()===1,'Escape closes commission popup only');

  for (const width of [1440, 768, 390, 320]) {
    await page.setViewportSize({ width, height: 900 });
    for (const theme of ['light', 'dark']) {
      await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
      check(await modal.evaluate(element => element.scrollWidth <= element.clientWidth + 1), `modal fits at ${width}`);
      check(await modal.locator('.product-dialog-body').evaluate(element => element.scrollWidth <= element.clientWidth + 1), `body fits at ${width}`);
      await modal.locator('.product-dialog-body').evaluate(element => element.scrollTop = 0);
      check(!await modal.getByRole('button', { name: 'Edit prices', exact: true }).isDisabled(), 'editing enabled after save');
      await page.screenshot({ path: `.temp/inventory-verification/product-${width}-${theme}.png`, animations: 'disabled' });
      await modal.locator('.product-history').evaluate(element => element.scrollIntoView({ block: 'start' }));
      const weekHeight = await modal.locator('.product-week').first().evaluate(element => element.getBoundingClientRect().height);
      check(weekHeight <= (width <= 540 ? 78 : 65), `compact weekly row at ${width}: ${weekHeight}`);
      check(await modal.locator('.product-week').last().evaluate(element => element.scrollWidth <= element.clientWidth + 1), `large signed quantities fit at ${width}`);
      check(await modal.locator('.product-week').last().locator('dd').evaluateAll(elements => elements.every(element => element.scrollWidth <= element.clientWidth + 1)), `signed values remain fully readable at ${width}`);
      check(await modal.locator('.product-dialog-header').evaluate(element => element.getBoundingClientRect().top > 0), `product header remains visible while scrolling at ${width}`);
      await page.screenshot({ path: `.temp/weekly-history-design/history-${width}-${theme}.png`, animations: 'disabled' });
    }
  }
  await modal.locator('.product-week').last().scrollIntoViewIfNeeded();
  await page.screenshot({ path: '.temp/inventory-verification/history-320.png', animations: 'disabled' });
  await page.keyboard.press('Escape');
  check(await modal.count() === 0, 'Escape closes native dialog');
  check(await page.getByRole('button',{name:/Beximco LPG.*12.*Product details/}).evaluate(element => element === document.activeElement), 'focus returns to product tile');
  for (const width of [1440, 390, 320]) {
    await page.setViewportSize({ width, height: 900 });
    check(await page.locator('.inv-overview').evaluate(element => element.scrollWidth <= element.clientWidth + 1), `summary fits at ${width}`);
    await page.screenshot({ path: `.temp/inventory-verification/inventory-${width}.png`, animations: 'disabled' });
  }
  // Verify saved price feeds POS, independently of MRP.
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.goto(origin + '/#/pos');
  await page.getByRole('button', { name: 'Increase Refill quantity', exact: true }).first().click();
  check(await page.locator('.pos-option-price').first().textContent() === 'Tk 1,300', 'POS uses selling price');
  check(!await page.locator('.pos-option-price').first().textContent().then(text => text.includes('1,700')), 'POS excludes MRP');

  // Settings persists the order and inventory starts each brand on a separate row.
  await page.goto(origin+'/#/settings');
  await page.getByRole('button',{name:/LPG Brands/}).click();
  await page.getByRole('button',{name:'Move Omera up',exact:true}).click();
  await page.waitForFunction(()=>document.querySelector('.brand-order-controls')?.parentElement?.textContent.includes('Omera'));
  await page.goto(origin+'/#/inventory');
  await page.locator('.inv-brand-heading').first().waitFor();
  check((await page.locator('.inv-brand-heading').allTextContents())[0]==='Omera','saved settings order used immediately');
  await page.goto(origin+'/#/settings');
  await page.getByRole('button',{name:/LPG Brands/}).click();
  failOrder=true;
  await page.getByRole('button',{name:'Move Omera down',exact:true}).click();
  await page.getByText('Brand order changed. Reload brands before reordering.',{exact:true}).waitFor();
  check(brands[0].brand_name==='Omera','failed reorder preserves saved order');
  failOrder=false;
  for (const width of [320, 390, 768, 1440]) {
    await page.setViewportSize({width,height:900});
    check(await page.locator('.brand-order-controls').evaluateAll(elements=>elements.every(element=>element.getBoundingClientRect().right<=innerWidth)),`brand order controls fit at ${width}`);
    await page.screenshot({path:`.temp/commission-brand-verification/settings-${width}.png`,animations:'disabled'});
  }
  manager=true;
  await page.reload();
  await page.goto(origin+'/#/inventory');
  await page.getByRole('button',{name:/Beximco LPG.*12.*Product details/}).click();
  await modal.getByRole('heading',{name:'Current pricing'}).waitFor();
  check(await modal.getByRole('button',{name:'Edit prices',exact:true}).count()===0,'manager cannot edit prices despite inventory manage');
  check(await modal.getByRole('button',{name:'Edit commission',exact:true}).count()===0,'manager cannot edit commission');
  check(await page.getByRole('button',{name:'Add Item',exact:true}).count()===1,'manager retains item registration');
  await page.keyboard.press('Escape');
  viewer = true;
  await page.reload();
  await page.goto(origin + '/#/inventory');
  await page.getByRole('button', { name: /Beximco LPG.*12.*Product details/ }).click();
  await modal.getByRole('heading', { name: 'Current pricing' }).waitFor();
  check(await modal.getByRole('button', { name: 'Edit prices', exact: true }).count() === 0, 'inventory viewer cannot edit');
  check(await page.getByRole('button', { name: 'Add Item', exact: true }).count() === 0, 'inventory viewer cannot add');
  await page.keyboard.press('Escape');
  failDetails = true;
  await page.reload();
  await page.getByRole('button', { name: /Beximco LPG.*12.*Product details/ }).click();
  await modal.getByRole('alert').waitFor();
  check(await modal.locator('.product-week').count() === 0, 'error does not masquerade as zero history');
  failDetails = false;
  await modal.getByRole('button', { name: 'Retry', exact: true }).click();
  await modal.getByRole('heading', { name: 'Current pricing' }).waitFor();
  check(errors.length === 0, 'no JavaScript errors: ' + errors.join(', '));
  return 'PASS: separate manual commission deductions, brand groups/order, weight sorting, catalog counts, owner-only prices/commission, conflict retention, reload, POS selling price, eight weeks, permissions, errors, focus and responsive light/dark layouts';
}
