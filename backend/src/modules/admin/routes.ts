import type { FastifyInstance, FastifyRequest } from 'fastify';
import { z } from 'zod';
import type { FixedWindowLimiter } from '../../lib/rate-limit.js';
import { AdminError, AdminService } from './service.js';
import type { Admin, RequestKind } from './types.js';
import { ADMIN_HTML, ADMIN_CSP } from './admin-ui.js';

const bearer = (req: FastifyRequest) => {
  const h = req.headers.authorization;
  return typeof h === 'string' && h.startsWith('Bearer ') ? h.slice(7) : undefined;
};

/** Payload rules per kind. Unknown fields are rejected so nothing unexpected is stored. */
/** Official lines only: digits, optional leading +, spaces and dashes allowed in input and stripped before saving. */
const phone = z.string().trim().regex(/^\+?[0-9][0-9 \-]{2,17}$/, 'not a phone number').transform((v) => v.replace(/[ \-]/g, ''));

const PAYLOADS: Record<RequestKind, z.ZodTypeAny> = {
  directory_upsert: z.object({
    controlRoomId: z.string().uuid().optional(),
    adminAreaId: z.number().int().positive(),
    name: z.string().trim().min(3).max(120),
    kind: z.enum(['state_command', 'area_command', 'control_room', 'emergency_line']),
    officialPhone: phone.optional(),
    officialSms: phone.optional(),
    source: z.string().trim().min(5).max(300),
  }).strict().refine((v) => v.officialPhone || v.officialSms, { message: 'give a phone or an SMS number' }),
  directory_retire: z.object({ controlRoomId: z.string().uuid() }).strict(),
  directory_verify: z.object({ controlRoomId: z.string().uuid(), source: z.string().min(5).max(300) }).strict(),
  data_access: z.object({ userId: z.string().uuid(), sinceHours: z.number().int().min(1).max(720).default(24) }).strict(),
  admin_add: z.object({ email: z.string().email().max(200) }).strict(),
  admin_remove: z.object({ adminId: z.string().uuid() }).strict(),
};

const STATUS: Record<AdminError['code'], number> = {
  invalid_credentials: 401, locked: 429, not_found: 404, forbidden: 403, conflict: 409, expired: 410, bad_request: 400,
};

export function registerAdminRoutes(app: FastifyInstance, d: { admin: AdminService; loginLimiter: FixedWindowLimiter }) {
  app.addHook('onRequest', async (req, reply) => {
    // The admin API is never cached or framed.
    if (req.url.startsWith('/admin')) reply.header('x-frame-options', 'DENY').header('cache-control', 'no-store');
  });

  const guarded = (fn: (req: FastifyRequest<any>, admin: Admin) => Promise<unknown>) =>
    async (req: FastifyRequest<any>, reply: any) => {
      try {
        const admin = await d.admin.authenticate(bearer(req));
        if (!admin) return reply.code(401).send({ error: 'unauthorized' });
        return reply.send(await fn(req, admin));
      } catch (e) {
        if (e instanceof AdminError) return reply.code(STATUS[e.code]).send({ error: e.code, message: e.message });
        // Bad input is the caller's fault: answer 400 here so it never depends on a global error handler.
        if (e instanceof z.ZodError) return reply.code(400).send({ error: 'bad_request' });
        throw e;
      }
    };

  app.post('/admin/v1/login', async (req, reply) => {
    const parsed = z.object({ email: z.string().max(200), password: z.string().max(200), code: z.string().max(10) }).safeParse(req.body);
    if (!parsed.success) return reply.code(400).send({ error: 'bad_request' });
    const b = parsed.data;
    if (!d.loginLimiter.allow(`ip:${req.ip}`) || !d.loginLimiter.allow(`em:${b.email.toLowerCase()}`)) {
      return reply.code(429).send({ error: 'rate_limited' });
    }
    try {
      return reply.send(await d.admin.login(b.email, b.password, b.code));
    } catch (e) {
      if (e instanceof AdminError) return reply.code(STATUS[e.code]).send({ error: e.code });
      throw e;
    }
  });

  // The console itself. Static page, no data in it; every API call still needs a session.
  app.get('/admin', async (_req, reply) =>
    reply
      .header('content-type', 'text/html; charset=utf-8')
      .header('content-security-policy', ADMIN_CSP)
      .header('cache-control', 'no-store')
      .header('x-content-type-options', 'nosniff')
      .header('referrer-policy', 'no-referrer')
      .send(ADMIN_HTML));

  app.get('/admin/v1/directory', guarded(async () => ({ rooms: await d.admin.directory() })));
  app.get('/admin/v1/areas', guarded(async () => ({ areas: await d.admin.areas() })));
  app.get('/admin/v1/admins', guarded(async () => ({ admins: await d.admin.admins() })));

  app.get('/admin/v1/me', guarded(async (_req, a) => ({ id: a.id, email: a.email })));

  app.get('/admin/v1/requests', guarded(async (req) => {
    const q = z.object({ state: z.enum(['pending', 'approved', 'rejected', 'executed', 'expired']).optional() }).parse(req.query);
    return { requests: await d.admin.list(q.state ? [q.state] : undefined) };
  }));

  app.post('/admin/v1/requests', guarded(async (req, a) => {
    const b = z.object({ kind: z.enum(['directory_verify', 'directory_upsert', 'directory_retire', 'data_access', 'admin_add', 'admin_remove']), payload: z.unknown(), reason: z.string().max(1000) }).parse(req.body);
    const payload = PAYLOADS[b.kind].parse(b.payload) as Record<string, unknown>;
    return { request: await d.admin.createRequest(a, b.kind, payload, b.reason) };
  }));

  app.get('/admin/v1/requests/:id', guarded(async (req) => d.admin.view(z.object({ id: z.string().uuid() }).parse(req.params).id)));
  app.post('/admin/v1/requests/:id/approve', guarded(async (req, a) => ({ request: await d.admin.decide(a, z.object({ id: z.string().uuid() }).parse(req.params).id, 'approve') })));
  app.post('/admin/v1/requests/:id/reject', guarded(async (req, a) => ({ request: await d.admin.decide(a, z.object({ id: z.string().uuid() }).parse(req.params).id, 'reject') })));
  app.post('/admin/v1/requests/:id/execute', guarded(async (req, a) => d.admin.execute(a, z.object({ id: z.string().uuid() }).parse(req.params).id)));
  app.get('/admin/v1/requests/:id/events', guarded(async (req, a) => ({ events: await d.admin.readEvents(a, z.object({ id: z.string().uuid() }).parse(req.params).id) })));
}
