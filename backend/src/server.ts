import { randomUUID } from 'node:crypto';
import type { Pool } from 'pg';
import { loadConfig } from './config/env.js';
import { buildApp } from './app.js';
import { FieldCrypto } from './lib/field-crypto.js';
import { createPinPair } from './lib/pin.js';
import { FixedWindowLimiter } from './lib/rate-limit.js';
import { TimerScheduler } from './lib/scheduler.js';
import { createPool, migrate } from './db/migrate.js';
import { HashChainAudit } from './modules/audit/audit.js';
import { PgAudit } from './modules/audit/pg-audit.js';
import { MemoryUserRepo } from './modules/auth/memory-user-repo.js';
import { MemoryOtpStore, OtpService, type OtpStore } from './modules/auth/otp.js';
import { PgUserRepo, type UserRepo } from './modules/auth/pg-user-repo.js';
import { makeAuthenticator, registerAuthRoutes } from './modules/auth/routes.js';
import { SmsBudgetGuard } from './modules/budget/budget.js';
import { InMemoryDirectory, type Directory } from './modules/dispatch/directory.js';
import { LogOnlyChannel, PoliceDispatcher, SmsDispatchChannel } from './modules/dispatch/dispatcher.js';
import { PgDirectory } from './modules/dispatch/pg-directory.js';
import { FcmPushSender, type ServiceAccount } from './modules/notify/fcm.js';
import { PgPushTokens } from './modules/notify/pg-push-tokens.js';
import { ContactNotifier, NoopPushSender, type PushSender } from './modules/notify/contact-notifier.js';
import { MemoryAdminActions, MemoryAdminStore } from './modules/admin/memory-admin-store.js';
import { PgAdminActions, PgAdminStore } from './modules/admin/pg-admin-store.js';
import { registerAdminRoutes } from './modules/admin/routes.js';
import { AdminService } from './modules/admin/service.js';
import { InboxService } from './modules/inbox/service.js';
import { registerInboxRoutes } from './modules/inbox/routes.js';
import { MemoryInbox } from './modules/inbox/memory-inbox.js';
import { PgInbox } from './modules/inbox/pg-inbox.js';
import type { InboxStore } from './modules/inbox/types.js';
import { MemoryShares } from './modules/share/memory-share.js';
import { PgShares } from './modules/share/pg-share.js';
import { registerShareRoutes } from './modules/share/routes.js';
import { ShareService } from './modules/share/service.js';
import type { ShareStore } from './modules/share/types.js';
import { CachedGeocoder, NominatimGeocoder } from './modules/geo/geocoder.js';
import { PgAdvisoryLock, pgRetentionTasks } from './modules/retention/pg-retention.js';
import { RetentionJob } from './modules/retention/retention.js';
import { SosEngine } from './modules/sos/engine.js';
import { MemorySosStore } from './modules/sos/memory-store.js';
import { PgSosStore } from './modules/sos/pg-store.js';
import { BullScheduler, createRedis, engineJobHandler } from './queue/bull-scheduler.js';
import { TelegramBotApi } from './modules/telegram/api.js';
import { TelegramLoginBot } from './modules/telegram/bot.js';
import { registerTelegramRoutes } from './modules/telegram/routes.js';
import { deriveWebhookSecret } from './modules/telegram/secret.js';
import { MockSmsProvider, type SmsProvider } from './providers/sms/SmsProvider.js';
import { TermiiSmsProvider } from './providers/sms/TermiiProvider.js';
import type { AuditSink, Scheduler, SosStore } from './domain/types.js';

const env = loadConfig();
const clock = () => Date.now();
const log = {
  info: (o: Record<string, unknown>, m?: string) => console.info(m ?? '', o),
  warn: (o: Record<string, unknown>, m?: string) => console.warn(m ?? '', o),
  error: (o: Record<string, unknown>, m?: string) => console.error(m ?? '', o),
};

const sms: SmsProvider =
  env.SMS_PROVIDER === 'termii'
    ? new TermiiSmsProvider({
        apiKey: env.TERMII_API_KEY!,
        senderId: env.TERMII_SENDER_ID!,
        baseUrl: env.TERMII_BASE_URL,
        channel: env.TERMII_CHANNEL,
        estCostKobo: env.SMS_COST_KOBO_ESTIMATE,
      })
    : new MockSmsProvider(env.SMS_COST_KOBO_ESTIMATE);

const budget = new SmsBudgetGuard(
  {
    dailyLimitKobo: env.SMS_DAILY_BUDGET_KOBO,
    emergencyReservePct: env.SMS_EMERGENCY_RESERVE_PCT,
    perUserDailyKobo: env.SMS_PER_USER_DAILY_KOBO,
  },
  clock,
);

// ---- storage: memory (dev/tests) or postgres + redis (real) ----
let store: SosStore;
let audit: AuditSink;
let directory: Directory;
let users: UserRepo;
let otpStore: OtpStore;
let scheduler: Scheduler;
let pool: Pool | undefined;
let inboxStore: InboxStore;
let shareStore: ShareStore;
let bull: BullScheduler | undefined;
const fc = new FieldCrypto(env.DATA_KEY ?? '00'.repeat(32), env.PHONE_HMAC_KEY ?? '11'.repeat(32));
let memoryStore: MemorySosStore | undefined;

if (env.STORE === 'postgres') {
  pool = createPool(env.DATABASE_URL!);
  const applied = await migrate(pool);
  if (applied.length) log.info({ applied }, 'migrations applied');
  const repo = new PgUserRepo(pool, fc, clock);
  store = new PgSosStore(pool, fc);
  inboxStore = new PgInbox(pool, fc);
  shareStore = new PgShares(pool);
  audit = new PgAudit(pool, clock);
  directory = new PgDirectory(pool);
  users = repo;
  otpStore = repo;
  bull = new BullScheduler(createRedis(env.REDIS_URL!), log);
  scheduler = bull;
} else {
  memoryStore = new MemorySosStore();
  store = memoryStore;
  inboxStore = new MemoryInbox(memoryStore);
  shareStore = new MemoryShares();
  audit = new HashChainAudit(clock);
  // Empty on purpose: entries must come from verified official sources.
  directory = new InMemoryDirectory([], null);
  users = new MemoryUserRepo(memoryStore);
  otpStore = new MemoryOtpStore();
  scheduler = new TimerScheduler((e) => log.error({ err: e instanceof Error ? e.message : 'unknown' }, 'job failed'));
}

let push: PushSender = new NoopPushSender();
if (env.PUSH_PROVIDER === 'fcm') {
  if (!pool) throw new Error('PUSH_PROVIDER=fcm needs STORE=postgres');
  const account = JSON.parse(Buffer.from(env.FCM_SERVICE_ACCOUNT_B64!, 'base64').toString('utf8')) as ServiceAccount;
  push = new FcmPushSender(new PgPushTokens(pool, fc), account, fetch, clock, log);
}

// The inbox service needs the engine (to read and answer alerts) and the engine needs the notifier
// (which delivers through the inbox service), so the notifier gets the service after the engine exists.
let inboxService!: InboxService;
const notifier = new ContactNotifier({ deliver: (m) => inboxService.deliver(m), over: (s, r) => inboxService.alertOver(s, r) }, push, log);
const dispatcher = new PoliceDispatcher(
  directory,
  env.DISPATCH_MODE === 'sms' ? new SmsDispatchChannel(sms) : new LogOnlyChannel(),
  audit,
  { includeUserPhone: env.DISPATCH_INCLUDE_USER_PHONE },
  log,
);

const engine = new SosEngine({
  store,
  scheduler,
  notifier,
  dispatcher,
  audit,
  lowBatteryLimiter: new FixedWindowLimiter(1, 30 * 60_000, clock),
  clock,
  newId: randomUUID,
  log,
  cfg: {
    cancelWindowMs: env.CANCEL_WINDOW_MS,
    repeatMs: env.REPEAT_INTERVAL_MS,
    maxRepeats: env.MAX_REPEATS,
    offlineAfterMs: env.OFFLINE_AFTER_MS,
    pinMaxAttempts: env.PIN_MAX_ATTEMPTS,
    pinLockoutMs: env.PIN_LOCKOUT_MS,
    retentionMs: env.RETENTION_HOURS * 3_600_000,
    baseUrl: env.PUBLIC_BASE_URL,
    tokenSecret: env.TOKEN_SECRET,
    pinPepper: Buffer.from(env.PIN_PEPPER, 'utf8'),
  },
});
inboxService = new InboxService(store, inboxStore, push, engine, {
  retentionMs: env.RETENTION_HOURS * 3_600_000,
  clock,
  newId: randomUUID,
  testLimiter: new FixedWindowLimiter(1, 10 * 60_000, clock),
  shares: shareStore,
  log,
});
const shareService = new ShareService(store, inboxStore, shareStore, push, {
  clock,
  newId: randomUUID,
  retentionMs: env.RETENTION_HOURS * 3_600_000,
  log,
});
setInterval(() => void shareService.expireDue().catch((e) => log.error({ err: e instanceof Error ? e.message : 'unknown' }, 'share expiry failed')), 60_000).unref();
bull?.start(engineJobHandler(engine));

const pepper = Buffer.from(env.PIN_PEPPER, 'utf8');
if (env.DEV_SEED && memoryStore) {
  const pins = await createPinPair('1234', '4321', pepper);
  memoryStore.addUser({ id: 'demo-user', phone: '+2340000000000', locale: 'en' }, pins, [
    { id: 'c1', userId: 'demo-user', phone: '+2340000000001', locale: 'en', hasApp: false, priority: 0 },
    { id: 'c2', userId: 'demo-user', phone: '+2340000000002', locale: 'pcm', hasApp: false, priority: 1 },
    { id: 'c3', userId: 'demo-user', phone: '+2340000000003', locale: 'ha', hasApp: false, priority: 2 },
  ]);
  log.info({}, 'dev seed loaded: send header x-dev-user-id: demo-user');
}

const auth = makeAuthenticator(env.JWT_SECRET ?? env.TOKEN_SECRET, clock);
const otp = new OtpService(otpStore, sms, fc, budget, randomUUID, clock);

const geocoder =
  env.GEOCODER === 'nominatim' && env.NOMINATIM_URL ? new CachedGeocoder(new NominatimGeocoder(env.NOMINATIM_URL)) : undefined;

const app = buildApp({
  engine,
  geocoder,
  geoLimiter: new FixedWindowLimiter(30, 60_000, clock),
  authenticate: async (req) => {
    const fromJwt = await auth.userId(req);
    if (fromJwt) return fromJwt;
    // Dev-only shortcut, only reachable with the in-memory store outside production.
    if (env.DEV_SEED && env.NODE_ENV !== 'production') {
      const v = req.headers['x-dev-user-id'];
      if (typeof v === 'string' && v) return v;
    }
    return null;
  },
  startLimiter: new FixedWindowLimiter(10, 3_600_000, clock),
  ackLimiter: new FixedWindowLimiter(60, 60_000, clock),
  logger: false,
  trustProxyHops: env.TRUST_PROXY_HOPS,
  globalLimiter: new FixedWindowLimiter(env.GLOBAL_RATE_PER_MIN, 60_000, clock),
  hsts: env.NODE_ENV === 'production',
});

// Admin API (off unless ADMIN_JWT_SECRET is set). Two-person approval for anything sensitive.
if (env.ADMIN_JWT_SECRET) {
  const adminStore = pool ? new PgAdminStore(pool) : new MemoryAdminStore();
  const actions = pool ? new PgAdminActions(pool) : new MemoryAdminActions(memoryStore!);
  registerAdminRoutes(app, {
    admin: new AdminService(adminStore, actions, audit, fc, env.ADMIN_JWT_SECRET, clock),
    loginLimiter: new FixedWindowLimiter(10, 15 * 60_000, clock),
  });
  log.info({}, 'admin API enabled');
}

// Sign-up codes through Telegram (OTP_PROVIDER=telegram). Only the code goes this way; SOS alerts never use the bot.
const telegramApi = env.OTP_PROVIDER === 'telegram' ? new TelegramBotApi(env.TELEGRAM_BOT_TOKEN!) : undefined;
// Unless TELEGRAM_WEBHOOK_SECRET is set, the webhook secret is derived from TOKEN_SECRET.
const telegramSecret = env.TELEGRAM_WEBHOOK_SECRET ?? deriveWebhookSecret(env.TOKEN_SECRET);
if (telegramApi) {
  registerTelegramRoutes(app, {
    bot: new TelegramLoginBot({
      api: telegramApi,
      otp,
      defaultCountryCode: env.DEFAULT_COUNTRY_CODE,
      chatLimiter: new FixedWindowLimiter(30, 60_000, clock),
      log,
    }),
    secret: telegramSecret,
  });
}

registerAuthRoutes(app, {
  otp,
  telegramLoginUrl: telegramApi ? `https://t.me/${env.TELEGRAM_BOT_USERNAME!}?start=login` : undefined,
  devLastCode:
    env.OTP_DEV_ECHO && sms instanceof MockSmsProvider
      ? () => /\b(\d{6})\b/.exec(sms.sent.at(-1)?.text ?? '')?.[1] ?? null
      : undefined,
  users,
  jwtSecret: env.JWT_SECRET ?? env.TOKEN_SECRET,
  pinPepper: pepper,
  clock,
  defaultCountryCode: env.DEFAULT_COUNTRY_CODE,
  ipLimiter: new FixedWindowLimiter(20, 3_600_000, clock),
  authenticate: auth,
});

registerInboxRoutes(app, {
  service: inboxService,
  authenticate: async (req) => auth.userId(req),
  limiter: new FixedWindowLimiter(120, 60_000, clock),
});

registerShareRoutes(app, {
  service: shareService,
  authenticate: async (req) => auth.userId(req),
  limiter: new FixedWindowLimiter(60, 60_000, clock),
  updateLimiter: new FixedWindowLimiter(120, 60_000, clock),
  clock,
});

// Dev convenience: with the mock SMS provider, print OTP texts so you can sign in locally.
if (env.OTP_DEV_ECHO && sms instanceof MockSmsProvider) {
  const orig = sms.send.bind(sms);
  sms.send = async (m) => {
    console.info('[dev] sms ->', m.to, m.text);
    return orig(m);
  };
}

// Retention (Postgres mode): hourly cleanup of finished SOS events, old OTPs, revoked devices and
// deleted accounts. One replica runs it at a time (advisory lock).
const retention =
  store instanceof PgSosStore && pool
    ? new RetentionJob(
        pgRetentionTasks(pool, (now) => (store as PgSosStore).purgeExpired(now), (now) => inboxStore.purge(now), (now) => shareStore.purge(now)),
        new PgAdvisoryLock(pool),
        clock,
        log,
      )
    : undefined;
retention?.start();

await app.listen({ port: env.PORT, host: '0.0.0.0' });
log.info({ port: env.PORT, store: env.STORE }, 'sentri backend listening');

// Tell Telegram where to deliver bot messages. Best effort: if it fails the server still runs, and the failure is logged.
if (telegramApi) {
  const hook = `${env.PUBLIC_BASE_URL.replace(/\/+$/, '')}/v1/telegram/webhook`;
  telegramApi.setWebhook(hook, telegramSecret).then(
    () => log.info({}, 'telegram webhook set'),
    (e) => log.error({ err: e instanceof Error ? e.message : 'unknown' }, 'telegram webhook not set'),
  );
}

// Graceful shutdown: stop taking requests, then let queue workers and the pool finish.
for (const sig of ['SIGINT', 'SIGTERM'] as const) {
  process.on(sig, async () => {
    retention?.stop();
    await app.close();
    await bull?.close();
    await pool?.end();
    process.exit(0);
  });
}
