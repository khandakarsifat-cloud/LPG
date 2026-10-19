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
        const subtotal = body.p_items.reduce((sum, line) => sum + line.quantity * line.unit_price, 0);
        const sale = { sale_id: `cd000000-0000-4000-8000-${String(checkouts.length).padStart(12, '0')}`,
          sale_tier: body.p_customer_tier, created_at: new Date().toISOString(), subtotal,
          discount_amount: body.p_discount_amount, exchange_fee: body.p_exchange_fee,
          total_amount: subtotal - body.p_discount_amount + body.p_exchange_fee,
          customers: { ...customer }, sale_items: body.p_items.map(line => ({ ...line,
            line_total: line.quantity * line.unit_price, items: items.find(item => item.item_id === line.item_id) })) };
        sales.push(sale);
        data = { ...sale, customer_id: customerId, customer_phone: customer.phone, customer_name: customer.name };
        break;
      }
      case 'sales': data = url.searchParams.has('sale_id') ? sales[0] : sales; break;
    }
    await route.fulfill({ json: data });
  });
  const check = (condition, message) => { if (!condition) throw Error(message); };
  const expectVisible = async text => { await page.getByText(text, { exact: true }).waitFor(); };
  await page.goto(origin + '/?sale-tier-fixtures=1#/pos');
  await page.setViewportSize({ width: 1440, height: 1050 });
  const add = label => page.getByRole('button', { name: label, exact: true }).click();
  await add('Refill for Tier Gas 12kg');
  await add('Return Empty for Tier Gas 12kg');
  await add('New Package for Tier Gas 12kg');
  await add('New Package for Tier Gas 12kg');
  await add('New Package for Fallback Gas 5kg');
  await expectVisible('refill - Tk 1,200.00');
  await expectVisible('package - Tk 2,500.00');
  await page.getByPlaceholder('Phone, name, shop, address...').fill('01712345678');
  await page.getByText(customer.name, { exact: true }).click();
  const tier = page.getByRole('group', { name: 'Sale pricing' });
  await tier.getByRole('button', { name: 'Wholesale', exact: true }).click();
  await expectVisible('refill - Tk 1,100.00');
  await expectVisible('package - Tk 2,300.00');
  await expectVisible('package - Tk 900.00');
  await expectVisible('Wholesale Sale');
  check(await page.getByRole('button', { name: 'Choose another customer' }).isVisible(), 'Tier change detached saved customer');
  await tier.getByRole('button', { name: 'Retail', exact: true }).click();
  await expectVisible('refill - Tk 1,200.00');
  await expectVisible('package - Tk 2,500.00');
  await tier.getByRole('button', { name: 'Wholesale', exact: true }).click();
  await add('New Package for Tier Gas 12kg');
  // Editing cents must survive each keystroke; wheel/arrow navigation must not step money.
  for (const label of ['Discount (Tk)', 'Exchange Fee (Tk)']) {
    const input = page.getByLabel(label, { exact: true });
    check(await input.getAttribute('type') === 'text' && await input.getAttribute('inputmode') === 'decimal', `${label} must use direct decimal entry`);
    await input.fill('');
    await input.pressSequentially('12.50');
    check(await input.inputValue() === '12.50', `${label} lost decimal input`);
    await input.press('ArrowUp');
    await input.hover();
    await page.mouse.wheel(0, 120);
    check(await input.inputValue() === '12.50' && await input.evaluate(el => document.activeElement === el), `${label} changed or lost focus while scrolling`);
  }
  await page.getByLabel('Discount (Tk)', { exact: true }).fill('100');
  await page.getByLabel('Exchange Fee (Tk)', { exact: true }).fill('50');
  // The saved-customer tier control stays reachable at phone/tablet widths.
  for (const width of [390, 768, 1440]) {
    await page.setViewportSize({ width, height: 1050 });
    await tier.scrollIntoViewIfNeeded();
    check(await tier.evaluate(el => el.getBoundingClientRect().right <= window.innerWidth), `Tier control overflows at ${width}px`);
  }
  await add('Complete Checkout');
  await page.getByLabel('Receipt printer', { exact: true }).click();
  await page.keyboard.press('Escape');
  check(await page.getByRole('button', { name: 'Confirm', exact: true }).isVisible(), 'Dismissing receipt picker closed checkout');
  await add('Confirm');
  await page.getByText(/Saved wholesale sale/).waitFor();
  const submitted = checkouts[0];
  check(submitted.p_customer_id === customerId && submitted.p_customer_tier === 'wholesale', 'Checkout lost customer or tier');
  check(submitted.p_items.find(line => line.type === 'refill').unit_price === 1100, 'Refill checkout price is stale');
  const packageLine = submitted.p_items.find(line => line.item_id === sku && line.type === 'package');
  check(packageLine.unit_price === 2300 && packageLine.quantity === 3, 'Existing line increment used stale price');
  check(sales[0].total_amount === 8850, 'Repriced total, discount or exchange fee is incorrect');
  await page.getByRole('button', { name: 'Reprint Last Sale' }).click();
  await page.getByText('Browser print dialog opened. Confirm printing in your browser.', { exact: true }).waitFor();
  await page.waitForFunction(() => !document.querySelector('iframe[title="Printable sales receipt"]'));
  check(printed.length === 1 && printed[0].includes('wholesale'), 'Receipt used customer retail tier instead of saved sale tier');
  await page.goto(origin + '/?sale-tier-fixtures=1#/');
  await page.getByText(customer.name, { exact: true }).click();
  await expectVisible('wholesale');
  // Selecting a wholesale customer also reprices a retail draft, then an explicit
  // retail override must be captured independently of that customer's profile.
  customer.tier = 'wholesale';
  await page.goto(origin + '/?sale-tier-fixtures=1#/pos');
  await page.reload();
  await add('New Package for Tier Gas 12kg');
  await expectVisible('package - Tk 2,500.00');
  await page.getByPlaceholder('Phone, name, shop, address...').fill('01712345678');
  await page.getByText(customer.name, { exact: true }).click();
  await expectVisible('package - Tk 2,300.00');
  await tier.getByRole('button', { name: 'Retail', exact: true }).click();
  await expectVisible('package - Tk 2,500.00');
  await add('Complete Checkout');
  await add('Confirm');
  await page.getByText(/Saved retail sale/).waitFor();
  check(checkouts[1].p_customer_id === customerId && checkouts[1].p_customer_tier === 'retail'
    && checkouts[1].p_items[0].unit_price === 2500, 'Wholesale customer retail override failed');
  check(errors.length === 0, errors.join('\n'));
  return { checkoutTiers: checkouts.map(body => body.p_customer_tier),
    total: sales[0].total_amount, receipts: printed.length, checks: 'cart repricing both ways, quantities, retail fallback, customer retention, saved sale, receipt, responsive controls' };
}
