// Run with playwright-cli against a production Vite preview or the published site.
// All Auth/REST responses are isolated fixtures; no business writes or printing.
async page => {
  const origin = new URL(page.url()).origin;
  const scripts = [];
  const errors = [];
  page.on('request', request => {
    if (new URL(request.url()).pathname.endsWith('.js')) scripts.push(new URL(request.url()).pathname);
  });
  page.on('pageerror', error => errors.push(error.message));
  const check = (condition, message) => { if (!condition) throw Error(message); };
  const user = { id: 'be000000-0000-4000-8000-000000000001', aud: 'authenticated', role: 'authenticated',
    email: 'routes@example.invalid', app_metadata: {}, user_metadata: {}, created_at: new Date().toISOString() };
  await page.route('**/auth/v1/**', route => route.fulfill({ json: user }));
  await page.route('**/rest/v1/**', route => {
    const name = new URL(route.request().url()).pathname.split('/').pop();
    let data = [];
    if (name === 'user_profiles') data = [{ tenant_id: 'be000000-0000-4000-8000-000000000002', full_name: 'Route Operator', email: user.email, tenants: { business_name: 'Route verification' } }];
    else if (name === 'get_my_permissions') data = ['dashboard:view','pos:sell','sales:view','inventory:view','inventory:manage','customers:view','customers:manage','purchases:view','purchases:manage','employees:view','employees:manage','payroll:view','logistics:view','logistics:manage','gas_plants:view','gas_plants:manage','settings:manage','finance:view'];
    else if (name === 'get_dashboard_stats') data = { todayRevenue: 0, todayMovements: 0, totalCustomers: 0 };
    else if (name === 'get_customer_directory') data = { entries: [], total: 0 };
    else if (name === 'get_customer_overview') data = { wholesale: 0, retail: 0, new_wholesale: 0, new_retail: 0, inactive_wholesale: 0, inactive_retail: 0 };
    return route.fulfill({ json: data });
  });
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto(origin + '/?route-loading-anonymous=1#/pos');
  await page.getByRole('heading', { name: 'Sign in', exact: true }).waitFor();
  check(scripts.some(path => /\/LoginPage-/.test(path)), 'Login route was not split into an asset');
  check(!scripts.some(path => /\/(POS|Employees|Inventory|Purchases|Customers|Dashboard|Settings|Logistics|GasPlants|RegisterPage)-/.test(path)), 'Anonymous startup downloaded management routes');
  const anonymousScripts = [...new Set(scripts)];
  await page.getByRole('link', { name: 'Create a Business', exact: true }).click();
  await page.getByRole('heading', { name: 'Create your Business', exact: true }).waitFor();
  check(scripts.some(path => /\/RegisterPage-/.test(path)), 'Registration route did not load on navigation');
  const payload = btoa(JSON.stringify({ sub: user.id, exp: Math.floor(Date.now() / 1000) + 86400, aud: 'authenticated', role: 'authenticated' })).replaceAll('=', '').replaceAll('+', '-').replaceAll('/', '_');
  const token = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.' + payload + '.Zml4dHVyZQ';
  await page.context().addInitScript(({ user, token }) => {
    const session = JSON.stringify({ access_token: token, refresh_token: 'fixture', token_type: 'bearer', expires_in: 86400, expires_at: Math.floor(Date.now() / 1000) + 86400, user });
    for (const host of ['api', '127', 'localhost']) localStorage.setItem(`sb-${host}-auth-token`, session);
  }, { user, token });
  await page.goto(origin + '/?route-loading-authenticated=1#/pos');
  await page.locator('.pos-workspace').waitFor();
  check(!scripts.some(path => /\/Employees-/.test(path)), 'Unvisited employee route loaded early');
  await page.locator('.sidebar').evaluate(element => { element.dataset.routeLoadingTest = 'stable'; });
  let release, requested;
  const gate = new Promise(resolve => { release = resolve; });
  const started = new Promise(resolve => { requested = resolve; });
  await page.route('**/assets/Employees-*.js', async route => { requested(); await gate; await route.continue(); });
  await page.getByRole('navigation', { name: 'Primary navigation' }).getByRole('link', { name: 'Employees', exact: true }).click();
  await started;
  check(await page.locator('.sidebar[data-route-loading-test=stable]').isVisible(), 'Navigation unmounted during a delayed route load');
  check(await page.locator('.topbar').isVisible(), 'Header disappeared during a delayed route load');
  release();
  await page.locator('.employees-page').waitFor();
  const routes = [['/', '.dashboard-workspace'], ['/inventory', '.inv-overview-toolbar'], ['/customers', '.customers-page'],
    ['/employees', '.employees-page'], ['/finance', '.empty-state h2'], ['/purchases', '.purchases-page'],
    ['/logistics', '.inv-tabs'], ['/gas-plants', '.inv-stats-row'], ['/settings', '.settings-tabs'], ['/pos', '.pos-workspace']];
  for (const [path, selector] of routes) {
    await page.goto(origin + '/#' + path);
    await page.locator(selector).waitFor();
    await page.reload();
    await page.locator(selector).waitFor();
  }
  check(errors.length === 0, errors.join('\n'));
  return { anonymousScripts, protectedRoutes: routes.length, checks: 'anonymous guard, deferred route assets, shell retention during a delayed import, navigation and direct reloads', errors };
}
