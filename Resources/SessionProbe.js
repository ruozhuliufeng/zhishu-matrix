// Body of an async function run with callAsyncJavaScript. Only non-secret profile fields are
// returned; the access token in the session response never leaves the page.
const response = await fetch('/api/auth/session', { credentials: 'include', cache: 'no-store' });
let session = null;
try {
  session = await response.json();
} catch (error) {
  session = null;
}
const parsed = Boolean(session) && typeof session === 'object';
const user = parsed && session.user && typeof session.user === 'object' ? session.user : null;
const account = parsed && session.account && typeof session.account === 'object' ? session.account : null;
const text = value => (typeof value === 'string' ? value.slice(0, 320) : '');
return {
  status: response.status,
  parsed,
  signedIn: Boolean(user && (user.id || user.email)),
  email: text(user && user.email),
  planType: text(account && account.planType),
};
