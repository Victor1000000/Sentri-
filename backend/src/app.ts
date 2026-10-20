import Fastify, { type FastifyInstance, type FastifyRequest } from 'fastify';
import { z } from 'zod';
import type { FixedWindowLimiter } from './lib/rate-limit.js';
import type { ReverseGeocoder } from './modules/geo/geocoder.js';
import type { SosEngine } from './modules/sos/engine.js';

export interface AppDeps {
  engine: SosEngine;
  /** Returns the authenticated user id, or null. Real device-bound auth lands in step 1b. */
  authenticate: (req: FastifyRequest) => Promise<string | null>;
  startLimiter: FixedWindowLimiter;
  /** Not used any more: contacts no longer answer through public links. Kept optional so callers need no change. */
  ackLimiter?: FixedWindowLimiter;
  /** Optional. Without it the lookup route answers 404 and apps show coordinates only. */
  geocoder?: ReverseGeocoder;
  geoLimiter?: FixedWindowLimiter;
  logger?: boolean;
  /** Reverse proxies in front of the server. Sets which part of X-Forwarded-For is believed. Default 0: ignore the header. */
  trustProxyHops?: number;
  /** Per-IP cap on all requests, checked first. Without it, anyone can hammer the open routes. */
  globalLimiter?: FixedWindowLimiter;
  /** Tell browsers to use HTTPS only. Turn on in production, where TLS is terminated in front of the server. */
  hsts?: boolean;
}

const Geo = z.object({
  lat: z.number().min(-90).max(90),
  lon: z.number().min(-180).max(180),
  accuracyM: z.number().positive().max(100000).optional(),
});

const StartBody = Geo.partial().extend({
  trigger: z.enum(['floating', 'volume', 'shake', 'power', 'widget']),
});

export function buildApp(d: AppDeps): FastifyInstance {
  const hops = d.trustProxyHops && d.trustProxyHops > 0 ? d.trustProxyHops : 0;
  // Request logging is off: URLs can carry ids that should not reach logs.
  const app = Fastify({
    logger: d.logger ?? false,
    disableRequestLogging: true,
    bodyLimit: 4096,
    // Trust exactly that many proxies, so a caller cannot invent an IP by sending their own X-Forwarded-For.
    // (A function, because the plain-number form is no longer accepted by Fastify's types.)
    trustProxy: hops > 0 ? (_addr: string, hop: number) => hop < hops : false,
    // Slow-loris and oversized-header guards.
    connectionTimeout: 30_000,
    requestTimeout: 30_000,
    maxParamLength: 128,
  });

  app.addHook('onRequest', async (req, reply) => {
    if (d.globalLimiter && !d.globalLimiter.allow(`ip:${req.ip}`)) return reply.code(429).send({ error: 'rate_limited' });
  });

  app.addHook('onSend', async (_req, reply) => {
    if (d.hsts) reply.header('strict-transport-security', 'max-age=31536000; includeSubDomains');
    reply.header('permissions-policy', 'geolocation=(), camera=(), microphone=()');
    reply.header('cache-control', 'no-store');
    reply.header('referrer-policy', 'no-referrer');
    reply.header('x-content-type-options', 'nosniff');
    // Pages that set their own policy (the admin console) keep it. Everyone else is JSON and gets the strictest one.
    if (!reply.getHeader('content-security-policy')) {
      reply.header('content-security-policy', "default-src 'none'; frame-ancestors 'none'");
    }
  });

  app.setErrorHandler((err, _req, reply) => {
    if (err instanceof z.ZodError) return reply.code(400).send({ error: 'bad_request' });
    const code = (err as { statusCode?: number }).statusCode;
    if (code && code < 500) return reply.code(code).send({ error: 'bad_request' });
    return reply.code(500).send({ error: 'internal' });
  });

  const user = async (req: FastifyRequest) => d.authenticate(req);

  // ---- user-facing, authenticated ----

  app.post('/v1/sos', async (req, reply) => {
    const uid = await user(req);
    if (!uid) return reply.code(401).send({ error: 'unauthorized' });
    if (!d.startLimiter.allow(`start:${uid}`)) return reply.code(429).send({ error: 'rate_limited' });
    const b = StartBody.parse(req.body);
    const geo = b.lat !== undefined && b.lon !== undefined
      ? { lat: b.lat, lon: b.lon, accuracyM: b.accuracyM, at: Date.now() }
      : undefined;
    const v = await d.engine.start(uid, b.trigger, geo);
    return reply.code(201).send(v);
  });

  app.post<{ Params: { id: string } }>('/v1/sos/:id/location', async (req, reply) => {
    const uid = await user(req);
    if (!uid) return reply.code(401).send({ error: 'unauthorized' });
    const g = Geo.parse(req.body);
    const ok = await d.engine.updateLocation(uid, req.params.id, { ...g, at: Date.now() });
    return ok ? reply.send(ok) : reply.code(404).send({ error: 'not_found' });
  });

  // Place names for a position. Never part of the SOS path itself.
  app.get('/v1/geo/reverse', async (req, reply) => {
    const uid = await user(req);
    if (!uid) return reply.code(401).send({ error: 'unauthorized' });
    if (!d.geocoder) return reply.code(404).send({ error: 'not_available' });
    if (d.geoLimiter && !d.geoLimiter.allow(`geo:${uid}`)) return reply.code(429).send({ error: 'rate_limited' });
    const q = z.object({ lat: z.coerce.number().min(-90).max(90), lon: z.coerce.number().min(-180).max(180) }).parse(req.query);
    const place = await d.geocoder.reverse(q.lat, q.lon);
    return reply.send({ place });
  });

  app.post('/v1/sos/current/pin', async (req, reply) => {
    const uid = await user(req);
    if (!uid) return reply.code(401).send({ error: 'unauthorized' });
    const { pin } = z.object({ pin: z.string().min(1).max(16) }).parse(req.body);
    const out = await d.engine.submitPinForCurrent(uid, pin);
    if (out.result === 'not_found') return reply.code(404).send({ error: 'not_found' });
    return reply.send(out);
  });

  app.post<{ Params: { id: string } }>('/v1/sos/:id/pin', async (req, reply) => {
    const uid = await user(req);
    if (!uid) return reply.code(401).send({ error: 'unauthorized' });
    const { pin } = z.object({ pin: z.string().min(1).max(16) }).parse(req.body);
    const out = await d.engine.submitPin(uid, req.params.id, pin);
    if (out.result === 'not_found') return reply.code(404).send({ error: 'not_found' });
    return reply.send(out);
  });

  app.post('/v1/alerts/low-battery', async (req, reply) => {
    const uid = await user(req);
    if (!uid) return reply.code(401).send({ error: 'unauthorized' });
    const g = Geo.partial().parse(req.body ?? {});
    const geo = g.lat !== undefined && g.lon !== undefined ? { lat: g.lat, lon: g.lon, accuracyM: g.accuracyM, at: Date.now() } : undefined;
    return reply.send(await d.engine.lowBattery(uid, geo));
  });

  app.get('/healthz', async () => ({ ok: true }));

  return app;
}
