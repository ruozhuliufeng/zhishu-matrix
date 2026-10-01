const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const body = fs.readFileSync(path.join(__dirname, '../Resources/UsageProbe.js'), 'utf8');
const AsyncFunction = (async () => {}).constructor;

const usageJSON = {
  plan_type: 'pro',
  rate_limit: { primary_window: { used_percent: 20, limit_window_seconds: 18000, reset_at: 1790000000 } },
  credits: { has_credits: true, unlimited: false, balance: '62500' },
};

function runProbe(routes) {
  const calls = [];
  const fetch = async (url, options) => {
    calls.push({ url, auth: options.headers.Authorization || '' });
    const reply = routes(url, options.headers.Authorization || '');
    return {
      status: reply.status,
      async json() {
        if (typeof reply.body === 'string') throw new SyntaxError('Unexpected token <');
        return reply.body;
      },
    };
  };
  return new AsyncFunction('fetch', body)(fetch).then(result => ({ result, calls }));
}

test('reads usage and subscription with the account cookies', async () => {
  const { result, calls } = await runProbe(url => url.endsWith('/usage')
    ? { status: 200, body: usageJSON }
    : { status: 200, body: { active_until: '2026-10-25T00:00:00Z', will_renew: true, account: { id: 'nested' } } });
  assert.equal(result.signedIn, true);
  assert.deepEqual(result.usage, { status: 200, body: usageJSON });
  assert.deepEqual(result.subscription.body, { active_until: '2026-10-25T00:00:00Z', will_renew: true });
  assert.equal(calls.length, 2);
});

test('retries with the session token after a 401 without returning it', async () => {
  const { result, calls } = await runProbe((url, auth) => {
    if (url === '/api/auth/session') return { status: 200, body: { user: { email: 'c@example.com' }, accessToken: 'secret-token' } };
    if (auth !== 'Bearer secret-token') return { status: 401, body: { detail: 'Unauthorized' } };
    return url.endsWith('/usage') ? { status: 200, body: usageJSON } : { status: 200, body: { active_until: null, will_renew: false } };
  });
  assert.equal(result.signedIn, true);
  assert.equal(result.email, 'c@example.com');
  assert.equal(result.usage.status, 200);
  assert.equal(calls.filter(call => call.auth === 'Bearer secret-token').length, 2);
  assert.doesNotMatch(JSON.stringify(result), /secret-token/);
});

test('reports an empty session as signed out', async () => {
  const { result } = await runProbe(url => url === '/api/auth/session' ? { status: 200, body: {} } : { status: 401, body: {} });
  assert.deepEqual(result, { signedIn: false });
});

test('passes blocked responses through for the app to explain', async () => {
  const { result } = await runProbe(() => ({ status: 403, body: '<html>challenge</html>' }));
  assert.equal(result.signedIn, null);
  assert.deepEqual(result.usage, { status: 403, body: null });
});
