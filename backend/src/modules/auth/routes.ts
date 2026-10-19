import { randomBytes } from 'node:crypto';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { z } from 'zod';
import { PinError, createPinPair } from '../../lib/pin.js';
import type { FixedWindowLimiter } from '../../lib/rate-limit.js';
import { hashToken } from '../../lib/tokens.js';
import { signAccessToken, verifyAccessToken, type AccessClaims } from './jwt.js';
import type { OtpService } from './otp.js';
import { ContactError, LiveSosError, LocaleSchema, normalizePhone, validateContacts } from './phone.js';
import type { SavedContact, UserRepo } from './pg-user-repo.js';

export const ACCESS_TTL_SEC = 15 * 60;

/** Reads `Authorization: Bearer <access token>`. */
export function makeAuthenticator(jwtSecret: string, clock: () => number) {
  const device = (req: FastifyRequest): AccessClaims | null => {
    const h = req.headers.authorization;
    if (!h?.startsWith('Bearer ')) return null;
    return verifyAccessToken(h.slice(7), jwtSecret, clock());
  };
  return { device, userId: async (req: FastifyRequest) => device(req)?.sub ?? null };
}

export interface AuthRouteDeps {
  otp: OtpService;
  /** Dev only (OTP_DEV_ECHO with the mock SMS provider): the code just "sent", so sign-up can be tried with no SMS. */
  devLastCode?: () => string | null;
  users: UserRepo;
  jwtSecret: string;
  pinPepper: Buffer;
  clock: () => number;
  defaultCountryCode: string;
  /** Per-IP limiter for OTP requests and verification attempts. */
  ipLimiter: FixedWindowLimiter;
  authenticate: ReturnType<typeof makeAuthenticator>;
  /** Called after contacts are saved. Must not throw. */
  onContactsSaved?: (userId: string, saved: SavedContact[]) => Promise<void>;
}

const Key32 = z
  .string()
  .refine((s) => Buffer.from(s, 'base64').length === 32, 'must be a base64 32-byte key')
  .transform((s) => Buffer.from(s, 'base64'));

const newRefreshToken = () => randomBytes(32).toString('base64url');

export function registerAuthRoutes(app: FastifyInstance, d: AuthRouteDeps): void {
  const unauthorized = { error: 'unauthorized' };

  // ---- phone verification ----

  app.post('/v1/auth/otp/request', async (req, reply) => {
    if (!d.ipLimiter.allow(`otp-req:${req.ip}`)) return reply.code(429).send({ error: 'rate_limited' });
    const { phone: raw } = z.object({ phone: z.string().min(6).max(24) }).parse(req.body);
    const phone = normalizePhone(raw, d.defaultCountryCode);
    if (!phone) return reply.code(400).send({ error: 'invalid_phone' });
    const result = await d.otp.request(phone);
    // Same answer whether or not the number has an account, so this can't be used to probe who has one.
    if (result === 'rate_limited') return reply.code(429).send({ error: 'rate_limited' });
    if (result === 'budget_exhausted' || result === 'send_failed') return reply.code(503).send({ error: 'try_later' });
    const devCode = d.devLastCode?.();
    return reply.code(202).send(devCode ? { ok: true, devCode } : { ok: true });
  });

  app.post('/v1/auth/otp/verify', async (req, reply) => {
    if (!d.ipLimiter.allow(`otp-verify:${req.ip}`)) return reply.code(429).send({ error: 'rate_limited' });
    const b = z
      .object({
        phone: z.string().min(6).max(24),
        code: z.string().length(6),
        platform: z.enum(['android', 'ios']),
        publicKey: Key32,
        boxPublicKey: Key32,
        locale: LocaleSchema.optional(),
      })
      .parse(req.body);
    const phone = normalizePhone(b.phone, d.defaultCountryCode);
    if (!phone || !(await d.otp.verify(phone, b.code))) return reply.code(401).send({ error: 'invalid_code' });

    const { userId, isNew } = await d.users.findOrCreateUserByPhone(phone, b.locale ?? 'en');
    const refreshToken = newRefreshToken();
    const deviceId = await d.users.registerDevice(
      userId,
      { platform: b.platform, publicKey: b.publicKey, boxPublicKey: b.boxPublicKey },
      hashToken(refreshToken),
    );
    const accessToken = signAccessToken({ sub: userId, did: deviceId }, d.jwtSecret, ACCESS_TTL_SEC, d.clock());
    return reply.send({ userId, deviceId, accessToken, refreshToken, expiresIn: ACCESS_TTL_SEC, isNew });
  });

  app.post('/v1/auth/refresh', async (req, reply) => {
    if (!d.ipLimiter.allow(`refresh:${req.ip}`)) return reply.code(429).send({ error: 'rate_limited' });
    const b = z.object({ deviceId: z.string().uuid(), refreshToken: z.string().min(20).max(100) }).parse(req.body);
    const next = newRefreshToken();
    const userId = await d.users.rotateRefresh(b.deviceId, hashToken(b.refreshToken), hashToken(next));
    if (!userId) return reply.code(401).send(unauthorized);
    const accessToken = signAccessToken({ sub: userId, did: b.deviceId }, d.jwtSecret, ACCESS_TTL_SEC, d.clock());
    return reply.send({ accessToken, refreshToken: next, expiresIn: ACCESS_TTL_SEC });
  });

  // ---- onboarding (authenticated) ----

  // The owner's view of their contact list, with who has accepted or declined.
  app.get('/v1/me/contacts', async (req, reply) => {
    const me = d.authenticate.device(req);
    if (!me) return reply.code(401).send(unauthorized);
    return reply.send({ contacts: await d.users.listContacts(me.sub) });
  });

  app.put('/v1/me/contacts', async (req, reply) => {
    const me = d.authenticate.device(req);
    if (!me) return reply.code(401).send(unauthorized);
    const b = z
      .object({ contacts: z.array(z.object({ phone: z.string().min(6).max(24), locale: LocaleSchema.optional() })).max(10) })
      .parse(req.body);
    const own = await d.users.getPhone(me.sub);
    if (!own) return reply.code(401).send(unauthorized);
    try {
      const clean = validateContacts(b.contacts, own, d.defaultCountryCode);
      const saved = await d.users.replaceContacts(me.sub, clean);
      await d.onContactsSaved?.(me.sub, saved);
      return reply.send({ count: clean.length });
    } catch (err) {
      if (err instanceof ContactError) return reply.code(400).send({ error: 'invalid_contacts', message: err.message });
      if (err instanceof LiveSosError) return reply.code(409).send({ error: 'sos_active', message: err.message });
      throw err;
    }
  });

  app.put('/v1/me/pins', async (req, reply) => {
    const me = d.authenticate.device(req);
    if (!me) return reply.code(401).send(unauthorized);
    const b = z.object({ cancelPin: z.string().max(16), duressPin: z.string().max(16) }).parse(req.body);
    try {
      await d.users.setPins(me.sub, await createPinPair(b.cancelPin, b.duressPin, d.pinPepper));
      return reply.code(204).send();
    } catch (err) {
      if (err instanceof PinError) return reply.code(400).send({ error: 'invalid_pins', message: err.message });
      throw err;
    }
  });

  app.put('/v1/me/profile', async (req, reply) => {
    const me = d.authenticate.device(req);
    if (!me) return reply.code(401).send(unauthorized);
    const b = z
      .object({
        locale: LocaleSchema.optional(),
        dataSaver: z.boolean().optional(),
        // What contacts see on an alert. No control characters or angle brackets.
        name: z.string().trim().min(1).max(40).regex(/^[^\u0000-\u001F\u007F<>]+$/).optional(),
      })
      .parse(req.body);
    await d.users.updateProfile(me.sub, b);
    return reply.code(204).send();
  });

  app.put('/v1/me/push-token', async (req, reply) => {
    const me = d.authenticate.device(req);
    if (!me) return reply.code(401).send(unauthorized);
    const { token } = z.object({ token: z.string().min(10).max(4096) }).parse(req.body);
    await d.users.setPushToken(me.sub, me.did, token);
    return reply.code(204).send();
  });
}
