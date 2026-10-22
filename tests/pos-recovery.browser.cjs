// Run with playwright-cli on local Vite. All API calls and printing are fixtures.
async page => {
  const origin = new URL(page.url()).origin;
  const tenant = 'cd000000-0000-4000-8000-000000000001';
  const sku = 'cd000000-0000-4000-8000-000000000003';
  const customerId = 'cd000000-0000-4000-8000-000000000004';
  const user = { id: 'cd000000-0000-4000-8000-000000000002', aud: 'authenticated', role: 'authenticated',
    email: 'tier@example.invalid', app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() };
  const payload = btoa(JSON.stringify({ sub: user.id, exp: Math.floor(Date.now() / 1000) + 86400, aud: 'authenticated', role: 'authenticated' })).replaceAll('=', '').replaceAll('+', '-').replaceAll('/', '_');
  const token = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.' + payload + '.Zml4dHVyZQ';
  const printed = [];
  await page.exposeFunction('__captureTierReceipt', text => printed.push(text));
  await page.context().addInitScript(({ user, token }) => {
    const session = JSON.stringify({ access_token: token, refresh_token: 'fixture', token_type: 'bearer', expires_in: 86400,
      expires_at: Math.floor(Date.now() / 1000) + 86400, user });
    for (const host of ['api', '127', 'localhost']) localStorage.setItem(`sb-${host}-auth-token`, session);
    window.print = () => {
      window.top.__captureTierReceipt(document.body.innerText);
      window.dispatchEvent(new Event('afterprint'));
    };
  }, { user, token });
  const customer = { tenant_id: tenant, customer_id: customerId, name: 'Saved Retail Customer', phone: '01712345678', tier: 'retail', address: 'Dhaka' };
  const items = [
    { tenant_id: tenant, item_id: sku, brand: 'Tier Gas', size_kg: 12, mouth_size: '22mm', filled_quantity: 40, empty_quantity: 40, lpg_brands: { brand_name: 'Tier Gas' } },
    { tenant_id: tenant, item_id: 'fallback', brand: 'Fallback Gas', size_kg: 5, mouth_size: '22mm', filled_quantity: 40, empty_quantity: 40, lpg_brands: { brand_name: 'Fallback Gas' } },
  ];
  const prices = [
    { item_id: sku, customer_tier: 'retail', price_type: 'refill', price: 1200 },
    { item_id: sku, customer_tier: 'retail', price_type: 'package', price: 2500 },
    { item_id: sku, customer_tier: 'wholesale', price_type: 'refill', price: 1100 },
    { item_id: sku, customer_tier: 'wholesale', price_type: 'package', price: 2300 },
    { item_id: 'fallback', customer_tier: 'retail', price_type: 'package', price: 900 },
  ].map(row => ({ ...row, effective_from: '2026-01-01' }));
  const checkouts = [];
  let loseResponse = true;
  let rejectValidation = true;
  let expireSession = true;
  const sales = [];
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.route('**/auth/v1/**', route => route.fulfill({ json: user }));
  await page.route('**/rest/v1/**', async route => {
    const request = route.request();
    const url = new URL(request.url());
    const name = url.pathname.split('/').pop();
    let data = [];
    switch (name) {
      case 'user_profiles': data = [{ tenant_id: tenant, full_name: 'Tier Operator', email: user.email, tenants: { business_name: 'Tier verification' } }]; break;
      case 'get_my_permissions': data = ['dashboard:view', 'sales:view', 'receipts:print', 'pos:sell']; break;
      case 'get_dashboard_stats': data = { todayRevenue: 0, todayMovements: 0, totalCustomers: 1 }; break;
      case 'items': data = items; break;
      case 'price_books': data = prices; break;
      case 'customers': data = [customer]; break;
      case 'create_pos_sale': {
        const body = request.postDataJSON();
        checkouts.push(body);
        if (rejectValidation) {
          rejectValidation = false;
          await route.fulfill({status:400,json:{code:'P0001',message:'Selling price changed. Refresh prices.'}});
          return;
        }
        if (sales.length) {
          if (expireSession) {
            expireSession = false;
            await route.fulfill({status:401,json:{code:'PGRST301',message:'JWT expired'}});
            return;
          }
          data = { ...sales[0], customer_id: customerId, customer_phone: customer.phone, customer_name: customer.name }; break;
        }
        const subtotal = body.p_items.reduce((sum, line) => sum + line.quantity * line.unit_price, 0);
        const sale = { sale_id: `cd000000-0000-4000-8000-${String(checkouts.length).padStart(12, '0')}`,
          sale_tier: body.p_customer_tier, created_at: new Date().toISOString(), subtotal,
          discount_amount: body.p_discount_amount, exchange_fee: body.p_exchange_fee,
          total_amount: subtotal - body.p_discount_amount + body.p_exchange_fee,
          customers: { ...customer }, sale_items: body.p_items.map(line => ({ ...line,
            line_total: line.quantity * line.unit_price, items: items.find(item => item.item_id === line.item_id) })) };
        sales.push(sale);
        data = { ...sale, customer_id: customerId, customer_phone: customer.phone, customer_name: customer.name };
        if (loseResponse) { loseResponse = false; await route.abort('failed'); return; }
        break;
      }
      case 'sales' : data = url.searchParams.has('sale_id') ? sales[0] : sales; break;
    }
    await route.fulfill({ json: data });
  });

  const check = (ok, message) => { if (!ok) throw Error(message); };
  await page.goto(origin+'/?checkout-recovery=1#/pos');
  await page.getByRole('button',{name:'New Package for Tier Gas 12kg',exact:true}).click();
  await page.getByPlaceholder('Phone, name, shop, address...').fill(customer.phone);
  await page.getByText(customer.name,{exact:true}).click();
  await page.getByRole('button',{name:'Complete Checkout',exact:true}).click();
  await page.getByRole('button',{name:'Confirm',exact:true}).click();
  await page.getByText('Failed to complete sale: Selling price changed. Refresh prices.',{exact:true}).waitFor();
  check(sales.length===0 && await page.getByRole('button',{name:'Recover checkout',exact:true}).count()===0,'a definite validation failure must retain the draft without an uncertain request');
  await page.getByRole('button',{name:'Cancel',exact:true}).click();
  check(checkouts.length===1 && sales.length===0,'cancelling confirmation must not submit or reverse a sale');
  await page.getByRole('button',{name:'Complete Checkout',exact:true}).click();
  await page.getByRole('button',{name:'Confirm',exact:true}).click();
  await page.getByRole('button',{name:'Recover checkout',exact:true}).waitFor();
  check(sales.length===1,'lost response must follow a committed fixture sale');
  await page.reload();
  await page.getByRole('button',{name:'Recover checkout',exact:true}).click();
  await page.getByText('Failed to complete sale: JWT expired',{exact:true}).waitFor();
  await page.getByRole('button',{name:'Recover checkout',exact:true}).click();
  await page.getByText(/Saved retail sale/).waitFor();
  check(checkouts.length===4 && checkouts[1].p_request_id===checkouts[2].p_request_id && checkouts[2].p_request_id===checkouts[3].p_request_id,'recovery must reuse request ID across reload and an expired-session response');
  check(checkouts[0].p_request_id!==checkouts[1].p_request_id,'a definite rejection must release the previous request');
  check(JSON.stringify(checkouts[1])===JSON.stringify(checkouts[2]),'recovery must reuse the original payload');
  check(JSON.stringify(checkouts[2])===JSON.stringify(checkouts[3]),'an auth failure must retain the original request');
  check(sales.length===1 && printed.length===0,'recovery must not duplicate or print automatically');
  check(await page.getByRole('button',{name:'Recover checkout',exact:true}).count()===0,'confirmed recovery must clear the pending request');
  for (const width of [390,768,1440]) {
    await page.setViewportSize({width,height:900});
    check(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),'recovery UI must fit at '+width);
  }
  return {validationErrorShown:true,cancelIsReadOnly:true,lostResponse:true,reloadRecovery:true,sameRequestAndPayload:true,duplicateSales:0,unexpectedPrints:printed.length};
}
