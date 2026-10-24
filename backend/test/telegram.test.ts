import { describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';
import { EnvSchema, loadConfig, toHexKey } from '../src/config/env.js';
import { FieldCrypto } from '../src/lib/field-crypto.js';
import { FixedWindowLimiter } from '../src/lib/rate-limit.js';
import { MemoryUserRepo } from '../src/modules/auth/memory-user-repo.js';
import { MemoryOtpStore, OtpService } from '../src/modules/auth/otp.js';
import { makeAuthenticator, registerAuthRoutes } from '../src/modules/auth/routes.js';
import { SmsBudgetGuard } from '../src/modules/budget/budget.js';
import { TelegramBotApi, type ShareButton, type TelegramApi } from '../src/modules/telegram/api.js';
import { TelegramLoginBot } from '../src/modules/telegram/bot.js';
import { registerTelegramRoutes } from '../src/modules/telegram/routes.js';
import { deriveWebhookSecret } from '../src/modules/telegram/secret.js';
import { MockSmsProvider } from '../src/providers/sms/SmsProvider.js';
import { PEPPER, harness } from './helpers.js';

const SECRET = 's'.repeat(32);
const KEY_A = 'a'.repeat(64);
const KEY_B = 'b'.repeat(64);
const TOKEN = '123456789:AAEhBP0av28HqcP_x9mKj2nV7sLwQ4tYzXc';
const HOOK_SECRET = 'webhook-secret-0123456789';
const PHONE = '+2349024804472';

class FakeTelegram implements TelegramApi {
  sent: { chatId: number; html: string; button?: ShareButton }[] = [];
  failNext = false;
  async sendMessage(chatId: number, html: string, button?: ShareButton): Promise<void> {
    if (this.failNext) {
      this.failNext = false;
      throw new Error('telegram sendMessage failed: network');
    }
    this.sent.push({ chatId, html, button });
  }
  async setWebhook(): Promise<void> {}
  codeOf(i = -1): string | undefined {
    return /<code>(\d{6})<\/code>/.exec(this.sent.at(i)?.html ?? '')?.[1];
  }
}

function core(opts: { chatMax?: number } = {}) {
  const api = new FakeTelegram();
  const sms = new MockSmsProvider(0);
  const fc = new FieldCrypto(KEY_A, KEY_B);
  const budget = new SmsBudgetGuard({ dailyLimitKobo: 1_000_000, emergencyReservePct: 20, perUserDailyKobo: 1_000_000 });
  let n = 0;
  const otp = new OtpService(new MemoryOtpStore(), sms, fc, budget, () => `o${++n}`);
  const bot = new TelegramLoginBot({
    api,
    otp,
    defaultCountryCode: '234',
    chatLimiter: new FixedWindowLimiter(opts.chatMax ?? 100, 60_000),
  });
  return { api, sms, otp, bot, budget };
}

const contactUpdate = (over: { chat?: Record<string, unknown>; from?: Record<string, unknown> | null; contact?: Record<string, unknown> } = {}) => ({
  update_id: 1,
  message: {
    message_id: 1,
    chat: { id: 5, type: 'private', ...over.chat },
    ...(over.from === null ? {} : { from: { id: 5, is_bot: false, ...over.from } }),
    contact: { phone_number: '2349024804472', first_name: 'Vic', user_id: 5, ...over.contact },
  },
});

describe('login bot', () => {
  it("sends a code for the person's own number, with no SMS, and the code signs them in", async () => {
    const { api, sms, otp, bot } = core();
    await bot.handle(contactUpdate());
    expect(api.sent).toHaveLength(1);
    expect(api.sent[0]!.chatId).toBe(5);
    expect(api.sent[0]!.button?.text).toBe('Get a new code');
    const code = api.codeOf()!;
    expect(code).toMatch(/^\d{6}$/);
    expect(sms.sent).toHaveLength(0);
    expect(await otp.verify(PHONE, code)).toBe(true);
    expect(await otp.verify(PHONE, code)).toBe(false); // cannot be used twice
  });

  it('accepts the number however Telegram formats it', async () => {
    const { api, otp, bot } = core();
    await bot.handle(contactUpdate({ contact: { phone_number: '+234 902 480 4472' } }));
    expect(await otp.verify(PHONE, api.codeOf()!)).toBe(true);
  });

  it("refuses someone else's contact card and makes no code", async () => {
    const { api, otp, bot } = core();
    await bot.handle(contactUpdate({ contact: { user_id: 99 } }));
    expect(api.codeOf()).toBeUndefined();
    expect(api.sent).toHaveLength(1);
    expect(api.sent[0]!.html).toContain('own');
    expect(api.sent[0]!.button?.text).toBe('Share my number');
    expect(await otp.verify(PHONE, '123456')).toBe(false);
  });

  it('refuses a contact that carries no user id', async () => {
    const { api, bot } = core();
    const u = contactUpdate();
    delete (u.message.contact as { user_id?: number }).user_id;
    await bot.handle(u);
    expect(api.codeOf()).toBeUndefined();
    expect(api.sent[0]!.html).toContain('own');
  });

  it('says so when the number cannot be used', async () => {
    const { api, bot } = core();
    await bot.handle(contactUpdate({ contact: { phone_number: '12345' } }));
    expect(api.codeOf()).toBeUndefined();
    expect(api.sent[0]!.html).toContain('cannot use that number');
  });

  it('stops after 5 codes an hour for one number and says so', async () => {
    const { api, bot } = core();
    for (let i = 0; i < 5; i++) await bot.handle(contactUpdate());
    expect(api.sent.filter((m) => m.html.includes('<code>'))).toHaveLength(5);
    await bot.handle(contactUpdate());
    expect(api.sent).toHaveLength(6);
    expect(api.sent[5]!.html).toContain('Too many codes');
    expect(api.codeOf()).toBeUndefined();
  });

  it('answers each person only so often', async () => {
    const { api, bot } = core({ chatMax: 2 });
    for (let i = 0; i < 4; i++) await bot.handle({ message: { chat: { id: 5, type: 'private' }, from: { id: 5 }, text: '/start' } });
    expect(api.sent).toHaveLength(2);
  });

  it('shows the welcome and the share button on /start', async () => {
    const { api, bot } = core();
    await bot.handle({ message: { chat: { id: 5, type: 'private' }, from: { id: 5 }, text: '/start login' } });
    expect(api.sent).toHaveLength(1);
    expect(api.sent[0]!.html).toContain('Share my number');
    expect(api.sent[0]!.button?.text).toBe('Share my number');
  });

  it('ignores groups, bots, updates with no sender, and other kinds of update', async () => {
    const { api, bot } = core();
    await bot.handle(contactUpdate({ chat: { type: 'group' } }));
    await bot.handle(contactUpdate({ chat: { type: 'supergroup' } }));
    await bot.handle(contactUpdate({ from: { is_bot: true } }));
    await bot.handle(contactUpdate({ from: null }));
    await bot.handle({ edited_message: { chat: { id: 5, type: 'private' }, from: { id: 5 } } });
    expect(api.sent).toHaveLength(0);
  });

  it('never throws, whatever it is given', async () => {
    const { bot } = core();
    for (const junk of [null, undefined, 'x', 42, [], {}, { message: 'no' }, { message: { chat: {} } }]) {
      await expect(bot.handle(junk)).resolves.toBeUndefined();
    }
  });

  it('survives Telegram failing to deliver, and does not leave the person locked out', async () => {
    const { api, bot } = core();
    api.failNext = true;
    await expect(bot.handle(contactUpdate())).resolves.toBeUndefined();
    expect(api.sent).toHaveLength(0);
    await bot.handle(contactUpdate()); // asking again works
    expect(api.codeOf()).toMatch(/^\d{6}$/);
  });

  it('never touches the SMS budget', async () => {
    const { bot, budget } = core();
    const before = (budget as unknown as { spent: number }).spent;
    for (let i = 0; i < 3; i++) await bot.handle(contactUpdate());
    expect((budget as unknown as { spent: number }).spent).toBe(before);
  });
});

describe('Telegram API client', () => {
  type Call = { url: string; body: Record<string, unknown> };
  const okFetch = (calls: Call[], reply: unknown = { ok: true, result: true }, status = 200) =>
    (async (url: string, init: { body: string }) => {
      calls.push({ url, body: JSON.parse(init.body) as Record<string, unknown> });
      return { ok: status >= 200 && status < 300, status, json: async () => reply };
    }) as unknown as ConstructorParameters<typeof TelegramBotApi>[1];

  it('sends a message with the share-my-number button', async () => {
    const calls: Call[] = [];
    await new TelegramBotApi(TOKEN, okFetch(calls)).sendMessage(5, 'hi <b>there</b>', { text: 'Share my number' });
    expect(calls[0]!.url).toBe(`https://api.telegram.org/bot${TOKEN}/sendMessage`);
    expect(calls[0]!.body).toMatchObject({ chat_id: 5, text: 'hi <b>there</b>', parse_mode: 'HTML' });
    expect(calls[0]!.body.reply_markup).toEqual({
      keyboard: [[{ text: 'Share my number', request_contact: true }]],
      resize_keyboard: true,
      one_time_keyboard: false,
    });
  });

  it('sends no keyboard when there is no button', async () => {
    const calls: Call[] = [];
    await new TelegramBotApi(TOKEN, okFetch(calls)).sendMessage(5, 'hi');
    expect(calls[0]!.body.reply_markup).toBeUndefined();
  });

  it('sets the webhook with the secret and only asks for messages', async () => {
    const calls: Call[] = [];
    await new TelegramBotApi(TOKEN, okFetch(calls)).setWebhook('https://api.example.com/v1/telegram/webhook', HOOK_SECRET);
    expect(calls[0]!.url).toBe(`https://api.telegram.org/bot${TOKEN}/setWebhook`);
    expect(calls[0]!.body).toMatchObject({ url: 'https://api.example.com/v1/telegram/webhook', secret_token: HOOK_SECRET, allowed_updates: ['message'] });
  });

  it('fails on an error status, and the error never contains the bot token', async () => {
    const err = await new TelegramBotApi(TOKEN, okFetch([], { ok: false }, 401)).sendMessage(5, 'x').catch((e: Error) => e);
    expect(err).toBeInstanceOf(Error);
    expect((err as Error).message).toContain('401');
    expect((err as Error).message).not.toContain(TOKEN);
  });

  it('fails when Telegram answers ok:false or not JSON', async () => {
    await expect(new TelegramBotApi(TOKEN, okFetch([], { ok: false })).sendMessage(5, 'x')).rejects.toThrow(/failed/);
    const notJson = (async () => ({ ok: true, status: 200, json: async () => { throw new Error('bad json'); } })) as unknown as ConstructorParameters<typeof TelegramBotApi>[1];
    await expect(new TelegramBotApi(TOKEN, notJson).sendMessage(5, 'x')).rejects.toThrow(/failed/);
  });

  it('hides the token even when the network error mentions the address', async () => {
    const boom = (async (url: string) => {
      throw new Error(`connect ECONNREFUSED ${url}`);
    }) as unknown as ConstructorParameters<typeof TelegramBotApi>[1];
    const err = await new TelegramBotApi(TOKEN, boom).sendMessage(5, 'x').catch((e: Error) => e);
    expect((err as Error).message).toBe('telegram sendMessage failed: network');
    expect(JSON.stringify(err)).not.toContain(TOKEN);
  });

  it('gives up after the timeout', async () => {
    const hang = ((url: string, init: { signal: AbortSignal }) =>
      new Promise((_, reject) => init.signal.addEventListener('abort', () => reject(new Error(`aborted ${url}`))))) as unknown as ConstructorParameters<typeof TelegramBotApi>[1];
    const err = await new TelegramBotApi(TOKEN, hang, 25).sendMessage(5, 'x').catch((e: Error) => e);
    expect((err as Error).message).toBe('telegram sendMessage failed: network');
  });
});

describe('webhook route', () => {
  async function setup() {
    const h = await harness();
    const { api, bot } = core();
    const app = buildApp({
      engine: h.engine,
      authenticate: async () => null,
      startLimiter: new FixedWindowLimiter(100, 60_000),
    });
    registerTelegramRoutes(app, { bot, secret: HOOK_SECRET });
    const post = (headers: Record<string, string>, payload: unknown) =>
      app.inject({ method: 'POST', url: '/v1/telegram/webhook', headers, payload: payload as object });
    return { api, post };
  }

  it('rejects calls without the right secret, and does nothing for them', async () => {
    const { api, post } = await setup();
    expect((await post({}, contactUpdate())).statusCode).toBe(401);
    expect((await post({ 'x-telegram-bot-api-secret-token': 'wrong' }, contactUpdate())).statusCode).toBe(401);
    expect((await post({ 'x-telegram-bot-api-secret-token': HOOK_SECRET + 'x' }, contactUpdate())).statusCode).toBe(401);
    expect(api.sent).toHaveLength(0);
  });

  it('accepts a call with the right secret and hands the update to the bot', async () => {
    const { api, post } = await setup();
    const r = await post({ 'x-telegram-bot-api-secret-token': HOOK_SECRET }, contactUpdate());
    expect(r.statusCode).toBe(200);
    expect(api.codeOf()).toMatch(/^\d{6}$/);
  });

  it('answers 200 even for an update the bot ignores', async () => {
    const { api, post } = await setup();
    const r = await post({ 'x-telegram-bot-api-secret-token': HOOK_SECRET }, contactUpdate({ chat: { type: 'group' } }));
    expect(r.statusCode).toBe(200);
    expect(api.sent).toHaveLength(0);
  });

  it('refuses a body over 64 KB', async () => {
    const { post } = await setup();
    const r = await post({ 'x-telegram-bot-api-secret-token': HOOK_SECRET }, { pad: 'x'.repeat(70_000) });
    expect(r.statusCode).toBe(413);
  });
});

describe('sign-up through Telegram', () => {
  async function setup() {
    const h = await harness();
    const { api, sms, otp, bot } = core();
    const users = new MemoryUserRepo(h.store);
    const auth = makeAuthenticator(SECRET, Date.now);
    const app = buildApp({ engine: h.engine, authenticate: auth.userId, startLimiter: new FixedWindowLimiter(100, 60_000) });
    registerAuthRoutes(app, {
      otp,
      users,
      jwtSecret: SECRET,
      pinPepper: PEPPER,
      clock: Date.now,
      defaultCountryCode: '234',
      telegramLoginUrl: 'https://t.me/sentri_login_bot?start=login',
      ipLimiter: new FixedWindowLimiter(100, 60_000),
      authenticate: auth,
    });
    registerTelegramRoutes(app, { bot, secret: HOOK_SECRET });
    const key = Buffer.alloc(32, 7).toString('base64');
    const verify = (phone: string, code: string) =>
      app.inject({ method: 'POST', url: '/v1/auth/otp/verify', payload: { phone, code, platform: 'android', publicKey: key, boxPublicKey: key } });
    const request = (phone: string) => app.inject({ method: 'POST', url: '/v1/auth/otp/request', payload: { phone } });
    return { app, api, sms, bot, verify, request };
  }

  it('request sends nothing and answers with the bot link', async () => {
    const { request, sms, api } = await setup();
    const r = await request('08031234567');
    expect(r.statusCode).toBe(202);
    expect(r.json()).toEqual({ ok: true, telegramUrl: 'https://t.me/sentri_login_bot?start=login' });
    expect(sms.sent).toHaveLength(0);
    expect(api.sent).toHaveLength(0);
  });

  it('gives the same answer for every valid number, and refuses a bad one', async () => {
    const { request } = await setup();
    const a = await request('08031234567');
    const b = await request('+2347012345678');
    expect(a.json()).toEqual(b.json());
    expect((await request('abc')).statusCode).toBe(400);
  });

  it('a full sign-in works: request, share number in Telegram, type the code', async () => {
    const { request, bot, api, verify } = await setup();
    await request('0902 480 4472');
    await bot.handle(contactUpdate());
    const r = await verify('0902 480 4472', api.codeOf()!);
    expect(r.statusCode).toBe(200);
    const body = r.json();
    expect(body.accessToken).toEqual(expect.any(String));
    expect(body.isNew).toBe(true);
  });

  it('a code made for one number cannot sign in another', async () => {
    const { bot, api, verify } = await setup();
    await bot.handle(contactUpdate());
    const code = api.codeOf()!;
    expect((await verify('08031234567', code)).statusCode).toBe(401);
    expect((await verify(PHONE, code)).statusCode).toBe(200);
  });

  it('typing a number in the app does not let anyone get its code', async () => {
    const { request, bot, api, verify } = await setup();
    await request('08031234567'); // the attacker types the victim's number...
    await bot.handle(contactUpdate({ contact: { phone_number: '2348031234567', user_id: 77 } })); // ...and shares the victim's contact card
    expect(api.codeOf()).toBeUndefined();
    expect((await verify('08031234567', '000000')).statusCode).toBe(401);
  });

  it('works through the webhook end to end', async () => {
    const { app, api, verify } = await setup();
    const r = await app.inject({
      method: 'POST',
      url: '/v1/telegram/webhook',
      headers: { 'x-telegram-bot-api-secret-token': HOOK_SECRET },
      payload: contactUpdate() as object,
    });
    expect(r.statusCode).toBe(200);
    expect((await verify(PHONE, api.codeOf()!)).statusCode).toBe(200);
  });
});

describe('Telegram settings', () => {
  const dev = { PUBLIC_BASE_URL: 'https://api.example.com', TOKEN_SECRET: 't'.repeat(32), PIN_PEPPER: 'p'.repeat(32) };
  const tg = { OTP_PROVIDER: 'telegram', TELEGRAM_BOT_TOKEN: TOKEN, TELEGRAM_BOT_USERNAME: 'sentri_login_bot', TELEGRAM_WEBHOOK_SECRET: HOOK_SECRET };

  it('defaults to SMS and needs no Telegram settings then', () => {
    const r = EnvSchema.safeParse(dev);
    expect(r.success && r.data.OTP_PROVIDER).toBe('sms');
  });

  it('treats empty Telegram variables as not set when SMS is used', () => {
    expect(EnvSchema.safeParse({ ...dev, TELEGRAM_BOT_TOKEN: '', TELEGRAM_BOT_USERNAME: '', TELEGRAM_WEBHOOK_SECRET: '' }).success).toBe(true);
  });

  it('accepts a full Telegram setup', () => {
    expect(EnvSchema.safeParse({ ...dev, ...tg }).success).toBe(true);
  });

  it.each(['TELEGRAM_BOT_TOKEN', 'TELEGRAM_BOT_USERNAME'])('needs %s in Telegram mode', (k) => {
    const env: Record<string, string> = { ...dev, ...tg };
    delete env[k];
    expect(EnvSchema.safeParse(env).success).toBe(false);
    expect(EnvSchema.safeParse({ ...env, [k]: '' }).success).toBe(false);
  });

  it.each([
    ['token without a colon', { TELEGRAM_BOT_TOKEN: 'notatoken' }],
    ['token that is too short', { TELEGRAM_BOT_TOKEN: '123456:short' }],
    ['username with a dash', { TELEGRAM_BOT_USERNAME: 'sentri-bot' }],
    ['username that is too short', { TELEGRAM_BOT_USERNAME: 'abc' }],
    ['webhook secret that is too short', { TELEGRAM_WEBHOOK_SECRET: 'short' }],
    ['webhook secret with a space', { TELEGRAM_WEBHOOK_SECRET: 'has a space in it 1234' }],
  ])('refuses a %s', (_n, over) => {
    expect(EnvSchema.safeParse({ ...dev, ...tg, ...over }).success).toBe(false);
  });

  it('does not need a webhook secret, because one is derived', () => {
    const env: Record<string, string> = { ...dev, ...tg };
    delete env.TELEGRAM_WEBHOOK_SECRET;
    expect(EnvSchema.safeParse(env).success).toBe(true);
    expect(EnvSchema.safeParse({ ...env, TELEGRAM_WEBHOOK_SECRET: '' }).success).toBe(true);
  });

  it('still checks a webhook secret when one is given', () => {
    expect(EnvSchema.safeParse({ ...dev, ...tg, TELEGRAM_WEBHOOK_SECRET: 'short' }).success).toBe(false);
  });

  it('refuses the dev code echo in Telegram mode', () => {
    expect(EnvSchema.safeParse({ ...dev, ...tg, OTP_DEV_ECHO: 'true' }).success).toBe(false);
  });

  it('works in production alongside a real SMS provider for alerts', () => {
    const prod = {
      ...dev,
      ...tg,
      NODE_ENV: 'production',
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
    expect(EnvSchema.safeParse(prod).success).toBe(true);
    expect(EnvSchema.safeParse({ ...prod, SMS_PROVIDER: 'mock' }).success).toBe(false); // alerts still need a real provider
  });
});

describe('derived webhook secret', () => {
  it('has the shape Telegram accepts', () => {
    const v = deriveWebhookSecret('t'.repeat(32));
    expect(v).toHaveLength(43);
    expect(v).toMatch(/^[A-Za-z0-9_-]{16,256}$/);
  });

  it('is the same every time for the same TOKEN_SECRET, so a restart does not break the webhook', () => {
    expect(deriveWebhookSecret('t'.repeat(32))).toBe(deriveWebhookSecret('t'.repeat(32)));
  });

  it('differs for another TOKEN_SECRET and never equals it', () => {
    expect(deriveWebhookSecret('a'.repeat(32))).not.toBe(deriveWebhookSecret('b'.repeat(32)));
    expect(deriveWebhookSecret('a'.repeat(32))).not.toBe('a'.repeat(32));
  });

  it('is accepted by the settings when used as TELEGRAM_WEBHOOK_SECRET', () => {
    const secret = deriveWebhookSecret('t'.repeat(32));
    const r = EnvSchema.safeParse({
      PUBLIC_BASE_URL: 'https://api.example.com',
      TOKEN_SECRET: 't'.repeat(32),
      PIN_PEPPER: 'p'.repeat(32),
      OTP_PROVIDER: 'telegram',
      TELEGRAM_BOT_TOKEN: TOKEN,
      TELEGRAM_BOT_USERNAME: 'sentri_login_bot',
      TELEGRAM_WEBHOOK_SECRET: secret,
    });
    expect(r.success).toBe(true);
  });
});

describe('public address on Render', () => {
  const base = { TOKEN_SECRET: 't'.repeat(32), PIN_PEPPER: 'p'.repeat(32) };

  it("uses Render's own address when PUBLIC_BASE_URL is not set", () => {
    expect(loadConfig({ ...base, RENDER_EXTERNAL_URL: 'https://sentri-api.onrender.com' }).PUBLIC_BASE_URL).toBe('https://sentri-api.onrender.com');
  });

  it('prefers PUBLIC_BASE_URL when it is set', () => {
    const c = loadConfig({ ...base, PUBLIC_BASE_URL: 'https://api.example.com', RENDER_EXTERNAL_URL: 'https://sentri-api.onrender.com' });
    expect(c.PUBLIC_BASE_URL).toBe('https://api.example.com');
  });

  it('falls back to Render when PUBLIC_BASE_URL is empty', () => {
    expect(loadConfig({ ...base, PUBLIC_BASE_URL: '', RENDER_EXTERNAL_URL: 'https://sentri-api.onrender.com' }).PUBLIC_BASE_URL).toBe('https://sentri-api.onrender.com');
  });

  it('still refuses to start with no public address at all', () => {
    expect(() => loadConfig({ ...base })).toThrow(/PUBLIC_BASE_URL/);
  });
});

describe('the Render Blueprint settings', () => {
  // Exactly what render.yaml sets, plus what Render adds (generated base64 secrets, its own address and port).
  const render = {
    NODE_ENV: 'development',
    STORE: 'memory',
    OTP_PROVIDER: 'telegram',
    SMS_PROVIDER: 'mock',
    TRUST_PROXY_HOPS: '1',
    TOKEN_SECRET: 'kQ3+9vXc/7Zl2mPq8RtYb1nVwE5uHjAsDfGhKlMn0Pw=',
    PIN_PEPPER: 'Zx8/Qw3+Er5TyUi7OpAs9DfGhJk1LzXcVbNm2QwErTy=',
    TELEGRAM_BOT_TOKEN: TOKEN,
    TELEGRAM_BOT_USERNAME: 'sentri_login_bot',
    RENDER_EXTERNAL_URL: 'https://sentri-api.onrender.com',
    PORT: '10000',
  };

  it('start the server in Telegram mode with Render\'s own address', () => {
    const c = loadConfig(render);
    expect(c.OTP_PROVIDER).toBe('telegram');
    expect(c.STORE).toBe('memory');
    expect(c.PUBLIC_BASE_URL).toBe('https://sentri-api.onrender.com');
    expect(c.PORT).toBe(10000);
    expect(c.TRUST_PROXY_HOPS).toBe(1);
    expect(c.TELEGRAM_WEBHOOK_SECRET).toBeUndefined();
  });

  it('give a webhook secret Telegram accepts, even from base64 secrets with + / =', () => {
    expect(deriveWebhookSecret(loadConfig(render).TOKEN_SECRET)).toMatch(/^[A-Za-z0-9_-]{16,256}$/);
  });

  it('would not start in production mode, which is why the Blueprint uses development', () => {
    expect(() => loadConfig({ ...render, NODE_ENV: 'production' })).toThrow();
  });
});

describe('secrets from a hosting dashboard', () => {
  const dev = { PUBLIC_BASE_URL: 'https://api.example.com', TOKEN_SECRET: 't'.repeat(32), PIN_PEPPER: 'p'.repeat(32) };
  const live = {
    ...dev,
    STORE: 'postgres',
    DATABASE_URL: 'postgres://u:p@db/sentri',
    REDIS_URL: 'redis://r:6379',
    JWT_SECRET: 'Hj7+Lk2/Mn9PqRs4TuVw6XyZa8BcDe0FgHi1JkLmNoP=',
  };
  const b64 = 'Qa1+Ws2/Ed3RfTg4YhUj5IkOl6PzXc7VbNm8AsDf9Gh=';

  it('accepts 32-byte keys as hex or as base64, and hands them on as hex', () => {
    const hex = 'ab'.repeat(32);
    expect(toHexKey(hex)).toBe(hex);
    expect(toHexKey(hex.toUpperCase())).toBe(hex);
    expect(toHexKey(b64)).toBe(Buffer.from(b64, 'base64').toString('hex'));
    expect(toHexKey(b64.replace(/\+/g, '-').replace(/\//g, '_'))).toBe(Buffer.from(b64, 'base64').toString('hex')); // base64url
    expect(toHexKey(b64.replace(/=$/, ''))).toBe(Buffer.from(b64, 'base64').toString('hex')); // no padding
  });

  it('refuses anything that is not exactly 32 bytes', () => {
    for (const bad of ['', 'short', 'zz'.repeat(32), 'ab'.repeat(31), 'ab'.repeat(33), 'A'.repeat(42), 'A'.repeat(45), `${b64}!`]) {
      expect(toHexKey(bad), bad).toBeNull();
    }
  });

  it('starts on the permanent database with Render-style base64 secrets', () => {
    const c = loadConfig({ ...live, DATA_KEY: b64, PHONE_HMAC_KEY: 'Zz9+Yy8/Xx7WwVv6UuTt5SsRr4QqPp3OoNn2MmLl1Kk=' });
    expect(c.STORE).toBe('postgres');
    expect(c.DATA_KEY).toMatch(/^[0-9a-f]{64}$/);
    expect(c.PHONE_HMAC_KEY).toMatch(/^[0-9a-f]{64}$/);
    expect(c.DATA_KEY).not.toBe(c.PHONE_HMAC_KEY);
  });

  it('refuses the permanent database without its keys, or with a bad key', () => {
    expect(() => loadConfig({ ...live })).toThrow(/DATA_KEY/);
    expect(() => loadConfig({ ...live, DATA_KEY: 'nope', PHONE_HMAC_KEY: b64 })).toThrow(/DATA_KEY/);
  });
});
