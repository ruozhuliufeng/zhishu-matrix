const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const body = fs.readFileSync(path.join(__dirname, '../Resources/SessionProbe.js'), 'utf8');
const AsyncFunction = (async () => {}).constructor;

function runProbe(status, payload) {
  const fetch = async () => ({
    status,
    async json() {
      if (typeof payload === 'string') throw new SyntaxError('Unexpected token <');
      return payload;
    },
  });
  return new AsyncFunction('fetch', body)(fetch);
}

test('reports the signed-in email and plan without leaking the access token', async () => {
  const result = await runProbe(200, {
    user: { id: 'user-1', email: 'work@example.com', name: 'Work' },
    account: { planType: 'plus' },
    accessToken: 'secret-token',
  });
  assert.deepEqual(result, { status: 200, parsed: true, signedIn: true, email: 'work@example.com', planType: 'plus' });
  assert.doesNotMatch(JSON.stringify(result), /secret-token/);
});

test('treats an empty session as signed out', async () => {
  const result = await runProbe(200, {});
  assert.equal(result.parsed, true);
  assert.equal(result.signedIn, false);
  assert.equal(result.email, '');
});

test('flags unparsable responses so the app keeps the previous login state', async () => {
  const result = await runProbe(403, '<html>challenge</html>');
  assert.equal(result.status, 403);
  assert.equal(result.parsed, false);
  assert.equal(result.signedIn, false);
});
