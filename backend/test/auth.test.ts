import { describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';
import { FieldCrypto } from '../src/lib/field-crypto.js';
import { FixedWindowLimiter } from '../src/lib/rate-limit.js';
import { signAccessToken, verifyAccessToken } from '../src/modules/auth/jwt.js';
import { MemoryUserRepo } from '../src/modules/auth/memory-user-repo.js';
import { MemoryOtpStore, OtpService } from '../src/modules/auth/otp.js';
import { ContactError, normalizePhone, validateContacts } from '../src/modules/auth/phone.js';
import { makeAuthenticator, registerAuthRoutes } from '../src/modules/auth/routes.js';
import { SmsBudgetGuard } from '../src/modules/budget/budget.js';
import { MockSmsProvider } from '../src/providers/sms/SmsProvider.js';
import { GEO, PEPPER, harness } from './helpers.js';

const SECRET = 's'.repeat(32);
const KEY_A = 'a'.repeat(64);
const KEY_B = 'b'.repeat(64);

describe('FieldCrypto', () => {
  const fc = new FieldCrypto(KEY_A, KEY_B);

  it('round-trips and uses a fresh nonce each time', () => {
    const a = fc.encrypt('+2348012345678');
    const b = fc.encrypt('+2348012345678');
    expect(a.equals(b)).toBe(false);
    expect(fc.decrypt(a)).toBe('+2348012345678');
  });

  it('detects tampering and wrong keys', () => {
    const ct = fc.encrypt('secret');
    ct[ct.length - 1] ^= 1;
    expect(() => fc.decrypt(ct)).toThrow();
    expect(() => new FieldCrypto('b'.repeat(64), KEY_B).decrypt(fc.encrypt('x'))).toThrow();
  });

  it('blind index is stable, keyed, and does not contain the number', () => {
    expect(fc.blindIndex('+234801').equals(fc.blindIndex('+234801'))).toBe(true);
    expect(fc.blindIndex('+234801').equals(new FieldCrypto(KEY_A, KEY_A).blindIndex('+234801'))).toBe(false);
  });

  it('rejects malformed keys', () => {
    expect(() => new FieldCrypto('abc', KEY_B)).toThrow(/DATA_KEY/);
  });
});

describe('access tokens', () => {
  const now = 1_700_000_000_000;

  it('verifies a good token', () => {
    const t = signAccessToken({ sub: 'u1', did: 'd1' }, SECRET, 900, now);
    expect(verifyAccessToken(t, SECRET, now + 1000)).toEqual({ sub: 'u1', did: 'd1' });
  });

  it('rejects expired, tampered, wrong-secret and alg:none tokens', () => {
    const t = signAccessToken({ sub: 'u1', did: 'd1' }, SECRET, 900, now);
    expect(verifyAccessToken(t, SECRET, now + 901_000)).toBeNull();
    expect(verifyAccessToken(t, 'x'.repeat(32), now)).toBeNull();
    const [h, p, s] = t.split('.');
    const evil = Buffer.from(JSON.stringify({ sub: 'admin', did: 'd1', exp: 9_999_999_999 })).toString('base64url');
    expect(verifyAccessToken(`${h}.${evil}.${s}`, SECRET, now)).toBeNull();
    const none = Buffer.from(JSON.stringify({ alg: 'none', typ: 'JWT' })).toString('base64url');
    expect(verifyAccessToken(`${none}.${p}.`, SECRET, now)).toBeNull();
    expect(verifyAccessToken('garbage', SECRET, now)).toBeNull();
  });
});

describe('phone numbers and contacts', () => {
  it('normalises Nigerian formats to E.164', () => {
    for (const s of ['08031234567', '0803 123 4567', '+2348031234567', '2348031234567', '002348031234567']) {
      expect(normalizePhone(s), s).toBe('+2348031234567');
    }
  });

  it('rejects junk and wrong-length Nigerian numbers', () => {
    for (const s of ['', 'abc', '0803123', '+23480312345678', '123']) expect(normalizePhone(s), s).toBeNull();
  });

  it('requires 3 to 5 distinct contacts, none being the user', () => {
    const own = '+2348000000000';
    const mk = (n: number) => Array.from({ length: n }, (_, i) => ({ phone: `080311111${10 + i}` }));
    expect(() => validateContacts(mk(2), own)).toThrow(ContactError);
    expect(() => validateContacts(mk(6), own)).toThrow(ContactError);
    expect(validateContacts(mk(3), own)).toHaveLength(3);
    expect(() => validateContacts([...mk(2), { phone: '08000000000' }], own)).toThrow(/own number/);
    expect(() => validateContacts([...mk(2), { phone: '0803111111 0' }], own)).toThrow(/different/);
    expect(() => validateContacts([...mk(2), { phone: 'nope' }], own)).toThrow(/not valid/);
  });
});

describe('OTP service', () => {
  function setup() {
    let now = 1_700_000_000_000;
    const sms = new MockSmsProvider(500);
    const store = new MemoryOtpStore();
    let n = 0;
    const budget = new SmsBudgetGuard({ dailyLimitKobo: 1_000_000, emergencyReservePct: 20, perUserDailyKobo: 1_000_000 }, () => now);
    const otp = new OtpService(store, sms, new FieldCrypto(KEY_A, KEY_B), budget, () => `otp-${++n}`, () => now);
    const code = () => /(\d{6})/.exec(sms.sent.at(-1)!.text)![1]!;
    return { otp, sms, budget, code, advance: (ms: number) => (now += ms) };
  }
  const PHONE = '+2348031234567';

  it('sends a code and accepts it once', async () => {
    const t = setup();
    expect(await t.otp.request(PHONE)).toBe('sent');
    expect(t.sms.sent[0]!.to).toBe(PHONE);
    const c = t.code();
    expect(await t.otp.verify(PHONE, c)).toBe(true);
    expect(await t.otp.verify(PHONE, c)).toBe(false); // already used
  });

  it('rejects wrong codes, then locks the challenge after 5 attempts even for the right code', async () => {
    const t = setup();
    await t.otp.request(PHONE);
    const good = t.code();
    const bad = good === '000000' ? '111111' : '000000';
    for (let i = 0; i < 5; i++) expect(await t.otp.verify(PHONE, bad)).toBe(false);
    expect(await t.otp.verify(PHONE, good)).toBe(false);
  });

  it('expires after 5 minutes', async () => {
    const t = setup();
    await t.otp.request(PHONE);
    const c = t.code();
    t.advance(5 * 60_000 + 1);
    expect(await t.otp.verify(PHONE, c)).toBe(false);
  });

  it('only the newest code works', async () => {
    const t = setup();
    await t.otp.request(PHONE);
    const first = t.code();
    await t.otp.request(PHONE);
    const second = t.code();
    if (first !== second) expect(await t.otp.verify(PHONE, first)).toBe(false);
    expect(await t.otp.verify(PHONE, second)).toBe(true);
  });

  it('limits requests per number per hour', async () => {
    const t = setup();
    for (let i = 0; i < 5; i++) expect(await t.otp.request(PHONE)).toBe('sent');
    expect(await t.otp.request(PHONE)).toBe('rate_limited');
    t.advance(3_600_001);
    expect(await t.otp.request(PHONE)).toBe('sent');
  });

  it('refunds the budget if the SMS fails, and stops when the routine budget is gone', async () => {
    const t = setup();
    t.sms.failNext = true;
    expect(await t.otp.request(PHONE)).toBe('send_failed');
    expect(t.budget.spentKobo).toBe(0);
    const tiny = new OtpService(
      new MemoryOtpStore(), t.sms, new FieldCrypto(KEY_A, KEY_B),
      new SmsBudgetGuard({ dailyLimitKobo: 100, emergencyReservePct: 20, perUserDailyKobo: 100 }),
      () => 'x',
    );
    expect(await tiny.request(PHONE)).toBe('budget_exhausted');
  });
});

describe('auth + onboarding routes', () => {
  async function setup(devEcho = false) {
    const h = await harness();
    const sms = new MockSmsProvider(0);
    const users = new MemoryUserRepo(h.store);
    const fc = new FieldCrypto(KEY_A, KEY_B);
    const budget = new SmsBudgetGuard({ dailyLimitKobo: 1_000_000, emergencyReservePct: 20, perUserDailyKobo: 1_000_000 });
    let n = 0;
    const otp = new OtpService(new MemoryOtpStore(), sms, fc, budget, () => `o${++n}`);
    const auth = makeAuthenticator(SECRET, Date.now);
    const app = buildApp({
      engine: h.engine,
      authenticate: auth.userId,
      startLimiter: new FixedWindowLimiter(100, 60_000),
      ackLimiter: new FixedWindowLimiter(100, 60_000),
    });
    registerAuthRoutes(app, {
      otp, users, jwtSecret: SECRET, pinPepper: PEPPER, clock: Date.now, defaultCountryCode: '234',
      devLastCode: devEcho ? () => /(\d{6})/.exec(sms.sent.at(-1)?.text ?? '')?.[1] ?? null : undefined,
      ipLimiter: new FixedWindowLimiter(100, 60_000), authenticate: auth,
    });
    const key = Buffer.alloc(32, 7).toString('base64');
    const signIn = async (phone = '08031234567') => {
      await app.inject({ method: 'POST', url: '/v1/auth/otp/request', payload: { phone } });
      const code = /(\d{6})/.exec(sms.sent.at(-1)!.text)![1];
      return app.inject({
        method: 'POST', url: '/v1/auth/otp/verify',
        payload: { phone, code, platform: 'android', publicKey: key, boxPublicKey: key },
      });
    };
    return { h, app, sms, signIn };
  }

  it('the code is only echoed back when dev echo is on, and then it is the real one', async () => {
    const off = await setup();
    const r1 = await off.app.inject({ method: 'POST', url: '/v1/auth/otp/request', payload: { phone: '08031234567' } });
    expect(r1.json()).toEqual({ ok: true });
    const on = await setup(true);
    const r2 = await on.app.inject({ method: 'POST', url: '/v1/auth/otp/request', payload: { phone: '08031234567' } });
    const devCode = r2.json().devCode as string;
    expect(devCode).toMatch(/^\d{6}$/);
    expect(on.sms.sent.at(-1)!.text).toContain(devCode);
  });

  const contacts = [{ phone: '08031111111' }, { phone: '08032222222' }, { phone: '08033333333', locale: 'ha' }];

  it('full onboarding: verify phone, add contacts, set PINs, then an SOS uses them', async () => {
    const { h, app, signIn } = await setup();
    const res = await signIn();
    expect(res.statusCode).toBe(200);
    const { accessToken, isNew } = res.json();
    expect(isNew).toBe(true);
    const bearer = { authorization: `Bearer ${accessToken}` };

    expect((await app.inject({ method: 'PUT', url: '/v1/me/contacts', headers: bearer, payload: { contacts } })).json()).toEqual({ count: 3 });
    expect((await app.inject({ method: 'PUT', url: '/v1/me/pins', headers: bearer, payload: { cancelPin: '2580', duressPin: '0852' } })).statusCode).toBe(204);

    const sos = await app.inject({ method: 'POST', url: '/v1/sos', headers: bearer, payload: { trigger: 'floating', ...GEO } });
    expect(sos.statusCode).toBe(201);
    await h.sched.advance(5000);
    expect(h.notifier.messages.filter((m) => m.contact.phone.startsWith('+23480'))).toHaveLength(3);
    const pin = await app.inject({ method: 'POST', url: `/v1/sos/${sos.json().sosId}/pin`, headers: bearer, payload: { pin: '2580' } });
    expect(pin.json()).toEqual({ result: 'cancelled', keepTracking: false });
  });

  it('rejects bad OTPs and reports an unknown account the same way as a wrong code', async () => {
    const { app } = await setup();
    const r = await app.inject({
      method: 'POST', url: '/v1/auth/otp/verify',
      payload: { phone: '08031234567', code: '123456', platform: 'ios', publicKey: Buffer.alloc(32).toString('base64'), boxPublicKey: Buffer.alloc(32).toString('base64') },
    });
    expect(r.statusCode).toBe(401);
    expect(r.json()).toEqual({ error: 'invalid_code' });
  });

  it('refresh tokens rotate, and a replayed old one is refused', async () => {
    const { app, signIn } = await setup();
    const first = (await signIn()).json();
    const r1 = await app.inject({ method: 'POST', url: '/v1/auth/refresh', payload: { deviceId: first.deviceId, refreshToken: first.refreshToken } });
    expect(r1.statusCode).toBe(200);
    const replay = await app.inject({ method: 'POST', url: '/v1/auth/refresh', payload: { deviceId: first.deviceId, refreshToken: first.refreshToken } });
    expect(replay.statusCode).toBe(401);
    const r2 = await app.inject({ method: 'POST', url: '/v1/auth/refresh', payload: { deviceId: first.deviceId, refreshToken: r1.json().refreshToken } });
    expect(r2.statusCode).toBe(200);
  });

  it('onboarding endpoints need a valid bearer token', async () => {
    const { app } = await setup();
    for (const [method, url] of [['PUT', '/v1/me/contacts'], ['PUT', '/v1/me/pins'], ['PUT', '/v1/me/profile'], ['PUT', '/v1/me/push-token']] as const) {
      expect((await app.inject({ method, url, payload: {} })).statusCode, url).toBe(401);
    }
    const bad = await app.inject({ method: 'PUT', url: '/v1/me/pins', headers: { authorization: 'Bearer nope' }, payload: {} });
    expect(bad.statusCode).toBe(401);
  });

  it('validates contacts and PINs', async () => {
    const { app, signIn } = await setup();
    const bearer = { authorization: `Bearer ${(await signIn()).json().accessToken}` };
    const tooFew = await app.inject({ method: 'PUT', url: '/v1/me/contacts', headers: bearer, payload: { contacts: contacts.slice(0, 2) } });
    expect(tooFew.statusCode).toBe(400);
    expect(tooFew.json().error).toBe('invalid_contacts');
    const self = await app.inject({ method: 'PUT', url: '/v1/me/contacts', headers: bearer, payload: { contacts: [...contacts.slice(0, 2), { phone: '08031234567' }] } });
    expect(self.statusCode).toBe(400);
    const same = await app.inject({ method: 'PUT', url: '/v1/me/pins', headers: bearer, payload: { cancelPin: '2580', duressPin: '2580' } });
    expect(same.statusCode).toBe(400);
    const short = await app.inject({ method: 'PUT', url: '/v1/me/pins', headers: bearer, payload: { cancelPin: '12', duressPin: '0852' } });
    expect(short.statusCode).toBe(400);
  });

  it('refuses to change contacts while an alert is live, and allows it afterwards', async () => {
    const { app, signIn } = await setup();
    const bearer = { authorization: `Bearer ${(await signIn()).json().accessToken}` };
    await app.inject({ method: 'PUT', url: '/v1/me/contacts', headers: bearer, payload: { contacts } });
    await app.inject({ method: 'PUT', url: '/v1/me/pins', headers: bearer, payload: { cancelPin: '2580', duressPin: '0852' } });
    const { sosId } = (await app.inject({ method: 'POST', url: '/v1/sos', headers: bearer, payload: { trigger: 'shake' } })).json();
    const blocked = await app.inject({ method: 'PUT', url: '/v1/me/contacts', headers: bearer, payload: { contacts } });
    expect(blocked.statusCode).toBe(409);
    expect(blocked.json().error).toBe('sos_active');
    await app.inject({ method: 'POST', url: `/v1/sos/${sosId}/pin`, headers: bearer, payload: { pin: '2580' } });
    const ok = await app.inject({ method: 'PUT', url: '/v1/me/contacts', headers: bearer, payload: { contacts } });
    expect(ok.statusCode).toBe(200);
  });

  it('signing in again on a new phone reuses the account', async () => {
    const { signIn } = await setup();
    const a = (await signIn()).json();
    const b = (await signIn()).json();
    expect(b.isNew).toBe(false);
    expect(b.userId).toBe(a.userId);
    expect(b.deviceId).not.toBe(a.deviceId);
  });
});
