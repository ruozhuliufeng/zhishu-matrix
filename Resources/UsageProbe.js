// Body of an async function run with callAsyncJavaScript on a small chatgpt.com page. Reads usage limits and
// subscription renewal with the account's own sign-in; the access token used for a retry stays inside this function.
const read = async (path, token) => {
  const headers = { Accept: 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;
  const response = await fetch(path, { credentials: 'include', cache: 'no-store', headers });
  let body = null;
  try {
    body = await response.json();
  } catch (error) {
    body = null;
  }
  return { status: response.status, body };
};
const scalars = value => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const result = {};
  for (const [key, item] of Object.entries(value)) {
    if (item === null || ['string', 'number', 'boolean'].includes(typeof item)) result[key] = item;
  }
  return result;
};

let usage = await read('/backend-api/wham/usage');
let subscription = await read('/backend-api/subscriptions');
let signedIn = usage.status === 200 || subscription.status === 200 ? true : null;
let email = '';
if (usage.status === 401 || subscription.status === 401) {
  const session = await read('/api/auth/session');
  const user = session.body && typeof session.body === 'object' && session.body.user && typeof session.body.user === 'object'
    ? session.body.user : null;
  if (session.status === 200 && session.body && !user) return { signedIn: false };
  if (user) {
    signedIn = true;
    email = typeof user.email === 'string' ? user.email : '';
  }
  const token = session.body && typeof session.body.accessToken === 'string' ? session.body.accessToken : '';
  if (token) {
    usage = await read('/backend-api/wham/usage', token);
    subscription = await read('/backend-api/subscriptions', token);
  }
}
return {
  signedIn,
  email,
  usage: { status: usage.status, body: usage.body },
  subscription: { status: subscription.status, body: scalars(subscription.body) },
};
