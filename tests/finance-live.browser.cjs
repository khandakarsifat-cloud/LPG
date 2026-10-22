// Explicit live acceptance: creates one disposable business through registration.
// Return only fixture IDs for trusted cleanup, never credentials or sessions.
async page => {
  const base = 'https://floral-dew-443b.khandakarsifat.workers.dev';
  const suffix = Date.now().toString();
  const email = `finance-browser-${suffix}@example.invalid`, password = `Finance-${suffix}-${Math.random().toString(36)}-Aa1!`;
  await page.goto(base + '/?finance-live=' + suffix + '#/register');
  await page.locator('#business-name').fill('Finance browser fixture ' + suffix);
  await page.locator('#owner-name').fill('Finance browser owner');
  await page.getByRole('button', { name: 'Continue', exact: true }).click();
  await page.locator('#email').fill(email); await page.locator('#password').fill(password); await page.locator('#confirm-password').fill(password);
  const setup = page.waitForResponse(r => r.url().endsWith('/rpc/setup_business'));
  const signup = page.waitForResponse(r => r.url().includes('/auth/v1/signup'));
  await page.locator('button[type=submit]').click();
  const business = await (await setup).json(); const identity = await (await signup).json();
  const result = { tenant: business.tenant_id, user: identity.user?.id ?? identity.id };
  if (!result.tenant || !result.user) throw Error('Fixture registration did not complete');
  try {
    await page.getByRole('link', { name: 'Finance', exact: true }).click();
    await page.getByRole('button', { name: 'Manage Cash Register', exact: true }).waitFor();
    if (await page.locator('.finance-wallet').count() !== 5) throw Error('New business wallets missing');
    await page.getByRole('button', { name: 'Adjust balance', exact: true }).click();
    // Wallet selection is explicit: no browser fixture data or intercepted API.
    const dialog = page.getByRole('dialog', { name: 'Adjust wallet balance', exact: true });
    await dialog.getByLabel('Wallet', { exact: true }).selectOption({ label: 'Cash Register' });
    await dialog.getByLabel('Amount (Tk)', { exact: true }).fill('1000');
    await dialog.getByLabel('Reason / reference', { exact: true }).fill('Disposable browser fixture opening funds');
    await dialog.getByRole('button', { name: 'Record adjustment', exact: true }).click();
    await page.getByText('Adjustment recorded', { exact: true }).waitFor();
    await page.getByRole('button', { name: 'Transfer', exact: true }).click();
    await page.getByLabel('From wallet', { exact: true }).selectOption({ label: 'Cash Register' });
    await page.getByLabel('To wallet', { exact: true }).selectOption({ label: 'bKash' });
    await page.getByLabel('Amount (Tk)', { exact: true }).fill('100');
    await page.getByLabel('Reason / reference', { exact: true }).fill('Disposable fixture transfer');
    await page.getByRole('button', { name: 'Record transfer', exact: true }).click();
    await page.getByText('Transfer recorded', { exact: true }).waitFor();
    await page.getByText('3 entries', { exact: true }).waitFor();
    await page.getByRole('button', { name: 'Add wallet', exact: true }).click();
    await page.getByLabel('Wallet name', { exact: true }).fill('Fixture secondary bank');
    await page.getByRole('button', { name: 'Save wallet', exact: true }).click();
    await page.getByRole('button', { name: 'Manage Fixture secondary bank', exact: true }).waitFor();
    await page.getByLabel('Search wallet ledger').fill('Disposable fixture transfer');
    await page.getByText('2 entries', { exact: true }).waitFor();
    for (const width of [1440, 768, 390]) {
      await page.setViewportSize({ width, height: 950 });
      if (!await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1)) throw Error('Published Finance overflows at ' + width);
      await page.screenshot({ path: `.temp/finance/live-${width}.png` });
    }
    result.passed = 'Published frontend with real Auth/API: registration defaults, adjustment, transfer, custom wallet, indexed ledger search, desktop/tablet/mobile';
  } catch (error) { result.error = error.message; }
  await page.evaluate(() => { localStorage.clear(); sessionStorage.clear(); });
  await page.goto(base + '/?finance-live-done=' + suffix + '#/login');
  return result;
}
