import { describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';
import { FieldCrypto } from '../src/lib/field-crypto.js';
import { createPinPair } from '../src/lib/pin.js';
import { FixedWindowLimiter } from '../src/lib/rate-limit.js';
import { MemoryInbox } from '../src/modules/inbox/memory-inbox.js';
import { registerInboxRoutes } from '../src/modules/inbox/routes.js';
import { InboxService } from '../src/modules/inbox/service.js';
import { MemoryUserRepo } from '../src/modules/auth/memory-user-repo.js';
import { MemoryOtpStore, OtpService } from '../src/modules/auth/otp.js';
import { makeAuthenticator, registerAuthRoutes } from '../src/modules/auth/routes.js';
import { SmsBudgetGuard } from '../src/modules/budget/budget.js';
import type { PushPayload, PushSender } from '../src/modules/notify/contact-notifier.js';
import { MemorySosStore } from '../src/modules/sos/memory-store.js';
import { MemoryShares } from '../src/modules/share/memory-share.js';
import { registerShareRoutes } from '../src/modules/share/routes.js';
import { ShareService } from '../src/modules/share/service.js';
import { MockSmsProvider } from '../src/providers/sms/SmsProvider.js';
import { FakeClock, PEPPER, harness } from './helpers.js';

/**
 * Throws hostile input at every public route: SQL injection strings, NUL bytes, scripts, wrong types, oversized
 * bodies and broken JSON. Every answer must be a clean 4xx (or a normal success). Never a 5xx, never the input echoed back.
 */
const HOSTILE = [
  "' OR '1'='1",
  "'; DROP TABLE users; --",
  '" OR ""="',
  '1; SELECT pg_sleep(10)--',
  "') UNION SELECT phone_enc FROM users --",
  'a\u0000b',
  '\u0000',
  '%00',
  '<script>alert(1)</script>',
  '../../etc/passwd',
  '${7*7}',
  '{{7*7}}',
  '\u202eevil',
  '😀'.repeat(30),
  '__proto__',
  'constructor',
  ' ',
  '',
  'x'.repeat(2000),
];
const WRONG_TYPES: unknown[] = [null, 0, -1, 1e308, true, [], {}, ['a'], { a: 1 }, [[]], { __proto__: { admin: true } }];
const MARKERS = ['DROP TABLE', 'UNION SELECT', '<script>', 'pg_sleep', 'etc/passwd'];

type Case = { method: 'GET' | 'POST' | 'PUT' | 'DELETE'; url: (v: string) => string; body?: Record<string, unknown>; headers?: Record<string, string> };

async function rig() {
  const h = await harness();
  const store = new MemorySosStore();
  const pins = await createPinPair('1234', '4321', PEPPER);
  store.addUser({ id: 'u1', phone: '+2348000000000', locale: 'en', name: 'Ada' }, pins, [
    { id: 'c1', userId: 'u1', phone: '+2348000000001', locale: 'en', hasApp: true, priority: 0 },
  ]);
  store.putUser({ id: 'uc1', phone: '+2348000000001', locale: 'en' });
  const inbox = new MemoryInbox(store);
  const shares = new MemoryShares();
  const push: PushSender = {
    async sendToContact() { return false; },
    async sendToUser(_u: string, _p: PushPayload) { return true; },
  };
  let n = 0;
  const clock = new FakeClock();
  const o = { clock: clock.fn, newId: () => `id-${++n}`, retentionMs: 72 * 3_600_000 };
  const shareSvc = new ShareService(store, inbox, shares, push, o);
  const inboxSvc = new InboxService(store, inbox, push, { alertView: async () => 'invalid' } as never, { ...o, shares });
  const authenticate = async (req: { headers: Record<string, unknown> }) => (req.headers['x-user'] as string | undefined) ?? null;
  const app = buildApp({ engine: h.engine, authenticate, startLimiter: new FixedWindowLimiter(100_000, 60_000) });
  registerShareRoutes(app, { service: shareSvc, authenticate, limiter: new FixedWindowLimiter(100_000, 60_000), updateLimiter: new FixedWindowLimiter(100_000, 60_000), clock: clock.fn });
  registerInboxRoutes(app, { service: inboxSvc, authenticate, limiter: new FixedWindowLimiter(100_000, 60_000) });

  // sign-in and profile routes, with a real signed-in person
  const sms = new MockSmsProvider(0);
  const fc = new FieldCrypto('a'.repeat(64), 'b'.repeat(64));
  const budget = new SmsBudgetGuard({ dailyLimitKobo: 1_000_000, emergencyReservePct: 20, perUserDailyKobo: 1_000_000 });
  let k = 0;
  const otp = new OtpService(new MemoryOtpStore(), sms, fc, budget, () => `o${++k}`);
  const auth = makeAuthenticator('s'.repeat(32), Date.now);
  const authApp = buildApp({ engine: h.engine, authenticate: auth.userId, startLimiter: new FixedWindowLimiter(100_000, 60_000) });
  registerAuthRoutes(authApp, {
    otp,
    users: new MemoryUserRepo(new MemorySosStore()),
    jwtSecret: 's'.repeat(32),
    pinPepper: PEPPER,
    clock: Date.now,
    defaultCountryCode: '234',
    ipLimiter: new FixedWindowLimiter(100_000, 60_000),
    authenticate: auth,
  });
  let code = '';
  await otp.issue('+2349024804472', async (c) => void (code = c), 0);
  const key = Buffer.alloc(32, 7).toString('base64');
  const signed = await authApp.inject({
    method: 'POST',
    url: '/v1/auth/otp/verify',
    payload: { phone: '+2349024804472', code, platform: 'android', publicKey: key, boxPublicKey: key },
  });
  const token = (signed.json() as { accessToken: string }).accessToken;
  return { app, authApp, token };
}

const SOS_CASES: Case[] = [
  { method: 'POST', url: () => '/v1/sos', body: { trigger: 'shake', lat: 6.5, lon: 3.4, accuracyM: 12 } },
  { method: 'POST', url: (v) => `/v1/sos/${encodeURIComponent(v)}/location`, body: { lat: 6.5, lon: 3.4, accuracyM: 12 } },
  { method: 'POST', url: (v) => `/v1/sos/${encodeURIComponent(v)}/pin`, body: { pin: '1234' } },
  { method: 'POST', url: () => '/v1/sos/current/pin', body: { pin: '1234' } },
  { method: 'POST', url: () => '/v1/alerts/low-battery', body: { lat: 6.5, lon: 3.4 } },
  { method: 'GET', url: (v) => `/v1/geo/reverse?lat=${encodeURIComponent(v)}&lon=${encodeURIComponent(v)}` },
  { method: 'POST', url: () => '/v1/shares', body: { contactIds: ['c1'], geo: { lat: 6.5, lon: 3.4 }, hours: 2 } },
  { method: 'PUT', url: (v) => `/v1/shares/${encodeURIComponent(v)}/location`, body: { lat: 6.5, lon: 3.4 } },
  { method: 'POST', url: (v) => `/v1/shares/${encodeURIComponent(v)}/extend`, body: { hours: 2 } },
  { method: 'DELETE', url: (v) => `/v1/shares/${encodeURIComponent(v)}` },
  { method: 'GET', url: (v) => `/v1/inbox/${encodeURIComponent(v)}` },
  { method: 'POST', url: (v) => `/v1/inbox/${encodeURIComponent(v)}/respond` },
  { method: 'POST', url: (v) => `/v1/invites/${encodeURIComponent(v)}`, body: { decision: 'accept' } },
];

const AUTH_CASES: Case[] = [
  { method: 'POST', url: () => '/v1/auth/otp/request', body: { phone: '08031234567' } },
  { method: 'POST', url: () => '/v1/auth/otp/verify', body: { phone: '08031234567', code: '123456', platform: 'android', publicKey: 'a', boxPublicKey: 'b', locale: 'en' } },
  { method: 'POST', url: () => '/v1/auth/refresh', body: { deviceId: '00000000-0000-4000-8000-000000000000', refreshToken: 'x'.repeat(30) } },
  { method: 'PUT', url: () => '/v1/me/contacts', body: { contacts: [{ phone: '08031234567', locale: 'en' }] } },
  { method: 'PUT', url: () => '/v1/me/pins', body: { cancelPin: '1234', duressPin: '4321' } },
  { method: 'PUT', url: () => '/v1/me/profile', body: { name: 'Ada', locale: 'en', dataSaver: true } },
  { method: 'PUT', url: () => '/v1/me/push-token', body: { token: 'x'.repeat(40) } },
];

/** Every string field in turn replaced by `v`, and then every field at once. */
function withStrings(body: Record<string, unknown>, v: unknown): Record<string, unknown>[] {
  const paths: (string | number)[][] = [];
  const walk = (x: unknown, p: (string | number)[]) => {
    if (typeof x === 'string' || typeof x === 'number' || typeof x === 'boolean') paths.push(p);
    else if (Array.isArray(x)) x.forEach((y, i) => walk(y, [...p, i]));
    else if (x && typeof x === 'object') Object.entries(x).forEach(([k, y]) => walk(y, [...p, k]));
  };
  walk(body, []);
  const set = (root: Record<string, unknown>, p: (string | number)[], val: unknown) => {
    let cur: any = root;
    p.slice(0, -1).forEach((k) => (cur = cur[k]));
    cur[p[p.length - 1]!] = val;
  };
  const out = paths.map((p) => {
    const c = structuredClone(body);
    set(c, p, v);
    return c;
  });
  const all = structuredClone(body);
  paths.forEach((p) => set(all, p, v));
  return [...out, all];
}

function check(res: { statusCode: number; body: string; headers: Record<string, unknown> }, label: string) {
  expect(res.statusCode, `${label} -> ${res.statusCode} ${res.body.slice(0, 120)}`).toBeLessThan(500);
  for (const m of MARKERS) expect(res.body.includes(m), `${label} echoed "${m}"`).toBe(false);
  expect(String(res.headers['content-type'] ?? 'application/json'), label).toMatch(/json/);
}

describe('hostile input', () => {
  for (const [name, cases, useAuthApp] of [
    ['sos, sharing and inbox routes', SOS_CASES, false],
    ['sign-in and profile routes', AUTH_CASES, true],
  ] as const) {
    it(`every ${name} answers cleanly to hostile text in every field and in the URL`, async () => {
      const r = await rig();
      for (const c of cases) {
        const target = useAuthApp ? r.authApp : r.app;
        const headers = useAuthApp ? { authorization: `Bearer ${r.token}` } : { 'x-user': 'u1' };
        for (const v of HOSTILE) {
          const bodies = c.body ? withStrings(c.body, v) : [undefined];
          for (const b of bodies) {
            const res = await target.inject({ method: c.method, url: c.url(v), headers, ...(b ? { payload: b } : {}) });
            check(res, `${c.method} ${c.url('<text>')} with ${JSON.stringify(v).slice(0, 30)}`);
          }
        }
      }
    });

    it(`every ${name} answers cleanly to the wrong kind of value in every field`, async () => {
      const r = await rig();
      for (const c of cases) {
        if (!c.body) continue;
        const target = useAuthApp ? r.authApp : r.app;
        const headers = useAuthApp ? { authorization: `Bearer ${r.token}` } : { 'x-user': 'u1' };
        for (const v of WRONG_TYPES) {
          for (const b of withStrings(c.body, v)) {
            const res = await target.inject({ method: c.method, url: c.url('id-1'), headers, payload: JSON.stringify(b) });
            check(res, `${c.method} ${c.url('id-1')} with ${JSON.stringify(v)}`);
          }
        }
      }
    });

    it(`every ${name} survives broken JSON, the wrong content type, an empty body and an oversized body`, async () => {
      const r = await rig();
      for (const c of cases) {
        if (c.method === 'GET' || c.method === 'DELETE') continue;
        const target = useAuthApp ? r.authApp : r.app;
        const base = useAuthApp ? { authorization: `Bearer ${r.token}` } : { 'x-user': 'u1' };
        const url = c.url('id-1');
        for (const [payload, type] of [
          ['{"a":', 'application/json'],
          ['{"a":1}', 'text/plain'],
          ['', 'application/json'],
          ['null', 'application/json'],
          ['[]', 'application/json'],
          ['"just a string"', 'application/json'],
          [JSON.stringify({ pad: 'x'.repeat(200_000) }), 'application/json'],
        ] as const) {
          const res = await target.inject({ method: c.method, url, headers: { ...base, 'content-type': type }, payload });
          check(res, `${c.method} ${url} with ${type} ${payload.slice(0, 20)}`);
        }
      }
    });
  }
});

describe('a value the database refuses is the caller\'s mistake', () => {
  it('maps PostgreSQL "data exception" errors (class 22) to 400, and other failures to 500', async () => {
    const h = await harness();
    const app = buildApp({ engine: h.engine, authenticate: async () => 'u1', startLimiter: new FixedWindowLimiter(100, 60_000) });
    app.get('/t/bad-id', async () => {
      throw Object.assign(new Error('invalid input syntax for type uuid: "x"'), { code: '22P02' });
    });
    app.get('/t/nul', async () => {
      throw Object.assign(new Error('invalid byte sequence for encoding "UTF8": 0x00'), { code: '22021' });
    });
    app.get('/t/boom', async () => {
      throw Object.assign(new Error('connection refused'), { code: 'ECONNREFUSED' });
    });
    app.get('/t/db-down', async () => {
      throw Object.assign(new Error('the database system is shutting down'), { code: '57P01' });
    });
    const get = async (u: string) => app.inject({ method: 'GET', url: u });
    expect((await get('/t/bad-id')).statusCode).toBe(400);
    expect((await get('/t/nul')).statusCode).toBe(400);
    expect((await get('/t/boom')).statusCode).toBe(500);
    expect((await get('/t/db-down')).statusCode).toBe(500);
    expect((await get('/t/bad-id')).json()).toEqual({ error: 'bad_request' });
    expect((await get('/t/boom')).json()).toEqual({ error: 'internal' }); // no internal detail leaks
  });
});
