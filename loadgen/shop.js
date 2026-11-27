// Traffic for the shop's API (app/shop/main.py). One script: the profile in profiles.json sets the mix and the shape.
//
//   PROFILE    background | read-heavy | write-heavy | mixed | spike | soak
//   RATE       requests per second (spike: the rate before and after the burst), default from the profile
//   PEAK       spike only: the burst is PEAK times RATE
//   DURATION   for example 30s, 10m, 2h; default from the profile
//   SEED       the same seed sends the same requests in the same order (default 1)
//   BASE_URL   default http://127.0.0.1:8000
//   MAX_VUS    most requests at the same time (k6 adds them as needed)
//   DATA_CUSTOMERS, DATA_PRODUCTS, DATA_ORDERS   the data set's size, if not the full one in profiles.json
//   STRICT=1   fail the run (exit code 99) when a response is not one of the expected ones
//   DRY_RUN=1  print the requests instead of sending them (to compare two runs)
//
// Customers and products are picked as unevenly as the generator made them (db/seed/functions.sql): five customers
// get 10% of the requests, and a few products most of them.

import http from 'k6/http';
import { check } from 'k6';
import exec from 'k6/execution';

const settings = JSON.parse(open('./profiles.json'));
const env = __ENV;
const name = env.PROFILE || 'background';
const profile = settings.profiles[name];
if (!profile) throw new Error(`unknown PROFILE ${name}; known: ${Object.keys(settings.profiles).join(', ')}`);

const mix = typeof profile.mix === 'string' ? settings.profiles[profile.mix].mix : profile.mix;
const rate = Number(env.RATE || profile.rate);
const duration = env.DURATION || profile.duration;
const seed = Number(env.SEED || 1);
const baseUrl = env.BASE_URL || 'http://127.0.0.1:8000';
const data = {
  customers: Number(env.DATA_CUSTOMERS || settings.data.customers),
  products: Number(env.DATA_PRODUCTS || settings.data.products),
  orders: Number(env.DATA_ORDERS || settings.data.orders),
  lastDay: settings.data.last_day,
};
if (!(rate > 0) || !(seed >= 0) || !(data.customers > 5 && data.products > 3 && data.orders > 0)) {
  throw new Error('RATE must be above 0, SEED a number, and the data set at least 6 customers, 4 products and 1 order');
}

// --- Shape ------------------------------------------------------------------------------

function seconds(text) {
  const match = /^(\d+)(s|m|h)$/.exec(text);
  if (!match) throw new Error(`DURATION must look like 30s, 10m or 2h, not ${text}`);
  return Number(match[1]) * { s: 1, m: 60, h: 3600 }[match[2]];
}

// Arrival rates count per minute, so that 1.5 requests per second is possible
const perMinute = (perSecond) => Math.max(1, Math.round(perSecond * 60));
const total = seconds(duration);
const maxVUs = Number(env.MAX_VUS || Math.max(10, Math.ceil(rate * (Number(profile.peak) || 1) * 20)));
const vus = { preAllocatedVUs: Math.min(maxVUs, Math.max(2, Math.ceil(rate * 2))), maxVUs };

function scenario() {
  if (env.DRY_RUN === '1') return { executor: 'shared-iterations', vus: 2, iterations: Number(env.ITERATIONS || 200) };
  if (profile.shape === 'constant') {
    return { executor: 'constant-arrival-rate', rate: perMinute(rate), timeUnit: '1m', duration, ...vus };
  }
  if (profile.shape === 'spike') {
    const peak = rate * Number(env.PEAK || profile.peak);
    const part = Math.max(1, Math.floor((total - 20) / 4));
    return {
      executor: 'ramping-arrival-rate', startRate: perMinute(rate), timeUnit: '1m', ...vus,
      stages: [
        { target: perMinute(rate), duration: `${part}s` },
        { target: perMinute(peak), duration: '10s' },
        { target: perMinute(peak), duration: `${part}s` },
        { target: perMinute(rate), duration: '10s' },
        { target: perMinute(rate), duration: `${Math.max(1, total - 20 - 2 * part)}s` },
      ],
    };
  }
  throw new Error(`unknown shape ${profile.shape}`);
}

export const options = {
  scenarios: { [name]: scenario() },
  // Without "url": every product and order number would be a series of its own in Prometheus
  systemTags: ['status', 'method', 'name', 'scenario', 'expected_response', 'check'],
  tags: { profile: name, seed: String(seed) },
  thresholds: env.STRICT === '1' ? { checks: ['rate==1'] } : {},
  discardResponseBodies: true,
};

// --- Random numbers that a seed repeats ---------------------------------------------------

// mulberry32, started from the seed and the number of the request within the run
function random(n) {
  let state = (Math.imul(seed ^ 0x9e3779b9, 0x85ebca6b) ^ Math.imul(n + 1, 0xc2b2ae35)) >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const below = (r, n) => Math.floor(r() * n);
const oneOf = (r, values) => values[below(r, values.length)];
// Like gen.pick_customer and gen.pick_product
const customer = (r) => (r() < 0.10 ? 1 + below(r, 5) : 6 + Math.floor((data.customers - 5) * Math.pow(r(), 1.5)));
const product = (r) => 1 + Math.floor(data.products * Math.pow(r(), 3));
const order = (r) => 1 + below(r, data.orders);

function day(offset) {
  const date = new Date(`${data.lastDay}T00:00:00Z`);
  date.setUTCDate(date.getUTCDate() + offset);
  return date.toISOString().slice(0, 10);
}
// Periods inside the generated data, so that a run next month asks for the same rows
const period = (days) => `start=${day(-days)}&end=${data.lastDay}`;

function uuid(r) {
  const hex = Array.from({ length: 32 }, () => below(r, 16).toString(16)).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-4${hex.slice(13, 16)}-a${hex.slice(17, 20)}-${hex.slice(20)}`;
}

function distinctProducts(r, count) {
  const ids = new Set();
  while (ids.size < count) ids.add(product(r));
  return [...ids];
}

// --- The requests -------------------------------------------------------------------------

const WORDS = ['Classic', 'Modern', 'Compact', 'Deluxe', 'Eco', 'Lamp', 'Kettle', 'Chair', 'Headphones', 'Tent', 'Mug', 'Desk'];
const COLORS = ['black', 'white', 'grey', 'blue', 'red', 'teal'];
const STATUSES = ['pending', 'pending', 'pending', 'paid', 'paid', 'shipped', 'shipped', 'cancelled', 'returned', 'returned'];

const get = (path, ...expected) => ({ method: 'GET', path, expected: expected.length ? expected : [200] });
const send = (method, path, body, ...expected) => ({ method, path, body, expected });

const ENDPOINTS = {
  customer: (r) => get(`/customers/${customer(r)}`),
  customer_by_email: (r) => get(`/customers?email=user${customer(r)}%40example.com`),
  order_history: (r) => get(`/customers/${customer(r)}/orders?page=${r() < 0.8 ? 1 : 2 + below(r, 3)}&page_size=20`),
  orders_delivered: () => get('/orders?status=delivered&limit=20'),
  orders_by_status: (r) => get(`/orders?status=${oneOf(r, STATUSES)}&limit=20`),
  order_detail: (r) => get(`/orders/${order(r)}`),
  product_search: (r) => get(`/products?q=${oneOf(r, WORDS)}${r() < 0.3 ? `&color=${oneOf(r, COLORS)}` : ''}&page=1&page_size=20`),
  product_detail: (r) => get(`/products/${product(r)}`),
  top_products: (r) => get(`/reports/top-products?${period(oneOf(r, [7, 30, 90]))}&limit=10`),
  daily_sales: () => get(`/reports/daily-sales?${period(30)}`),
  event_counts: () => get(`/reports/events?${period(7)}`),
  add_event: (r) => {
    const known = r() < 0.7;
    return send('POST', '/events', {
      event_type: oneOf(r, ['view', 'view', 'view', 'search', 'add_to_cart', 'checkout', 'login']),
      session_id: uuid(r),
      customer_id: known ? customer(r) : null,
      product_id: r() < 0.8 ? product(r) : null,
      payload: { source: 'loadgen' },
    }, 201);
  },
  // 404: a product that is not for sale (5%), 409: out of stock
  place_order: (r) => send('POST', '/orders', {
    customer_id: customer(r),
    payment_method: oneOf(r, ['card', 'card', 'paypal', 'bank_transfer', 'gift_card']),
    lines: distinctProducts(r, 1 + below(r, 3)).map((id) => ({ product_id: id, quantity: 1 + below(r, 2) })),
  }, 201, 404, 409),
  add_review: (r) => send('POST', `/products/${product(r)}/reviews`, {
    customer_id: customer(r), rating: oneOf(r, [5, 5, 5, 4, 3, 1]), title: 'Loadgen review', body: 'Written by the load test.',
  }, 201),
  // Most orders are delivered and may be returned; the others answer 409
  change_status: (r) => send('PUT', `/orders/${order(r)}/status`, { status: 'returned' }, 200, 409),
};

for (const endpoint of Object.keys(mix)) {
  if (!ENDPOINTS[endpoint]) throw new Error(`profile ${name}: unknown endpoint ${endpoint}`);
}
const weights = Object.entries(mix);
const weightSum = weights.reduce((sum, [, weight]) => sum + weight, 0);

function choose(r) {
  let left = r() * weightSum;
  for (const [endpoint, weight] of weights) {
    left -= weight;
    if (left < 0) return endpoint;
  }
  return weights[weights.length - 1][0];
}

export function plan(n) {
  const r = random(n);
  const endpoint = choose(r);
  return { endpoint, ...ENDPOINTS[endpoint](r) };
}

export default function () {
  const n = exec.scenario.iterationInTest;
  const request = plan(n);
  const body = request.body === undefined ? null : JSON.stringify(request.body);
  if (env.DRY_RUN === '1') {
    console.log(`${n} ${request.endpoint} ${request.method} ${request.path} ${body || ''}`);
    return;
  }
  const response = http.request(request.method, `${baseUrl}${request.path}`, body, {
    headers: body ? { 'Content-Type': 'application/json' } : {},
    tags: { name: request.endpoint },
    responseCallback: http.expectedStatuses(...request.expected),
    timeout: '60s',
  });
  check(response, { 'expected status': (res) => request.expected.includes(res.status) });
}
