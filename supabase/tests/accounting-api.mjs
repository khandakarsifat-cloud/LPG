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
const tables = [
  'items',
  'inventory_movements',
  'sales',
  'sale_items',
  'sale_payments',
  'customer_transactions',
  'purchases',
  'purchase_items',
  'purchase_payments',
  'purchase_refund_obligations',
  'purchase_activity',
  'wallets',
  'wallet_transactions',
  'employees',
  'employee_terms',
  'employee_payments',
  'employee_payment_entries',
  'vehicles',
  'vehicle_assignments',
  'transits',
  'vehicle_service_trips',
  'operating_cost_events',
  'operating_payments',
  'service_trip_activity',
  'product_buying_price_history',
  'sale_cost_evidence',
  'inventory_valuation_baselines',
  'financial_source_archive',
  'business_analysis_access',
];
const preservation =
  'select jsonb_build_array(' +
  tables
    .map(
      (t) =>
        `(select md5(coalesce(jsonb_agg(to_jsonb(r) order by to_jsonb(r)::text)::text,'')) from public.${t} r)`,
    )
    .join(',') +
  ');';
const before = sql(preservation);
const clients = [],
  users = [],
  tenants = [];
let browser;
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
      p_business_name: 'Accounting API fixture ' + label + ' ' + randomUUID(),
      p_owner_name: 'Accounting acceptance operator',
    }),
  );
  tenants.push(b.tenant_id);
  return { c, user: auth.user, session: auth.session, tenant: b.tenant_id };
}
try {
  const burner = client();
  const auth = await checked(
    burner.auth.signInWithPassword({
      email: secret.LPG_TEST_EMAIL,
      password: secret.LPG_TEST_PASSWORD,
    }),
  );
  const membership = await checked(
    burner
      .from('user_profiles')
      .select('tenant_id,is_active')
      .eq('user_id', auth.user.id)
      .single(),
  );
  assert(membership.is_active && membership.tenant_id);
  console.log(
    'PASS: VPS/Worker target and retained burner membership verified read-only',
  );
  const owner = await account('owner'),
    foreign = await account('foreign');
  const c = owner.c;
  const rpc = (name, args = {}) =>
    checked(c.rpc(name, args)).catch((error) => {
      throw new Error(`${name}: ${error.message}`);
    });
  const today = new Intl.DateTimeFormat('sv-SE', {
    timeZone: 'Asia/Dhaka',
  }).format(new Date());
  const driver = (
    await rpc('save_employee', {
      p_payload: {
        name: 'Acceptance Driver',
        employee_type_name: 'Driver',
        business_unit: 'truck_business',
        phones: [{ phone: '01700000951', is_primary: true }],
        terms: { monthly_salary: 0, effective_from: today, is_active: true },
      },
      p_request_id: randomUUID(),
    })
  ).employee_id;
  const vehicle = (
    await rpc('save_vehicle', {
      p_payload: {
        name: 'Accounting acceptance vehicle',
        serial_no: 'ACC-LIVE-' + randomUUID().slice(0, 6),
        capacity: 0,
        driver_employee_id: driver,
      },
      p_request_id: randomUUID(),
    })
  ).vehicle_id;
  const brand = (
    await rpc('create_lpg_brand', {
      p_brand_name: 'Acceptance LPG ' + randomUUID().slice(0, 6),
      p_description: 'Disposable accounting fixture',
    })
  ).brand_id;
  const plant = (
    await rpc('create_gas_plant', {
      p_plant_name: 'Acceptance plant',
      p_brand_id: brand,
      p_location: 'Dhaka',
    })
  ).plant_id;
  const item = await checked(
    c
      .from('items')
      .insert({
        tenant_id: owner.tenant,
        brand_id: brand,
        size_kg: 12,
        mouth_size: '22mm',
      })
      .select('item_id')
      .single(),
  );
  const openingPrice = await rpc('set_product_buying_price', {
    p_payload: {
      item_id: item.item_id,
      price_type: 'refill',
      is_manual: true,
      price: 100,
      reason: 'Opening price before receipt evidence',
    },
    p_request_id: randomUUID(),
  });
  const missingAutomatic = await c.rpc('set_product_buying_price', {
    p_payload: {
      item_id: item.item_id,
      price_type: 'refill',
      is_manual: false,
      expected: openingPrice.history_id,
      reason: 'Reject missing automatic evidence',
    },
    p_request_id: randomUUID(),
  });
  assert.match(
    missingAutomatic.error?.message ?? '',
    /No automatic buying price/,
  );
  const wallets = await rpc('get_payment_wallets');
  assert(wallets.every((w) => w.kind !== 'logistics'));
  const cash = wallets.find((w) => w.type === 'cash').wallet_id,
    bank = wallets.find((w) => w.type === 'dealership').wallet_id;
  const purchase = (
    await rpc('create_purchase', {
      p_payload: {
        request_id: randomUUID(),
        plant_id: plant,
        vehicle_id: vehicle,
        transport_cost: 200,
        labour_cost: 100,
        commission: 0,
        items: [
          {
            item_id: item.item_id,
            type: 'package',
            quantity: 20,
            empty_dispatched: 0,
            unit_price: 300,
          },
        ],
      },
    })
  ).purchase_id;
  await rpc('dispatch_purchase', { p_purchase_id: purchase, p_revision: 1 });
  assert.equal(
    (await checked(c.from('wallets').select('balance'))).reduce(
      (s, w) => s + Number(w.balance),
      0,
    ),
    0,
  );
  await rpc('receive_purchase', { p_purchase_id: purchase, p_revision: 2 });
  let p = await rpc('get_product_inventory', { p_item_id: item.item_id });
  assert.equal(p.buying_prices.find((x) => x.type === 'package').price, 315);
  const paymentKey = randomUUID(),
    purchasePayments = [
      { wallet_id: cash, amount: 1000 },
      { wallet_id: bank, amount: 5100 },
    ];
  const paid = await rpc('record_purchase_payment', {
    p_purchase_id: purchase,
    p_payments: purchasePayments,
    p_request_id: paymentKey,
  });
  assert.deepEqual(
    await rpc('record_purchase_payment', {
      p_purchase_id: purchase,
      p_payments: purchasePayments,
      p_request_id: paymentKey,
    }),
    paid,
  );
  assert.equal(paid.due, 0);
  const transit = (
    await rpc('create_custom_transit', {
      p_payload: {
        vehicle_id: vehicle,
        fee: 1000,
        client_name: 'Acceptance external client',
        destination: 'Dhaka',
      },
      p_request_id: randomUUID(),
    })
  ).transit_id;
  await rpc('save_transit_costs', {
    p_transit_id: transit,
    p_revision: 1,
    p_costs: {
      driver_cost: 200,
      helper_cost: 0,
      oil_cost: 100,
      others_cost: 0,
      additional_costs: [],
    },
  });
  const operating = (payload) =>
    rpc('record_operating_payment', {
      p_payload: { payment_date: today, ...payload },
      p_request_id: randomUUID(),
    });
  await operating({
    transit_id: transit,
    kind: 'expense',
    payments: [
      { wallet_id: cash, amount: 40 },
      { wallet_id: bank, amount: 60 },
    ],
  });
  await rpc('employee_payment_operation', {
    p_payload: {
      action: 'pay',
      items: [
        {
          employee_id: driver,
          kind: 'trips',
          trip_count: 1,
          transit_id: transit,
          trip_role: 'driver',
          payment_date: today,
          payments: [
            { wallet_id: cash, amount: 100 },
            { wallet_id: bank, amount: 100 },
          ],
        },
      ],
    },
    p_request_id: randomUUID(),
  });
  await operating({
    transit_id: transit,
    kind: 'client_receipt',
    payments: [
      { wallet_id: cash, amount: 400 },
      { wallet_id: bank, amount: 600 },
    ],
  });
  let tr = await rpc('get_transit', { p_transit_id: transit });
  assert.equal(tr.profit, 700);
  assert.equal(tr.outstanding, 0);
  await rpc('transition_transit', {
    p_transit_id: transit,
    p_action: 'complete',
    p_revision: tr.revision,
  });
  const category = (await rpc('get_vehicle_expense_categories')).find(
    (x) => x.name === 'Engine Oil',
  ).category_id;
  const service = (
    await rpc('save_service_trip', {
      p_payload: {
        vehicle_id: vehicle,
        title: 'Acceptance oil service',
        service_date: today,
        expenses: [
          {
            category_id: category,
            amount: 300,
            description: 'Grouped vehicle maintenance',
          },
        ],
      },
      p_request_id: randomUUID(),
    })
  ).service_trip_id;
  await operating({
    service_trip_id: service,
    kind: 'expense',
    payments: [
      { wallet_id: cash, amount: 200 },
      { wallet_id: bank, amount: 50 },
    ],
  });
  const advance = await operating({
    service_trip_id: service,
    kind: 'expense',
    payments: [{ wallet_id: cash, amount: 100 }],
  });
  let svc = await rpc('get_service_trip', { p_service_trip_id: service });
  assert.equal(svc.advance, 50);
  assert(
    (
      await c.rpc('finalize_service_trip', {
        p_service_trip_id: service,
        p_revision: svc.revision,
        p_request_id: randomUUID(),
      })
    ).error,
  );
  await operating({
    service_trip_id: service,
    kind: 'expense_return',
    return_of: advance.payment_ids[0],
    payments: [{ wallet_id: cash, amount: 50 }],
  });
  svc = await rpc('get_service_trip', { p_service_trip_id: service });
  await rpc('finalize_service_trip', {
    p_service_trip_id: service,
    p_revision: svc.revision,
    p_request_id: randomUUID(),
  });
  let current = p.buying_prices.find((x) => x.type === 'package');
  await rpc('set_product_buying_price', {
    p_payload: {
      item_id: item.item_id,
      price_type: 'package',
      expected: current.history_id,
      is_manual: true,
      price: 400,
      reason: 'Acceptance manual override',
    },
    p_request_id: randomUUID(),
  });
  await rpc('set_product_commissions', {
    p_item_id: item.item_id,
    p_refill_rate: 5,
    p_package_rate: 15,
    p_expected: null,
  });
  p = await rpc('get_product_inventory', { p_item_id: item.item_id });
  current = p.buying_prices.find((x) => x.type === 'package');
  assert.equal(current.price, 400);
  assert.equal(current.automatic_price, 300);
  assert(current.is_manual);
  await rpc('save_product_prices', {
    p_item_id: item.item_id,
    p_customer_tier: 'retail',
    p_prices: {
      refill: { price: 500, mrp: null },
      package: { price: 1000, mrp: null },
    },
    p_expected: { refill: null, package: null },
  });
  // Package checkout intentionally consumes one empty as well as one filled
  // unit in the existing stock model. Establish only this fixture's opening empty.
  await rpc('create_inventory_movement', {
    p_item_id: item.item_id,
    p_movement_type: 'adjust_gain',
    p_filled_quantity_change: 0,
    p_empty_quantity_change: 1,
    p_notes: 'Disposable accounting acceptance opening empty',
  });
  const sale = await rpc('create_pos_sale', {
    p_customer_phone: '01700000959',
    p_customer_name: 'Acceptance retail customer',
    p_customer_shop_name: null,
    p_customer_address: null,
    p_customer_tier: 'retail',
    p_discount_amount: 0,
    p_exchange_fee: 0,
    p_notes: 'Disposable cost-evidence sale',
    p_items: [
      { item_id: item.item_id, type: 'package', quantity: 1, unit_price: 1000 },
    ],
    p_customer_id: null,
    p_payments: [],
    p_bottles: null,
    p_request_id: randomUUID(),
  });
  await rpc('collect_sale_payment', {
    p_sale_id: sale.sale_id,
    p_payments: [{ wallet_id: cash, amount: 500 }],
    p_request_id: randomUUID(),
  });
  const filters = {
    from: today,
    to: today,
    grain: 'day',
    business_id: owner.tenant,
  };
  let report = await rpc('get_finance_analysis', { p_filters: filters });
  assert.equal(report.totals.revenue, 2000);
  assert.equal(report.totals.expenses, 990);
  assert.equal(report.totals.profit, 1010);
  assert.equal(report.totals.cash_flow, -5200);
  assert.equal(report.inventory.known_value, 7600);
  assert.equal(report.vehicles[0].service_expenses, 300);
  assert.equal(report.vehicles[0].expenses, 600);
  assert.equal(
    (
      await rpc('get_analysis_details', {
        p_filters: filters,
        p_metric: 'expense',
        p_category: null,
        p_offset: 0,
        p_limit: 1,
      })
    ).entries.length,
    1,
  );
  assert(
    (await foreign.c.rpc('get_finance_analysis', { p_filters: filters })).error,
  );
  await rpc('grant_business_analysis_access', {
    p_user_id: foreign.user.id,
    p_grant: true,
  });
  const combined = await checked(
    foreign.c.rpc('get_finance_analysis', {
      p_filters: { ...filters, business_id: '' },
    }),
  );
  assert.equal(combined.businesses.length, 2);
  assert.equal(combined.totals.profit, 1010);
  await rpc('grant_business_analysis_access', {
    p_user_id: foreign.user.id,
    p_grant: false,
  });
  assert(
    (await foreign.c.rpc('get_finance_analysis', { p_filters: filters })).error,
  );
  console.log(
    'PASS: real purchase allocations, unpaid receipt price, split settlements, custom revenue/crew costs, service advance/return, overrides, historical sale cost, analytics and multi-business authorization',
  );
  if (process.argv.includes('--browser')) {
    mkdirSync('.temp/accounting', { recursive: true });
    browser = await chromium.launch({ channel: 'chrome', headless: true });
    const context = await browser.newContext({
      viewport: { width: 1440, height: 1050 },
      acceptDownloads: true,
    });
    await context.addInitScript(
      ({ session }) =>
        localStorage.setItem(
          'sb-api.lpg.144.79.249.4.sslip.io-auth-token',
          JSON.stringify(session),
        ),
      { session: owner.session },
    );
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror', (e) => errors.push(e.message));
    await page.goto(worker + '/#/finance');
    await page.getByRole('tab', { name: 'Analysis', exact: true }).click();
    await page
      .getByRole('heading', { name: 'Earnings over time', exact: true })
      .waitFor();
    for (const width of [1440, 768, 390, 320]) {
      await page.setViewportSize({ width, height: 1000 });
      assert(
        await page.evaluate(
          () => document.documentElement.scrollWidth <= innerWidth + 1,
        ),
        `Live Analysis overflow ${width}`,
      );
      await page.screenshot({
        path: `.temp/accounting/live-analysis-${width}.png`,
      });
    }
    const downloading = page.waitForEvent('download');
    await page
      .getByRole('button', { name: 'Download Analysis as PDF', exact: true })
      .click();
    await (await downloading).saveAs('.temp/accounting/live-analysis.pdf');
    await page.setViewportSize({ width: 1440, height: 1000 });
    await page.goto(worker + '/#/inventory');
    await page
      .locator('button.inv-tile')
      .filter({ hasText: 'Acceptance LPG' })
      .click();
    await page
      .getByRole('button', { name: 'Edit refill buying price', exact: true })
      .click();
    assert(
      await page
        .getByRole('dialog')
        .last()
        .getByRole('option', {
          name: 'Restore automatic calculation',
          exact: true,
        })
        .evaluate((option) => option.disabled),
      'Restore automatic calculation must be disabled without receipt evidence',
    );
    await page
      .getByRole('dialog')
      .last()
      .getByRole('button', { name: 'Cancel', exact: true })
      .click();
    await page
      .getByRole('button', { name: 'Edit package buying price', exact: true })
      .click();
    let dialog = page.getByRole('dialog').last();
    await dialog.getByLabel('Buying price (Tk)').fill('450');
    await dialog
      .getByLabel('Reason', { exact: true })
      .fill('Published UI manual adjustment');
    await dialog
      .getByRole('button', { name: 'Save buying price', exact: true })
      .click();
    await page
      .getByRole('button', { name: 'Buying Price History', exact: true })
      .click();
    dialog = page.getByRole('dialog').last();
    await dialog
      .getByText('Published UI manual adjustment', { exact: true })
      .waitFor();
    await dialog.getByRole('button', { name: 'Close', exact: true }).click();
    await page.getByLabel('Close product details').click();
    await page.goto(worker + '/#/logistics');
    await page
      .getByRole('button', { name: /Accounting acceptance vehicle.*ACC-LIVE/ })
      .click();
    dialog = page.getByRole('dialog');
    await dialog
      .getByRole('button', { name: 'Service trips', exact: true })
      .click();
    await dialog
      .getByRole('button', { name: /Acceptance oil service/ })
      .click();
    await page
      .getByRole('heading', { name: 'Vehicle service trip', exact: true })
      .waitFor();
    await page
      .getByRole('dialog')
      .last()
      .getByText(`${today} · Finalized`, { exact: true })
      .waitFor();
    assert.deepEqual(errors, []);
    await context.close();
    const readContext = await browser.newContext();
    await readContext.addInitScript(
      ({ session }) =>
        localStorage.setItem(
          'sb-api.lpg.144.79.249.4.sslip.io-auth-token',
          JSON.stringify(session),
        ),
      { session: auth.session },
    );
    const readPage = await readContext.newPage();
    await readPage.goto(worker + '/#/finance');
    await readPage.getByRole('tab', { name: 'Analysis', exact: true }).click();
    await readPage
      .getByRole('heading', { name: 'Earnings over time', exact: true })
      .waitFor();
    await readContext.close();
    console.log(
      'PASS: published desktop/tablet/phone Analysis/PDF, owner price editing/history, finalized service details and read-only burner Analysis',
    );
  }
  report = await rpc('get_finance_analysis', { p_filters: filters });
  assert.equal(
    report.totals.profit,
    1010,
    'Later buying prices must not rewrite sold cost',
  );
  assert.equal(
    sql(
      `select count(*) from public.wallets w where tenant_id=${uuid(owner.tenant)} and balance<>opening_balance+coalesce((select sum(amount) from public.wallet_transactions x where x.tenant_id=w.tenant_id and x.wallet_id=w.wallet_id),0);`,
    ),
    '0',
  );
  console.log(
    'PASS: live fixture wallets reconcile and historical profit remains unchanged after later price edits',
  );
} catch (error) {
  console.error(
    String(error?.stack ?? error)
      .replaceAll(secret.LPG_TEST_PASSWORD, '[redacted]')
      .replace(
        /eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g,
        '[redacted JWT]',
      ),
  );
  process.exitCode = 1;
} finally {
  if (browser) await browser.close();
  if (tenants.length) {
    const ids = tenants.map(uuid).join(',');
    const cleanupTables = sql(
      "select c.table_name from information_schema.columns c join information_schema.tables t using(table_catalog,table_schema,table_name) where c.table_schema='public' and c.column_name='tenant_id' and t.table_type='BASE TABLE' order by c.table_name;",
    ).split('\n');
    assert(cleanupTables.every((t) => /^[a-z_]+$/.test(t)));
    sql(
      `begin;do $$begin if exists(select 1 from public.tenants where tenant_id in (${ids}) and business_name not like 'Accounting API fixture %') then raise exception 'Not an accounting fixture';end if;end$$;set local session_replication_role=replica;${cleanupTables.map((t) => `delete from public.${t} where tenant_id in (${ids});`).join('\n')}commit;`,
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
