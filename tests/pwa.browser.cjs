// Run with playwright-cli in a fresh --persistent profile against a production preview or published site.
// Chromium refuses installation in incognito profiles. All Auth/REST calls below are fixtures.
async page => {
  const origin = new URL(page.url()).origin;
  const check = (condition, message) => { if (!condition) throw new Error(message); };
  const client = await page.context().newCDPSession(page);
  await page.goto(origin + '/#/login');
  await page.getByRole('heading', { name: 'Sign in', exact: true }).waitFor();
  const parsed = await client.send('Page.getAppManifest');
  check(parsed.url === origin + '/manifest.webmanifest', 'Manifest URL is not stable at the origin root');
  check(parsed.errors.length === 0, JSON.stringify(parsed.errors));
  const manifest = JSON.parse(parsed.data);
  check(manifest.display === 'standalone', 'Standalone display was lost');
  for (const key of ['id', 'start_url', 'scope']) check(new URL(manifest[key], parsed.url).href === origin + '/', `Unexpected ${key}`);
  const installability = await client.send('Page.getInstallabilityErrors');
  check(installability.installabilityErrors.length === 0, JSON.stringify(installability.installabilityErrors));
  for (const icon of manifest.icons) {
    const dimensions = await page.evaluate(async icon => {
      const image = new Image();
      image.src = icon.src;
      await image.decode();
      return `${image.naturalWidth}x${image.naturalHeight}`;
    }, icon);
    check(dimensions === icon.sizes, 'Install icon dimensions mismatch');
  }
  await page.getByRole('link', { name: 'Create a Business', exact: true }).click();
  await page.getByRole('heading', { name: 'Create your Business', exact: true }).waitFor();
  await page.reload();
  await page.getByRole('heading', { name: 'Create your Business', exact: true }).waitFor();
  const current = new URL(page.url());
  check(current.origin === origin && current.pathname === '/', 'Auth navigation escaped root scope');
  const workers = await page.evaluate(async () => (await navigator.serviceWorker.getRegistrations()).length);
  check(workers === 0, 'Unexpected service worker controls this app');
  const user = { id: 'be000000-0000-4000-8000-000000000001', aud: 'authenticated', role: 'authenticated', email: 'pwa@example.invalid', app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() };
  const payload = btoa(JSON.stringify({ sub: user.id, exp: Math.floor(Date.now() / 1000) + 86400, aud: 'authenticated', role: 'authenticated' })).replaceAll('=', '').replaceAll('+', '-').replaceAll('/', '_');
  const session = { access_token: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.' + payload + '.Zml4dHVyZQ', refresh_token: 'fixture', token_type: 'bearer', expires_in: 86400, user };
  const routes = [['/', 'Dashboard'], ['/inventory', 'Inventory'], ['/pos', 'Point of Sale'], ['/sales', 'Sales'], ['/purchases', 'Purchases'], ['/customers', 'Customers'], ['/employees', 'Employees'], ['/finance', 'Finance'], ['/logistics', 'Logistics'], ['/gas-plants', 'Gas Plants'], ['/settings', 'Settings']];
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.route('**/auth/v1/**', route => route.fulfill({ json: route.request().url().includes('/token') ? session : user }));
  await page.route('**/rest/v1/**', route => {
    const name = new URL(route.request().url()).pathname.split('/').pop();
    let data = [];
    if (name === 'user_profiles') data = [{ tenant_id: 'be000000-0000-4000-8000-000000000002', full_name: 'PWA Operator', email: user.email, tenants: { business_name: 'PWA fixture' } }];
    else if(name==='get_my_preferences')data={theme:null};
    else if(name==='get_business_catalogs')data={roles:['Owner','Manager','Salesman','Driver','Helper','General Staff'].map((name,i)=>({id:String(i),name,active:true,system:true,assigned:0})),weights:[5,12,25,35].map(size_kg=>({size_kg,active:true,assigned:0}))};
    else if (name === 'get_my_permissions') data = ['dashboard:view', 'pos:sell', 'sales:view', 'inventory:view', 'customers:view', 'purchases:view', 'employees:view', 'logistics:view', 'gas_plants:view', 'settings:manage', 'finance:view'];
    else if (name === 'get_dashboard_snapshot') data={date:new Date().toISOString().slice(0,10),finance_visible:false,days:[],sales:[],bottles:[],stove_types:[],attention:{},activity:{entries:[],hasMore:false}};
    else if (['get_customer_directory', 'get_sales_directory', 'get_purchase_directory', 'get_wallet_ledger'].includes(name)) data = { entries: [], total: 0, received: 0, paid_out: 0 };
    else if (name === 'get_sales_overview') data = { total: 0, amount: 0, due: 0, bottles: 0 };
    else if (name === 'get_customer_overview') data = { wholesale: 0, retail: 0, new_wholesale: 0, new_retail: 0, inactive_wholesale: 0, inactive_retail: 0 };
    return route.fulfill({ json: data });
  });
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto(origin + '/#/pos');
  await page.getByRole('heading', { name: 'Sign in', exact: true }).waitFor();
  check(new URL(page.url()).hash === '#/login', 'Anonymous guard did not use an in-scope hash redirect');
  await page.getByLabel('Email Address', { exact: true }).fill(user.email);
  await page.getByLabel('Password', { exact: true }).fill('fixture-password');
  await page.getByRole('button', { name: 'Sign In', exact: true }).click();
  await page.locator('.topbar-page-title').filter({ hasText: /^Dashboard$/ }).waitFor();
  for (const [path, label] of routes) {
    await page.getByRole('navigation', { name: 'Primary navigation' }).getByRole('link', { name: label, exact: true }).click();
    await page.locator('.topbar-page-title').filter({ hasText: new RegExp(`^${label}$`) }).waitFor();
    await page.reload();
    await page.locator('.topbar-page-title').filter({ hasText: new RegExp(`^${label}$`) }).waitFor();
    check(page.url() === origin + '/#' + path, `${label} escaped root scope on navigation/reload`);
    const currentManifest = await client.send('Page.getAppManifest');
    check(currentManifest.url === parsed.url && currentManifest.errors.length === 0, `${label} lost the manifest on reload`);
  }
  await page.getByRole('button', { name: 'Account: PWA Operator', exact: true }).click();
  await page.getByRole('menuitem', { name: 'Sign Out', exact: true }).click();
  await page.getByRole('heading', { name: 'Sign in', exact: true }).waitFor();
  check(page.url() === origin + '/#/login', 'Sign-out escaped root scope');
  check(errors.length === 0, errors.join('\n'));
  await client.detach();
  return { manifestURL: parsed.url, display: manifest.display, installabilityErrors: installability.installabilityErrors, icons: manifest.icons.length, serviceWorkers: workers, protectedRoutes: routes.length, checks: 'Chromium manifest processing/installability, icon decoding, guard/login/logout, registration, all workspace navigation and reloads with API fixtures', errors };
}
