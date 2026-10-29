// Run in an isolated browser context against the published frontend. Old SDK
// first-label sessions must not be reused after switching self-hosted backends.
async page => {
  const origin = new URL(page.url()).origin;
  await page.context().addInitScript(() => {
    localStorage.clear();
    const user = { id: 'a1111111-1111-4111-8111-111111111111', aud: 'authenticated',
      role: 'authenticated', email: 'obsolete-backend@example.invalid', app_metadata: {}, user_metadata: {} };
    const expires = Math.floor(Date.now() / 1000) + 3600;
    const token = btoa(JSON.stringify({ alg: 'HS256', typ: 'JWT' })) + '.'
      + btoa(JSON.stringify({ sub: user.id, role: 'authenticated', exp: expires })) + '.obsolete';
    localStorage.setItem('sb-api-auth-token', JSON.stringify({ user, access_token: token,
      refresh_token: 'obsolete-backend-fixture', token_type: 'bearer', expires_at: expires }));
  });
  const reused = [];
  page.on('request', request => {
    if ((request.headers().authorization ?? '').includes('.obsolete')) reused.push(request.url());
  });
  await page.goto(origin + '/?session-isolation=1#/');
  await page.getByLabel('Email Address', { exact: true }).waitFor();
  if (reused.length) throw new Error('Obsolete backend session was sent to the new API');
  if (await page.getByRole('heading', { name: 'Workspace access unavailable', exact: true }).count()) {
    throw new Error('Obsolete session blocked clean login');
  }
  return { isolated: true, reusedRequests: reused.length };
}
