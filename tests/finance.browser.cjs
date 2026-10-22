// UI acceptance with isolated Auth/REST fixtures; never prints or writes a real business.
async page => {
  const origin = new URL(page.url()).origin;
  const id = n => `fb000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
  const tenant = id(1), customerId = id(3), sku = id(4);
  const user = { id: id(2), aud: 'authenticated', role: 'authenticated', email: 'finance@example.invalid', app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() };
  const payload = btoa(JSON.stringify({ sub: user.id, exp: Math.floor(Date.now() / 1000) + 86400, aud: 'authenticated', role: 'authenticated' })).replaceAll('=', '').replaceAll('+', '-').replaceAll('/', '_');
  const token = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.' + payload + '.Zml4dHVyZQ';
  await page.context().addInitScript(({ user, token, tenant }) => {
    const session = JSON.stringify({ access_token: token, refresh_token: 'fixture-refresh', token_type: 'bearer', expires_in: 86400, expires_at: Math.floor(Date.now() / 1000) + 86400, user });
    for (const host of ['api', '127', 'localhost']) localStorage.setItem(`sb-${host}-auth-token`, session);
    localStorage.setItem(`lpg:receipt-print-method:v1:${tenant}`, 'browser');
    window.print = () => { throw Error('Unexpected physical/browser print in finance UI test'); };
  }, { user, token, tenant });
  const wallets = [
    { wallet_id: id(10), type: 'cash', kind: 'cash', name: 'Cash Register', balance: 26500 },
    { wallet_id: id(11), type: 'bkash', kind: 'bkash', name: 'bKash', balance: 15200 },
    { wallet_id: id(12), type: 'nagad', kind: 'nagad', name: 'Nagad', balance: 6200 },
    { wallet_id: id(13), type: 'dealership', kind: 'bank', name: 'Primary Bank Account', balance: -150000 },
    { wallet_id: id(14), type: 'logistics', kind: 'logistics', name: 'Logistics', balance: 8000 },
  ].map(w => ({ ...w, tenant_id: tenant, is_active: true, revision: 1, details: '', opening_balance: 0, created_at: '2026-10-01T00:00:00Z', updated_at: '2026-10-01T00:00:00Z' }));
  const customer = { tenant_id: tenant, customer_id: customerId, name: 'Shahidul Islam', phone: '01712345678', tier: 'retail', shop_name: 'Bismillah Traders', address: 'Mirpur, Dhaka' };
  const items = [{ tenant_id: tenant, item_id: sku, brand: 'Jamuna Gas', size_kg: 12, mouth_size: '22mm', filled_quantity: 50, empty_quantity: 50, lpg_brands: { brand_name: 'Jamuna Gas' } }];
  const ledger = Array.from({ length: 51 }, (_, n) => ({ transaction_id: id(100 + n), wallet_id: wallets[n % 5].wallet_id, wallet_name: wallets[n % 5].name, type: n % 2 ? 'wallet_transfer' : 'pos_sale_income', amount: n % 2 ? -700 : 1500, balance_after: n % 5 === 3 ? -150000 : 26500, created_at: '2026-10-20T10:00:00Z', description: n % 2 ? 'Cash replenishment from bank' : 'Sale payment · Jamuna Gas 12kg', reference_id: id(300), operation_id: id(200), counterparty: n % 2 ? 'Primary Bank Account' : null, actor: 'Owner', payment_reference: n === 0 ? 'BK-SEARCH-123' : '', customer_name: customer.name, customer_phone: customer.phone, source: 'sale' }));
  const sales = []; const calls = []; const errors = []; const operations = new Map(); let loseCollectionResponse = true;
  page.on('pageerror', error => errors.push(error.message));
  await page.route('**/auth/v1/**', route => route.fulfill({ json: user }));
  await page.route('**/rest/v1/**', async route => {
    const req = route.request(), url = new URL(req.url()), name = url.pathname.split('/').pop(), args = req.method() === 'POST' ? req.postDataJSON() : {};
    calls.push({ name, args }); let data = [];
    if (name === 'user_profiles') data = [{ tenant_id: tenant, email: user.email, full_name: 'Finance Owner', tenants: { business_name: 'LPG Finance Demo' } }];
    else if (name === 'get_my_permissions') data = ['dashboard:view', 'sales:view', 'receipts:print', 'pos:sell', 'finance:view', 'finance:manage', 'customers:view', 'customers:manage', 'logistics:view'];
    else if (name === 'wallets') data = wallets;
    else if (name === 'receipt_printers') data = null;
    else if (name === 'get_payment_wallets') data = wallets.filter(w => w.is_active && w.kind !== 'logistics');
    else if (name === 'get_wallet_ledger') {
      const f = args.p_filters || {}; let rows = ledger.filter(r => (!f.wallet || r.wallet_id === f.wallet) && (!f.type || r.type === f.type));
      if (f.search) rows = rows.filter(r => JSON.stringify(r).toLowerCase().includes(f.search.toLowerCase()));
      data = { entries: rows.slice(args.p_offset, args.p_offset + args.p_limit), total: rows.length, received: rows.filter(r => r.amount > 0).reduce((sum, r) => sum + r.amount, 0), paid_out: -rows.filter(r => r.amount < 0).reduce((sum, r) => sum + r.amount, 0) };
    } else if (name === 'save_finance_wallet') {
      wallets.push({ ...wallets[0], ...args.p_payload, type: 'custom', wallet_id: id(20), balance: 0 }); data = id(20);
    } else if (name === 'move_wallet_money') {
      data = { operation_id: args.p_request_id }; operations.set(args.p_request_id, args);
    } else if (name === 'items') data = items;
    else if (name === 'price_books') data = [{ tenant_id: tenant, item_id: sku, customer_tier: 'retail', price_type: 'package', price: 2300, effective_from: '2026-01-01' }];
    else if (name === 'customers') data = [customer];
    else if (name === 'create_pos_sale') {
      const paid = args.p_payments === null ? 2300 : args.p_payments.reduce((sum, p) => sum + p.amount, 0);
      const sale = { sale_id: id(300 + sales.length), sale_tier: 'retail', created_at: new Date().toISOString(), customer_id: customerId, total_amount: 2300, subtotal: 2300, discount_amount: 0, exchange_fee: 0, paid_amount: paid, due: 2300 - paid, customers: customer, sale_items: [{ ...args.p_items[0], line_total: 2300, items: items[0] }], payments: args.p_payments ?? [{ wallet_id: wallets[0].wallet_id, amount: 2300 }] };
      sales.push(sale); data = sale;
    } else if (name === 'get_finance_dues') {
      const rows = sales.filter(s => s.due > 0).map(s => ({ ...s, ...customer })); data = { entries: rows, total: rows.length, due: rows.reduce((sum, s) => sum + s.due, 0) };
    } else if (name === 'collect_sale_payment') {
      const s = sales.find(s => s.sale_id === args.p_sale_id);
      if (!operations.has(args.p_request_id)) { const paid = args.p_payments.reduce((sum, p) => sum + p.amount, 0); s.paid_amount += paid; s.due -= paid; s.payments.push(...args.p_payments.map(p => ({ ...p, phase: 'collection' }))); operations.set(args.p_request_id, args); }
      if (loseCollectionResponse) { loseCollectionResponse = false; return route.abort('connectionreset'); }
      data = { sale_id: s.sale_id, paid_amount: s.paid_amount, due: s.due };
    } else if (name === 'get_sale_settlement') {
      const s = sales.find(s => s.sale_id === args.p_sale_id);
      data = s ? { sale_id: s.sale_id, tracking: true, total: s.total_amount, paid: s.paid_amount, due: s.due, paid_at_checkout: s.paid_amount, payments: [], payment_count: 0, receipt_payments: s.payments.map(p => ({ ...p, wallet_name: wallets.find(w => w.wallet_id === p.wallet_id).name, method: wallets.find(w => w.wallet_id === p.wallet_id).kind })) } : { tracking: false, paid: 1500, due: 0, total: 1500, payment_count: 0, payments: [], receipt_payments: [] };
    } else if (name === 'sales') data = url.searchParams.has('sale_id') ? sales.find(s => s.sale_id === url.searchParams.get('sale_id').replace('eq.', '')) : sales;
    else if (name === 'get_dashboard_stats') data = { todayRevenue: 0, todayMovements: 0, totalCustomers: 1 };
    await route.fulfill({ json: data });
  });
  const check = (condition, message) => { if (!condition) throw Error(message); };
  await page.goto(origin + '/?finance-fixtures=' + Date.now() + '#/finance');
  await page.getByRole('heading', { name: 'Finance', exact: true }).last().waitFor();
  await page.getByText('51 entries', { exact: true }).waitFor();
  await page.getByRole('button', { name: 'Next page', exact: true }).click();
  await page.getByText('26–50 of 51 ledger entries', { exact: true }).waitFor();
  check(calls.some(c => c.name === 'get_wallet_ledger' && c.args.p_offset === 25 && c.args.p_limit === 25), 'Ledger was not server paged');
  await page.getByLabel('Search wallet ledger').fill('BK-SEARCH-123');
  await page.getByText('1 entries', { exact: true }).waitFor();
  await page.getByRole('button', { name: 'Reset', exact: true }).click();
  for (const width of [1440, 768, 390]) {
    await page.setViewportSize({ width, height: 950 });
    check(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), `Finance overflows at ${width}`);
    await page.screenshot({ path: `.temp/finance/finance-${width}.png`, fullPage: true });
  }
  await page.setViewportSize({ width: 1440, height: 1000 });
  await page.getByRole('button', { name: 'Add wallet', exact: true }).click();
  await page.getByLabel('Wallet name', { exact: true }).fill('Secondary Bank');
  await page.getByRole('button', { name: 'Save wallet', exact: true }).click();
  await page.getByRole('button', { name: 'Manage Secondary Bank' }).waitFor();
  await page.getByRole('button', { name: 'Transfer', exact: true }).click();
  await page.getByLabel('From wallet', { exact: true }).selectOption(wallets[0].wallet_id);
  await page.getByLabel('To wallet', { exact: true }).selectOption(wallets[1].wallet_id);
  await page.getByLabel('Amount (Tk)', { exact: true }).fill('500');
  await page.getByLabel('Reason / reference', { exact: true }).fill('Cash to bKash');
  await page.getByRole('button', { name: 'Record transfer', exact: true }).click();
  await page.getByText('Transfer recorded', { exact: true }).waitFor();
  const draftSale = async () => {
    await page.goto(origin + '/?finance-fixtures=1#/pos');
    await page.getByRole('button', { name: 'New Package for Jamuna Gas 12kg', exact: true }).click();
    await page.getByPlaceholder('Phone, name, shop, address...').fill(customer.phone);
    await page.getByText(customer.name, { exact: true }).click();
    await page.getByRole('button', { name: 'Complete Checkout', exact: true }).click();
    await page.getByRole('dialog', { name: 'Confirm Sale', exact: true }).waitFor();
  };
  await draftSale();
  check(await page.getByLabel('Payment 1 amount').count() === 0, 'Default checkout exposed payment controls');
  await page.getByRole('button', { name: 'Confirm', exact: true }).click();
  await page.getByText(/Saved retail sale/).waitFor();
  check(calls.filter(c => c.name === 'create_pos_sale')[0].args.p_payments === null, 'Default checkout should use server cash default');
  await draftSale();
  await page.getByRole('button', { name: 'Advanced payments', exact: true }).click();
  await page.getByLabel('Payment 1 amount').fill('1000');
  await page.getByRole('button', { name: 'Add payment', exact: true }).click();
  await page.getByLabel('Payment 2 wallet').selectOption(wallets[1].wallet_id);
  await page.getByLabel('Payment 2 amount').fill('1500');
  check(await page.getByRole('button', { name: 'Confirm', exact: true }).isDisabled(), 'Overpayment accepted by checkout');
  await page.getByLabel('Payment 2 amount').fill('500');
  await page.getByLabel('Payment 2 reference').fill('BK-SPLIT');
  await page.getByRole('dialog', { name: 'Confirm Sale', exact: true }).getByLabel('Browser receipt width', { exact: true }).selectOption('58');
  await page.getByLabel('58mm receipt preview').waitFor();
  for (const width of [390, 768, 1440]) {
    await page.setViewportSize({ width, height: 950 });
    check(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), `Checkout overflows at ${width}`);
    await page.screenshot({ path: `.temp/finance/checkout-${width}.png`, fullPage: true });
  }
  await page.getByRole('button', { name: 'Confirm', exact: true }).click();
  await page.getByText(/Saved retail sale/).waitFor();
  check(sales.length === 2 && sales[1].paid_amount === 1500 && sales[1].due === 800, 'Split partial checkout lost attribution');
  await page.goto(origin + '/?finance-fixtures=1#/finance');
  await page.getByRole('tab', { name: 'Customer dues', exact: true }).click();
  await page.getByRole('button', { name: 'Collect payment', exact: true }).click();
  await page.getByRole('button', { name: 'Pay remaining Tk 800.00', exact: true }).click();
  await page.getByLabel('Payment 1 wallet').selectOption(wallets[3].wallet_id);
  await page.getByRole('button', { name: 'Record payment', exact: true }).click();
  await page.getByRole('button', { name: 'Recover transaction', exact: true }).waitFor();
  await page.reload();
  await page.getByRole('button', { name: 'Recover transaction', exact: true }).click();
  await page.getByText('Previous transaction confirmed', { exact: true }).waitFor();
  await page.getByRole('tab', { name: 'Customer dues', exact: true }).click();
  await page.getByRole('heading', { name: 'No outstanding sales', exact: true }).waitFor();
  check(sales[1].due === 0 && sales[1].payments[2].wallet_id === wallets[3].wallet_id, 'Collection did not use selected bank');
  const collections = calls.filter(c => c.name === 'collect_sale_payment');
  check(collections.length === 2 && JSON.stringify(collections[0].args) === JSON.stringify(collections[1].args), 'Collection recovery changed the original request or payment attribution');
  check(errors.length === 0, errors.join('\n'));
  return { finance: 'desktop/tablet/mobile', ledger: 'bounded server pages and search', wallets: 'creation and transfer', checkout: 'default cash, split partial, overpayment rejection', receipt: '58mm preview', collection: 'selected bank, response-loss recovery after reload, no duplicate', errors };
}
