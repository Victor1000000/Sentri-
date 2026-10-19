import { describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';
import { FieldCrypto } from '../src/lib/field-crypto.js';
import { FixedWindowLimiter } from '../src/lib/rate-limit.js';
import { MemoryOtpStore, OtpService } from '../src/modules/auth/otp.js';
import { SmsBudgetGuard } from '../src/modules/budget/budget.js';
import { MockSmsProvider } from '../src/providers/sms/SmsProvider.js';
import { EnvSchema } from '../src/config/env.js';
import { harness } from './helpers.js';

async function appWith(extra: Partial<Parameters<typeof buildApp>[0]> = {}) {
  const h = await harness();
  return buildApp({
    engine: h.engine,
    authenticate: async () => null,
    startLimiter: new FixedWindowLimiter(5, 60_000),
    ...extra,
  });
}

describe('rate limiter memory', () => {
  it('forgets expired keys instead of growing forever', () => {
    let now = 0;
    const l = new FixedWindowLimiter(1, 1000, () => now);
    for (let i = 0; i < 100; i++) l.allow(`k${i}`);
    expect(l.size()).toBe(100);
    now = 5000;
    l.allow('fresh');
    expect(l.size()).toBe(1);
  });

  it('refuses new keys when a flood fills the table, but keeps serving known ones', () => {
    const l = new FixedWindowLimiter(5, 60_000, () => 0, 3);
    expect(l.allow('a')).toBe(true);
    expect(l.allow('b')).toBe(true);
    expect(l.allow('c')).toBe(true);
    expect(l.allow('d')).toBe(false);
    expect(l.allow('a')).toBe(true);
  });
});

describe('response headers', () => {
  it('sends HSTS only when turned on, and always blocks caching and sensors', async () => {
    const on = await appWith({ hsts: true });
    const off = await appWith();
    const a = await on.inject({ method: 'GET', url: '/healthz' });
    const b = await off.inject({ method: 'GET', url: '/healthz' });
    expect(a.headers['strict-transport-security']).toMatch(/max-age=31536000/);
    expect(b.headers['strict-transport-security']).toBeUndefined();
    expect(a.headers['cache-control']).toBe('no-store');
    expect(a.headers['permissions-policy']).toContain('geolocation=()');
  });
});

describe('overall request cap', () => {
  it('answers 429 once one address sends too many requests', async () => {
    const app = await appWith({ globalLimiter: new FixedWindowLimiter(3, 60_000) });
    const codes: number[] = [];
    for (let i = 0; i < 5; i++) codes.push((await app.inject({ method: 'GET', url: '/healthz' })).statusCode);
    expect(codes).toEqual([200, 200, 200, 429, 429]);
  });

  it('ignores a forged X-Forwarded-For when no proxy is configured', async () => {
    const app = await appWith({ globalLimiter: new FixedWindowLimiter(1, 60_000) });
    const get = (xff: string) => app.inject({ method: 'GET', url: '/healthz', headers: { 'x-forwarded-for': xff } });
    expect((await get('1.1.1.1')).statusCode).toBe(200);
    expect((await get('2.2.2.2')).statusCode).toBe(429); // still the same caller
  });

  it('with one proxy, tells callers apart by the address the proxy saw and ignores forged earlier entries', async () => {
    const app = await appWith({ trustProxyHops: 1, globalLimiter: new FixedWindowLimiter(1, 60_000) });
    // Only the real Fastify reads X-Forwarded-For. The offline stand-in used when the npm registry is unreachable
    // has no `version` and a fixed address, so this check runs in CI and on your machine, not there.
    if (!(app as unknown as { version?: string }).version) return;
    const get = (xff: string) => app.inject({ method: 'GET', url: '/healthz', headers: { 'x-forwarded-for': xff } });
    expect((await get('9.9.9.9, 10.0.0.1')).statusCode).toBe(200);
    expect((await get('8.8.8.8, 10.0.0.2')).statusCode).toBe(200); // a different real caller
    expect((await get('7.7.7.7, 10.0.0.1')).statusCode).toBe(429); // same real caller, new forged label
  });
});

describe('sign-in code guessing', () => {
  it('counts guesses sent at the same moment, so the right code cannot slip in late', async () => {
    const sms = new MockSmsProvider(0);
    const fc = new FieldCrypto('a'.repeat(64), 'b'.repeat(64));
    const budget = new SmsBudgetGuard({ dailyLimitKobo: 1_000_000, emergencyReservePct: 20, perUserDailyKobo: 1_000_000 });
    let n = 0;
    const otp = new OtpService(new MemoryOtpStore(), sms, fc, budget, () => `o${++n}`);
    const phone = '+2348031234567';
    await otp.request(phone);
    const good = /(\d{6})/.exec(sms.sent.at(-1)!.text)![1]!;
    const wrong = (i: number) => String((Number(good) + 1 + i) % 1_000_000).padStart(6, '0');
    // Nine wrong guesses and then the right one, all in flight together. Only the first five count.
    const results = await Promise.all([...Array.from({ length: 9 }, (_, i) => otp.verify(phone, wrong(i))), otp.verify(phone, good)]);
    expect(results.every((r) => r === false)).toBe(true);
    expect(await otp.verify(phone, good)).toBe(false);
  });
});

describe('startup safety', () => {
  const base = {
    NODE_ENV: 'production',
    PUBLIC_BASE_URL: 'https://api.example.com',
    TOKEN_SECRET: 't'.repeat(32),
    PIN_PEPPER: 'p'.repeat(32),
    STORE: 'postgres',
    DATABASE_URL: 'postgres://x',
    REDIS_URL: 'redis://x',
    JWT_SECRET: 'j'.repeat(32),
    DATA_KEY: 'a'.repeat(64),
    PHONE_HMAC_KEY: 'b'.repeat(64),
    SMS_PROVIDER: 'termii',
    TERMII_API_KEY: 'k',
    TERMII_SENDER_ID: 's',
  };

  it('accepts a proper production setup', () => {
    expect(EnvSchema.safeParse(base).success).toBe(true);
  });

  const unsafe: [string, Record<string, string>][] = [
    ['dev code echo', { OTP_DEV_ECHO: 'true' }],
    ['demo user', { DEV_SEED: 'true' }],
    ['memory store', { STORE: 'memory' }],
    ['mock SMS', { SMS_PROVIDER: 'mock' }],
    ['admin secret equal to the user secret', { ADMIN_JWT_SECRET: 'j'.repeat(32) }],
  ];
  for (const [name, over] of unsafe) {
    it(`refuses to start in production with ${name}`, () => {
      expect(EnvSchema.safeParse({ ...base, ...over }).success).toBe(false);
    });
  }
});
