import { z } from 'zod';

const bool = z
  .enum(['true', 'false'])
  .default('false')
  .transform((v) => v === 'true');

/** Hosting dashboards often leave a variable set but empty. Treat that as "not set". */
const blankIsUnset = (v: unknown) => (v === '' ? undefined : v);

/** All configuration comes from the environment. No secrets live in code. */
export const EnvSchema = z
  .object({
    NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
    PORT: z.coerce.number().int().default(8080),
    PUBLIC_BASE_URL: z.string().url(),
    TOKEN_SECRET: z.string().min(32),
    PIN_PEPPER: z.string().min(32),

    CANCEL_WINDOW_MS: z.coerce.number().int().min(0).default(5000),
    REPEAT_INTERVAL_MS: z.coerce.number().int().min(1000).default(25000),
    MAX_REPEATS: z.coerce.number().int().min(1).default(240),
    OFFLINE_AFTER_MS: z.coerce.number().int().min(10000).default(90000),
    PIN_MAX_ATTEMPTS: z.coerce.number().int().min(3).default(5),
    PIN_LOCKOUT_MS: z.coerce.number().int().min(1000).default(300000),
    RETENTION_HOURS: z.coerce.number().int().min(1).default(72),

    /** Turns the admin API on. Must differ from the user token secrets. */
    ADMIN_JWT_SECRET: z.string().min(32).optional(),
    PUSH_PROVIDER: z.enum(['none', 'fcm']).default('none'),
    /** Firebase service-account JSON, base64 encoded (one line, easy to keep in a secret manager). */
    FCM_SERVICE_ACCOUNT_B64: z.string().optional(),
    GEOCODER: z.enum(['none', 'nominatim']).default('none'),
    NOMINATIM_URL: z.string().url().optional(),
    /** Sign-up codes: 'sms' sends a text, 'telegram' sends the code through the Telegram bot. SOS alerts always use SMS_PROVIDER, never the bot. */
    OTP_PROVIDER: z.enum(['sms', 'telegram']).default('sms'),
    TELEGRAM_BOT_TOKEN: z.preprocess(blankIsUnset, z.string().regex(/^\d{5,}:[A-Za-z0-9_-]{20,}$/).optional()),
    TELEGRAM_BOT_USERNAME: z.preprocess(blankIsUnset, z.string().regex(/^[A-Za-z][A-Za-z0-9_]{4,31}$/).optional()),
    TELEGRAM_WEBHOOK_SECRET: z.preprocess(blankIsUnset, z.string().regex(/^[A-Za-z0-9_-]{16,256}$/).optional()),
    SMS_PROVIDER: z.enum(['mock', 'termii']).default('mock'),
    TERMII_API_KEY: z.string().optional(),
    TERMII_SENDER_ID: z.string().optional(),
    TERMII_BASE_URL: z.string().url().default('https://api.ng.termii.com'),
    TERMII_CHANNEL: z.enum(['generic', 'dnd']).default('dnd'),
    SMS_COST_KOBO_ESTIMATE: z.coerce.number().int().min(0).default(500),
    SMS_DAILY_BUDGET_KOBO: z.coerce.number().int().min(0).default(5_000_000),
    SMS_EMERGENCY_RESERVE_PCT: z.coerce.number().min(0).max(90).default(20),
    SMS_PER_USER_DAILY_KOBO: z.coerce.number().int().min(0).default(50_000),

    DISPATCH_MODE: z.enum(['log_only', 'sms']).default('log_only'),
    DISPATCH_INCLUDE_USER_PHONE: z
      .enum(['true', 'false'])
      .default('true')
      .transform((v) => v === 'true'),
    DEV_SEED: bool,

    // Step 1b: persistence, auth, encryption keys
    STORE: z.enum(['memory', 'postgres']).default('memory'),
    DATABASE_URL: z.string().optional(),
    REDIS_URL: z.string().optional(),
    JWT_SECRET: z.string().min(32).optional(),
    /** 64 hex chars each (openssl rand -hex 32). Keep in a secret manager, never in the database. */
    DATA_KEY: z.string().regex(/^[0-9a-fA-F]{64}$/).optional(),
    PHONE_HMAC_KEY: z.string().regex(/^[0-9a-fA-F]{64}$/).optional(),
    DEFAULT_COUNTRY_CODE: z.string().regex(/^\d{1,3}$/).default('234'),
    /**
     * How many reverse proxies sit in front of the server (hosting platforms usually add 1). Rate limits use the
     * caller's IP, so with 0 behind a proxy everyone looks like one visitor, and a wrong high number lets callers fake their IP.
     */
    TRUST_PROXY_HOPS: z.coerce.number().int().min(0).max(5).default(0),
    /** Overall per-IP request cap per minute, applied before any other check. */
    GLOBAL_RATE_PER_MIN: z.coerce.number().int().min(30).default(600),
    OTP_DEV_ECHO: bool,
  })
  .superRefine((v, ctx) => {
    if (v.STORE === 'postgres') {
      for (const k of ['DATABASE_URL', 'REDIS_URL', 'JWT_SECRET', 'DATA_KEY', 'PHONE_HMAC_KEY'] as const) {
        if (!v[k]) ctx.addIssue({ code: z.ZodIssueCode.custom, path: [k], message: `${k} is required when STORE=postgres` });
      }
    }
    if (v.NODE_ENV === 'production') {
      if (v.STORE !== 'postgres') ctx.addIssue({ code: z.ZodIssueCode.custom, path: ['STORE'], message: 'production requires STORE=postgres' });
      if (v.DEV_SEED || v.OTP_DEV_ECHO) ctx.addIssue({ code: z.ZodIssueCode.custom, path: ['DEV_SEED'], message: 'dev switches must be off in production' });
      if (v.SMS_PROVIDER === 'mock') ctx.addIssue({ code: z.ZodIssueCode.custom, path: ['SMS_PROVIDER'], message: 'production cannot use the mock SMS provider' });
    }
    if (v.ADMIN_JWT_SECRET && (v.ADMIN_JWT_SECRET === v.TOKEN_SECRET || v.ADMIN_JWT_SECRET === v.JWT_SECRET)) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ['ADMIN_JWT_SECRET'], message: 'must differ from TOKEN_SECRET and JWT_SECRET' });
    }
    if (v.PUSH_PROVIDER === 'fcm' && !v.FCM_SERVICE_ACCOUNT_B64) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, path: ['FCM_SERVICE_ACCOUNT_B64'], message: 'required when PUSH_PROVIDER=fcm' });
    }
    if (v.OTP_PROVIDER === 'telegram') {
      for (const k of ['TELEGRAM_BOT_TOKEN', 'TELEGRAM_BOT_USERNAME'] as const) {
        if (!v[k]) ctx.addIssue({ code: z.ZodIssueCode.custom, path: [k], message: `${k} is required when OTP_PROVIDER=telegram` });
      }
      if (v.OTP_DEV_ECHO) ctx.addIssue({ code: z.ZodIssueCode.custom, path: ['OTP_DEV_ECHO'], message: 'OTP_DEV_ECHO cannot be used with OTP_PROVIDER=telegram' });
    }
    if (v.SMS_PROVIDER === 'termii' && (!v.TERMII_API_KEY || !v.TERMII_SENDER_ID)) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: 'TERMII_API_KEY and TERMII_SENDER_ID are required when SMS_PROVIDER=termii',
      });
    }
  });

export type Env = z.infer<typeof EnvSchema>;

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Env {
  // On Render the public address is provided as RENDER_EXTERNAL_URL, so PUBLIC_BASE_URL need not be set by hand.
  const publicBase = env.PUBLIC_BASE_URL || env.RENDER_EXTERNAL_URL;
  const parsed = EnvSchema.safeParse(publicBase ? { ...env, PUBLIC_BASE_URL: publicBase } : env);
  if (!parsed.success) {
    // Print which variables are wrong, never their values.
    const problems = parsed.error.issues.map((i) => `${i.path.join('.') || '(root)'}: ${i.message}`);
    throw new Error(`Invalid environment configuration:\n${problems.join('\n')}`);
  }
  return parsed.data;
}
