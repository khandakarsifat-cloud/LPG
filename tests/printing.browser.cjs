// Run with playwright-cli run-code --filename=tests/printing.browser.cjs on local Vite.
// All backend/device calls are fixtures and Window.print is intercepted in every frame.
async page => {
  const appUrl = new URL(page.url()).origin;
  const tenant = 'bb000000-0000-4000-8000-000000000001';
  const user = { id: 'bb000000-0000-4000-8000-000000000002', aud: 'authenticated', role: 'authenticated', email: 'print@example.invalid', app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() };
  const saleId = 'bb000000-0000-4000-8000-000000000003';
  const sku = 'bb000000-0000-4000-8000-000000000004';
  const payload = btoa(JSON.stringify({ sub: user.id, exp: Math.floor(Date.now() / 1000) + 86400, aud: 'authenticated', role: 'authenticated' })).replaceAll('=', '').replaceAll('+', '-').replaceAll('/', '_');
  const token = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.' + payload + '.Zml4dHVyZQ';
  const printed = [];
  let onPrint = () => {};
  await page.exposeFunction('__captureReceipt', text => { printed.push(text); onPrint(); });
  await page.context().addInitScript(({ user, token }) => {
    const session = JSON.stringify({ access_token: token, refresh_token: 'fixture-refresh', token_type: 'bearer', expires_in: 86400, expires_at: Math.floor(Date.now() / 1000) + 86400, user });
    localStorage.setItem('sb-api-auth-token', session);
    localStorage.setItem('sb-127-auth-token', session);
    localStorage.setItem('sb-localhost-auth-token', session);
    window.print = () => {
      window.top.__captureReceipt(document.body.innerText);
      window.dispatchEvent(new Event('afterprint'));
    };
  }, { user, token });
  const device = { device_id: 'USBPRINT\\FIXTURE', serial_number: 'fixture', vendor_id: '1234', product_id: '5678', manufacturer: 'Fixture', model: 'Fixture', present: true, port_name: 'USB001' };
  const printer = { queue_id: 'fixture-queue', host_id: 'fixture-host', queue_name: 'Fixture Thermal', port_name: 'USB001', driver_name: 'Fixture', transport: 'windows_usb', device };
  let config = { tenant_id: tenant, printer, paper_width_mm: 80, printable_width_dots: 576, auto_cut: false };
  const sale = { sale_id: saleId, sale_tier: 'retail', created_at: new Date().toISOString(), subtotal: 1200, discount_amount: 100, exchange_fee: 50, total_amount: 1150, notes: '<img src=x onerror=alert(1)>', customers: { name: 'Receipt Customer বাংলা', phone: '01700000000', tier: 'retail' }, sale_items: [{ quantity: 1, unit_price: 1200, line_total: 1200, type: 'package', items: { brand: 'Fixture Gas', size_kg: 12, lpg_brands: { brand_name: 'Fixture Gas' } } }] };
  let bridgeRunning = false, bridgePrints = 0, configWrites = 0, checkouts = 0, saleReads = 0;
  let cashier = false;
  await page.route('**/auth/v1/**', route => route.fulfill({ json: user }));
  await page.route('http://127.0.0.1:17891/**', async route => {
    if (!bridgeRunning) return route.abort('connectionrefused');
    if (new URL(route.request().url()).pathname === '/print') {
      bridgePrints++;
      return route.fulfill({ json: { job_id: 42, message: 'Receipt sent to printer (fixture).' } });
    }
    return route.fulfill({ json: { printers: [{ ...printer, available: true, supported: true }], usb_devices: [device] } });
  });
  await page.route('**/rest/v1/**', async route => {
    const req = route.request(), url = new URL(req.url()), name = url.pathname.split('/').pop();
    let data = [];
    switch (name) {
      case 'user_profiles': data = [{ tenant_id: tenant, full_name: 'Receipt Operator', email: user.email, tenants: { business_name: 'Receipt Shop বাংলা' } }]; break;
      case 'get_my_permissions': data = ['dashboard:view', 'sales:view', 'pos:sell', 'inventory:view', 'customers:view', 'receipts:print', ...(!cashier ? ['printers:manage'] : [])]; break;
      case 'get_dashboard_stats': data = { todayRevenue: 1150, todayMovements: 1, totalCustomers: 1 }; break;
      case 'receipt_printers':
        if (req.method() === 'POST') { configWrites++; config = req.postDataJSON(); }
        data = config ? [config] : []; break;
      case 'sales': saleReads++; data = [sale]; break;
      case 'wallets': data = [{ type: 'dealership', balance: 1000 }]; break;
      case 'items': data = [{ item_id: sku, brand: 'Fixture Gas', size_kg: 12, mouth_size: '22mm', filled_quantity: 10, empty_quantity: 10, lpg_brands: { brand_name: 'Fixture Gas' } }]; break;
      case 'price_books': data = [{ item_id: sku, customer_tier: 'retail', price_type: 'package', price: 1200, effective_from: '2026-01-01' }]; break;
      case 'create_pos_sale': checkouts++; data = { sale_id: saleId, sale_tier: 'retail', customer_id: user.id, subtotal: 1200, total_amount: 1200, customer_phone: '01700000000', customer_name: 'Receipt Customer বাংলা' }; break;
    }
    if (req.headers().accept?.includes('application/vnd.pgrst.object+json') && Array.isArray(data)) data = data[0] ?? null;
    await route.fulfill({ json: data });
  });
  const check = (condition, message) => { if (!condition) throw new Error(message); };
  const waitPrints = async count => {
    // Wait on the intercepted print call, including async checkout/read/render work.
    if (printed.length < count) await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error(`Browser print ${count} timed out`)), 10000);
      onPrint = () => { if (printed.length >= count) { clearTimeout(timeout); resolve(); } };
    });
    await page.waitForFunction(() => !document.querySelector('iframe[title="Printable sales receipt"]'));
    check(printed.length === count, `Expected ${count} browser receipts, got ${printed.length}`);
  };
  await page.goto(appUrl + '/?printing-fixtures=1#/');
  await page.getByRole('button', { name: 'Receipt Printer', exact: true }).click();
  await page.getByLabel('Printer', { exact: true }).selectOption('browser');
  await page.getByRole('button', { name: 'Save Printer' }).click();
  check(configWrites === 0, 'Browser preference must preserve shared USB settings');
  await page.reload();
  await page.getByRole('button', { name: 'Receipt Printer', exact: true }).click();
  check(await page.getByLabel('Printer', { exact: true }).inputValue() === 'browser', 'Browser choice must survive reload');
  await page.getByRole('button', { name: 'Cancel', exact: true }).click();
  await page.getByText('Receipt Customer বাংলা', { exact: true }).click();
  await page.getByRole('button', { name: 'Print Receipt Again' }).click();
  await waitPrints(1);
  check(bridgePrints === 0 && checkouts === 0, 'Browser reprint must not call bridge or checkout');
  check(printed[0].includes('Tk 1,150.00') && printed[0].includes('Receipt Shop বাংলা'), 'Browser receipt must use saved amounts and Unicode');
  check(printed[0].includes('<img src=x onerror=alert(1)>'), 'Receipt notes must render as text');
  check(saleReads >= 2, 'Reprint must load saved sale');
  await page.getByRole('button', { name: 'Close', exact: true }).click();
  // USB selection, discovery and transport continue through the original boundary.
  bridgeRunning = true;
  await page.getByRole('button', { name: 'Receipt Printer', exact: true }).click();
  await page.getByLabel('Printer', { exact: true }).selectOption(printer.queue_id);
  await page.getByRole('button', { name: 'Save Printer' }).click();
  check(configWrites === 1, 'USB configuration must still save through the existing upsert');
  await page.getByText('Receipt Customer বাংলা', { exact: true }).click();
  await page.getByRole('button', { name: 'Print Receipt Again' }).click();
  await page.getByText('Receipt sent to printer (fixture).', { exact: true }).waitFor();
  check(bridgePrints === 1 && checkouts === 0, 'USB reprint must send once without checkout');
  // Cashiers can choose browser printing without printer-management permissions.
  await page.getByRole('button', { name: 'Close', exact: true }).click();
  cashier = true; bridgeRunning = false;
  await page.reload();
  await page.getByText('Receipt Customer বাংলা', { exact: true }).click();
  await page.getByLabel('Receipt printer', { exact: true }).click();
  await page.keyboard.press('Escape');
  check(await page.getByRole('button', { name: 'Print Receipt Again' }).isVisible(), 'Dismissing receipt picker closed sale details');
  await page.getByLabel('Receipt printer', { exact: true }).selectOption('browser');
  await page.getByRole('button', { name: 'Print Receipt Again' }).click();
  await waitPrints(2);
  check(bridgePrints === 1 && configWrites === 1 && checkouts === 0, 'Cashier browser printing must be independent of the bridge');
  await page.getByRole('button', { name: 'Close', exact: true }).click();
  // No configured printer: browser printing is the default at checkout and reprint.
  config = null;
  await page.evaluate(tenant => localStorage.removeItem(`lpg:receipt-print-method:v1:${tenant}`), tenant);
  await page.reload();
  await page.goto(appUrl + '/?printing-fixtures=1#/pos');
  await page.getByRole('button', { name: 'New Package for Fixture Gas 12kg', exact: true }).click();
  await page.getByPlaceholder('Phone, name, shop, address...').fill('01700000000');
  await page.getByPlaceholder('Customer name...').fill('Checkout Customer');
  await page.getByRole('button', { name: 'Complete Checkout', exact: true }).click();
  check(await page.getByLabel('Receipt printer', { exact: true }).inputValue() === 'browser', 'No USB config should default to browser');
  await page.getByRole('button', { name: 'Confirm & Print', exact: true }).click();
  await waitPrints(3);
  check(checkouts === 1 && bridgePrints === 1, 'Browser checkout must commit exactly once without bridge calls');
  await page.getByRole('button', { name: 'Reprint Last Sale', exact: true }).click();
  await waitPrints(4);
  check(checkouts === 1, 'Reprinting last sale must not repeat checkout');
  // Receipt controls stay within the viewport at mobile widths.
  for (const width of [320, 390, 768]) {
    await page.setViewportSize({ width, height: 900 });
    const closeMenu = page.getByRole('button', { name: 'Close navigation', exact: true });
    if (await closeMenu.count()) await closeMenu.click();
    await page.getByLabel('Receipt printer', { exact: true }).scrollIntoViewIfNeeded();
    const fits = await page.getByLabel('Receipt printer', { exact: true }).evaluate((el, width) => el.getBoundingClientRect().right <= width && el.getBoundingClientRect().left >= 0, width);
    check(fits, `Receipt selector must fit at ${width}px`);
  }
  // Render the actual shared browser template for visual inspection without printing.
  await page.screenshot({ path: '.temp/printing-verification/pos-reprint-768.png' });
  for (const paperWidth of [58, 80]) {
    const html = await page.evaluate(async ({ sale, paperWidth }) => {
      const { browserReceiptHTML } = await import('/src/lib/browserPrint.ts');
      return browserReceiptHTML({ ...sale, shop_name: 'Receipt Shop বাংলা', customer_name: sale.customers.name,
        customer_phone: sale.customers.phone, customer_tier: 'retail',
        items: sale.sale_items.map(line => ({ ...line, name: line.items.brand + ' 12kg' })) }, paperWidth);
    }, { sale, paperWidth });
    await page.setContent(html);
    await page.screenshot({ path: `.temp/printing-verification/receipt-${paperWidth}.png` });
    // Return to the app so the next template can be imported under its CSP.
    await page.goto(appUrl + '/?printing-fixtures=1#/');
  }
  return JSON.stringify({ browserReceipts: printed.length, bridgePrints, configWrites, checkouts, saleReads, result: 'PASS (fixtures only; no physical jobs)' });
}
