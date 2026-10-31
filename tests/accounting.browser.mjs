// Intercepted UI acceptance. Financial correctness is tested separately in PostgreSQL.
import assert from 'node:assert/strict';
import { readFileSync, mkdirSync } from 'node:fs';
import { parseEnv } from 'node:util';
import { chromium } from 'playwright';
const base = process.env.LPG_BROWSER_BASE ?? 'http://127.0.0.1:5174';
const env = parseEnv(readFileSync('.env', 'utf8'));
const host = new URL(env.VITE_SUPABASE_URL).host;
const id = (n) => `ac000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const tenant = id(1);
const user = {
  id: id(2),
  email: 'accounting-ui@example.invalid',
  aud: 'authenticated',
  role: 'authenticated',
  app_metadata: {},
  user_metadata: {},
  created_at: new Date().toISOString(),
};
const token =
  'eyJhbGciOiJIUzI1NiJ9.' +
  Buffer.from(
    JSON.stringify({
      sub: user.id,
      exp: Math.floor(Date.now() / 1000) + 86400,
      role: 'authenticated',
    }),
  ).toString('base64url') +
  '.fixture';
const session = {
  access_token: token,
  refresh_token: 'fixture',
  expires_in: 86400,
  expires_at: Math.floor(Date.now() / 1000) + 86400,
  token_type: 'bearer',
  user,
};
const wallets = [
  {
    wallet_id: id(10),
    name: 'Cash Register',
    type: 'cash',
    kind: 'cash',
    balance: 5000,
  },
  {
    wallet_id: id(11),
    name: 'Primary Bank Account',
    type: 'dealership',
    kind: 'bank',
    balance: 25000,
  },
].map((w) => ({
  ...w,
  tenant_id: tenant,
  is_active: true,
  revision: 1,
  opening_balance: 0,
  details: '',
}));
const brands = [
  {
    tenant_id: tenant,
    brand_id: id(20),
    brand_name: 'Jamuna',
    is_active: true,
    display_order: 0,
  },
];
const item = {
  tenant_id: tenant,
  item_id: id(21),
  brand_id: id(20),
  size_kg: 12,
  mouth_size: '22mm',
  filled_quantity: 120,
  empty_quantity: 90,
  lpg_brands: brands[0],
};
const vehicle = {
  tenant_id: tenant,
  vehicle_id: id(30),
  name: 'Dhaka Delivery',
  serial_no: 'DHA-901',
  capacity: 200,
  status: 'idle',
  location: 'Home',
  revision: 1,
  driver_employee_id: id(31),
  driver_name: 'Fixture Driver',
  helper_employee_id: null,
  helper_name: null,
};
const cats = [
  'Engine Oil',
  'Spare Parts',
  'Trip Cost',
  'Road Permit Renewal',
  'Vehicle Tax',
  'Other Costs',
].map((name, i) => ({
  category_id: id(40 + i),
  name,
  is_active: true,
  revision: 1,
}));
let prices = ['refill', 'package'].map((type, i) => ({
  type,
  history_id: id(60 + i),
  price: i ? 3000 : 1200,
  automatic_price: i ? 3000 : 1200,
  is_manual: false,
  bottle_cost: i ? 2900 : 1100,
  overhead_per_unit: 100,
  commission_per_unit: 0,
  transport_per_unit: 50,
  purchase_id: id(70),
  received_at: '2026-10-20T10:00:00Z',
}));
let changes = [];
let services = [];
const calls = [];
const requests = new Map();
let loseSave = true;
const errors = [];
const browser = await chromium.launch({ channel: 'chrome', headless: true });
const context = await browser.newContext({
  viewport: { width: 1440, height: 1050 },
  acceptDownloads: true,
});
await context.addInitScript(
  ({ session, host }) =>
    localStorage.setItem(`sb-${host}-auth-token`, JSON.stringify(session)),
  { session, host },
);
const page = await context.newPage();
page.setDefaultTimeout(15_000);
page.on('pageerror', (e) => errors.push(e.stack));
mkdirSync('.temp/accounting', { recursive: true });
const report = (filters) => {
  const months = Array.from({ length: 12 }, (_, i) => {
    const revenue = 80000 + i * 9500;
    const expenses = 62000 + i * 7100;
    return {
      period: `2026-${String(i + 1).padStart(2, '0')}-01`,
      revenue,
      expenses,
      profit: revenue - expenses,
      cash_in: revenue - 5000,
      cash_out: expenses + 1000,
      cash_flow: revenue - expenses - 6000,
      purchases: expenses - 10000,
      unvalued_units: 0,
    };
  });
  const totals = months.reduce(
    (a, t) => {
      for (const k of [
        'revenue',
        'expenses',
        'cash_in',
        'cash_out',
        'cash_flow',
        'purchases',
      ])
        a[k] += t[k];
      return a;
    },
    {
      revenue: 0,
      expenses: 0,
      cash_in: 0,
      cash_out: 0,
      cash_flow: 0,
      purchases: 0,
    },
  );
  return {
    generated_at: '2026-10-31T04:00:00Z',
    from: filters.from,
    to: filters.to,
    grain: filters.grain,
    totals: {
      ...totals,
      profit: totals.revenue - totals.expenses,
      known_profit: totals.revenue - totals.expenses,
      sales_count: 240,
      unvalued_units: 0,
      reconstructed_units: 20,
      margin: 24.6,
    },
    trend: months,
    categories: [
      { category: 'Cost of goods sold', amount: 650000 },
      { category: 'Employee salaries', amount: 100000 },
      { category: 'Transit: Driver earnings', amount: 70000 },
      { category: 'Vehicle service: Engine Oil', amount: 20000 },
      { category: 'Spending: Business', amount: 10000 },
    ],
    cash_categories: [
      { category: 'Actual wallet payments', amount: 800000 },
      { category: 'Owner withdrawals', amount: 20000 },
    ],
    inventory: {
      known_value: 595000,
      filled_value: 405000,
      empty_value: 190000,
      unvalued_units: 0,
      inverted_products: 0,
      reconstructed_products: 2,
    },
    current_inventory: { known_value: 605000, unvalued_units: 0 },
    inventory_trend: months.map((m, i) => ({
      period: m.period,
      known_value: 240000 + i * 32000,
      unvalued_units: i === 0 ? 5 : 0,
    })),
    businesses: [
      {
        tenant_id: tenant,
        business_name: 'LPG Accounting Demo',
        revenue: totals.revenue,
        expenses: totals.expenses,
        cash_flow: totals.cash_flow,
        profit: totals.revenue - totals.expenses,
        unvalued_units: 0,
      },
    ],
    vehicles: [
      {
        tenant_id: tenant,
        vehicle_id: vehicle.vehicle_id,
        vehicle_name: vehicle.name,
        revenue: 90000,
        expenses: 65000,
        service_expenses: 20000,
      },
    ],
    logistics: {
      revenue: 90000,
      internal_revenue: 60000,
      expenses: 45000,
      outstanding: 1200,
    },
  };
};
await page.route('**/auth/v1/**', (route) => route.fulfill({ json: user }));
await page.route('**/rest/v1/**', async (route) => {
  const req = route.request();
  const url = new URL(req.url());
  const name = url.pathname.split('/').pop();
  const args = req.method() === 'POST' ? req.postDataJSON() : {};
  calls.push({ name, args });
  let data = [];
  if (name === 'user_profiles')
    data = [
      {
        tenant_id: tenant,
        email: user.email,
        full_name: 'Fixture Owner',
        tenants: { business_name: 'LPG Accounting Demo' },
      },
    ];
  else if (name === 'get_my_permissions')
    data = [
      'finance:view',
      'finance:manage',
      'inventory:view',
      'inventory:manage',
      'logistics:view',
      'logistics:manage',
      'settings:manage',
      'employees:view',
      'payroll:view',
      'payroll:pay',
    ];
  else if (name === 'get_my_preferences') data = { theme: 'light' };
  else if (name === 'get_business_catalogs') data = {roles:[],weights:[{size_kg:12,active:true,assigned:1}]};
  else if (name === 'wallets') data = wallets;
  else if (name === 'get_payment_wallets') data = wallets;
  else if (name === 'get_financial_activity') data = { entries: [], total: 0 };
  else if (name === 'get_analysis_businesses')
    data = [
      { tenant_id: tenant, business_name: 'LPG Accounting Demo' },
      { tenant_id: id(3), business_name: 'Second authorized business' },
    ];
  else if (name === 'get_finance_analysis') data = report(args.p_filters);
  else if (name === 'get_analysis_details')
    data = {
      entries: [
        {
          tenant_id: tenant,
          business_name: 'LPG Accounting Demo',
          occurred_on: '2026-10-21',
          metric: args.p_metric,
          category: args.p_category ?? 'Product sales',
          amount: 12000,
          source: 'purchase',
          source_id: id(70),
          description: 'Auditable source record',
        },
      ],
      total: 25,
    };
  else if (name === 'items') data = [item];
  else if (name === 'list_lpg_brands' || name === 'lpg_brands') data = brands;
  else if (name === 'get_inventory_valuation')
    data = {
      known_value: 522000,
      filled_value: 360000,
      empty_value: 162000,
      unvalued_units: 0,
      inverted_products: 0,
    };
  else if (name === 'get_product_inventory')
    data = {
      can_manage_prices: true,
      commission: { refill_rate: 0, package_rate: 0, version: null },
      prices: [],
      buying_prices: prices,
      weeks: [],
    };
  else if (name === 'get_buying_price_history')
    data = {
      entries: changes.slice(args.p_offset, args.p_offset + args.p_limit),
      total: changes.length,
    };
  else if (name === 'set_product_buying_price') {
    if (!requests.has(args.p_request_id)) {
      const p = args.p_payload;
      const old = prices.find((x) => x.type === p.price_type);
      const next = {
        ...old,
        price: p.is_manual ? p.price : old.automatic_price,
        is_manual: p.is_manual,
        history_id: id(80 + changes.length),
      };
      prices = prices.map((x) => (x === old ? next : x));
      changes.unshift({
        history_id: next.history_id,
        price_type: p.price_type,
        previous_price: old.price,
        new_price: next.price,
        automatic_price: next.automatic_price,
        is_manual: p.is_manual,
        source: p.is_manual ? 'manual' : 'restore_automatic',
        reason: p.reason,
        effective_at: new Date().toISOString(),
        recorded_at: new Date().toISOString(),
        actor: 'Fixture Owner',
        reconstructed: false,
        purchase_id: id(70),
      });
      requests.set(args.p_request_id, { history_id: next.history_id });
    }
    data = requests.get(args.p_request_id);
  } else if (name === 'get_vehicle_directory')
    data = { entries: [vehicle], total: 1 };
  else if (name === 'get_vehicle') data = vehicle;
  else if (name === 'get_logistics_summary')
    data = {
      vehicles: 1,
      home: 1,
      transits: 3,
      active: 0,
      awaiting_completion: 0,
      earnings: 1000,
      paid: 1000,
      outstanding: 0,
      transport_fees: 9000,
      operating_costs: 5000,
      expense_outstanding: 0,
      profit: 4000,
      service_expenses: 300,
    };
  else if (name === 'get_vehicle_expense_categories') data = cats;
  else if (name === 'get_service_trip_directory')
    data = { entries: services, total: services.length };
  else if (name === 'get_service_trip')
    data = services.find((s) => s.service_trip_id === args.p_service_trip_id);
  else if (name === 'get_service_trip_activity')
    data = { entries: [], total: 0 };
  else if (name === 'get_operating_payments') data = { entries: [], total: 0 };
  else if (name === 'save_service_trip') {
    if (!requests.has(args.p_request_id)) {
      const p = args.p_payload;
      const cost = p.expenses.reduce((s, e) => s + e.amount, 0);
      const row = {
        ...p,
        service_trip_id: id(90),
        vehicle_name: vehicle.name,
        expenses: p.expenses.map((e) => ({
          ...e,
          category_name: cats.find((c) => c.category_id === e.category_id).name,
        })),
        total_cost: cost,
        paid: 0,
        outstanding: cost,
        advance: 0,
        revision: 1,
        finalized_at: null,
        created_at: new Date().toISOString(),
      };
      services = [row];
      requests.set(args.p_request_id, { service_trip_id: row.service_trip_id });
    }
    if (loseSave) {
      loseSave = false;
      return route.abort('connectionreset');
    }
    data = requests.get(args.p_request_id);
  } else if (
    name === 'get_transit_directory' ||
    name === 'get_vehicle_assignments'
  )
    data = { entries: [], total: 0 };
  await route.fulfill({ json: data });
});
try {
  await page.goto(base + '/#/finance');
  await page.getByRole('tab', { name: 'Analysis', exact: true }).click();
  await page.getByRole('heading', { name: 'Business performance' }).waitFor();
  await page.getByText('Earnings over time', { exact: true }).waitFor();
  for (const width of [1440, 768, 390, 320]) {
    await page.setViewportSize({ width, height: 1000 });
    assert(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= innerWidth + 1,
      ),
      `Analysis overflows at ${width}`,
    );
    await page.screenshot({
      path: `.temp/accounting/analysis-${width}.png`,
      fullPage: true,
    });
  }
  await page.setViewportSize({ width: 1440, height: 1050 });
  await page
    .getByRole('button', { name: 'Revenue earned', exact: false })
    .first()
    .click();
  const detail = page.getByRole('dialog');
  await detail.getByText('Auditable source record', { exact: true }).waitFor();
  await detail.getByRole('button', { name: 'Next page', exact: true }).click();
  assert(
    calls.some(
      (c) => c.name === 'get_analysis_details' && c.args.p_offset === 12,
    ),
  );
  await detail.getByRole('button', { name: 'Close', exact: true }).click();
  const download = page.waitForEvent('download');
  await page
    .getByRole('button', { name: 'Download Analysis as PDF', exact: true })
    .click();
  await (await download).saveAs('.temp/accounting/analysis.pdf');
  assert(
    readFileSync('.temp/accounting/analysis.pdf').subarray(0, 4).toString() ===
      '%PDF',
  );
  await Promise.all([
    page.waitForResponse((r) => r.url().endsWith('/rpc/get_finance_analysis')),
    page.getByLabel('Business', { exact: true }).selectOption(''),
  ]);
  assert(
    calls.filter((c) => c.name === 'get_finance_analysis').at(-1).args.p_filters
      .business_id === '',
  );
  await page.goto(base + '/#/inventory');
  await page.locator('button.inv-tile').filter({hasText:'Jamuna'}).first().click();
  await page.getByRole('button', { name: 'Edit refill buying price' }).click();
  let dialog = page.getByRole('dialog').last();
  await dialog.getByLabel('Buying price (Tk)').fill('1250');
  await dialog
    .getByLabel('Reason', { exact: true })
    .fill('UI verified manual override');
  await dialog
    .getByRole('button', { name: 'Save buying price', exact: true })
    .click();
  await page.getByText('Manual override', { exact: true }).waitFor();
  await page
    .getByRole('button', { name: 'Buying Price History', exact: true })
    .click();
  dialog = page.getByRole('dialog').last();
  await dialog
    .getByText('UI verified manual override', { exact: true })
    .waitFor();
  await dialog.screenshot({ path: '.temp/accounting/buying-history.png' });
  await dialog.getByRole('button', { name: 'Close', exact: true }).click();
  await page.getByLabel('Close product details').click();
  await page.goto(base + '/#/logistics');
  await page.getByRole('button', { name: /Dhaka Delivery.*DHA-901/ }).click();
  dialog = page.getByRole('dialog');
  await dialog
    .getByRole('button', { name: 'Service trips', exact: true })
    .click();
  await dialog
    .getByRole('button', { name: 'Service trip', exact: true })
    .click();
  dialog = page.getByRole('dialog').last();
  await dialog.getByLabel('Title', { exact: true }).fill('UI maintenance trip');
  await dialog
    .getByRole('button', { name: 'Add expense', exact: true })
    .click();
  await dialog.getByLabel('Amount (Tk)', { exact: true }).fill('300');
  await dialog
    .getByLabel('Description (optional)')
    .fill('Engine oil replacement');
  await dialog
    .getByRole('button', { name: 'Review service trip', exact: true })
    .click();
  dialog = page.getByRole('dialog').last();
  await dialog
    .getByRole('button', { name: 'Save service trip', exact: true })
    .click();
  await page
    .getByRole('button', { name: 'Recover service change', exact: true })
    .first()
    .waitFor();
  await page.getByRole('button', { name: 'Go back', exact: true }).click();
  await page
    .getByRole('button', { name: 'Recover service change', exact: true })
    .click();
  await page
    .getByRole('heading', { name: 'Vehicle service trip', exact: true })
    .waitFor();
  assert(services.length === 1);
  const saves = calls.filter((c) => c.name === 'save_service_trip');
  assert(
    saves.length === 2 &&
      saves[0].args.p_request_id === saves[1].args.p_request_id,
    'Service recovery must keep original request',
  );
  await page.setViewportSize({ width: 390, height: 900 });
  await page
    .getByRole('dialog')
    .last()
    .screenshot({ path: '.temp/accounting/service-trip.png' });
  assert(errors.length === 0, errors.join('\n'));
  console.log(
    'PASS: Analysis 320–1440px, scoped filters, server drill-down paging, real PDF download, owner buying price/history, service editing and lost-response recovery',
  );
} catch (error) {
  console.error('Browser errors:',errors);
  console.error('Visible page:',await page.locator('body').innerText());
  await page.screenshot({
    path: '.temp/accounting/failure.png',
    fullPage: true,
  });
  console.error(error);
  process.exitCode = 1;
} finally {
  await browser.close();
}
