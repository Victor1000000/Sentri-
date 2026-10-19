import type { FastifyInstance, FastifyRequest } from 'fastify';
import { z } from 'zod';
import type { FixedWindowLimiter } from '../../lib/rate-limit.js';
import type { InboxService } from './service.js';

export interface InboxRouteDeps {
  service: InboxService;
  authenticate: (req: FastifyRequest) => Promise<string | null>;
  limiter: FixedWindowLimiter;
}

const Id = z.string().uuid().or(z.string().min(1).max(64));

/** Everything a contact sees: their inbox, one alert with its map position, "I'm responding", and invitations. */
export function registerInboxRoutes(app: FastifyInstance, d: InboxRouteDeps): void {
  const gate = async (req: FastifyRequest): Promise<string | null> => {
    const uid = await d.authenticate(req);
    if (!uid || !d.limiter.allow(`inbox:${uid}`)) return null;
    return uid;
  };

  app.get('/v1/inbox', async (req, reply) => {
    const uid = await gate(req);
    if (!uid) return reply.code(401).send({ error: 'unauthorized' });
    return reply.send(await d.service.list(uid));
  });

  app.get<{ Params: { id: string } }>('/v1/inbox/:id', async (req, reply) => {
    const uid = await gate(req);
    if (!uid) return reply.code(401).send({ error: 'unauthorized' });
    const out = await d.service.open(uid, Id.parse(req.params.id));
    return out ? reply.send(out) : reply.code(404).send({ error: 'not_found' });
  });

  app.post<{ Params: { id: string } }>('/v1/inbox/:id/respond', async (req, reply) => {
    const uid = await gate(req);
    if (!uid) return reply.code(401).send({ error: 'unauthorized' });
    const r = await d.service.respond(uid, Id.parse(req.params.id));
    if (r === 'not_found') return reply.code(404).send({ error: 'not_found' });
    if (r === 'not_allowed') return reply.code(403).send({ error: 'not_allowed' });
    return reply.send({ result: r });
  });

  app.post('/v1/invites/:contactId', async (req, reply) => {
    const uid = await gate(req);
    if (!uid) return reply.code(401).send({ error: 'unauthorized' });
    const { contactId } = z.object({ contactId: Id }).parse(req.params);
    const { decision } = z.object({ decision: z.enum(['accept', 'decline']) }).parse(req.body);
    const ok = await d.service.decideInvite(uid, contactId, decision);
    return ok ? reply.code(204).send() : reply.code(404).send({ error: 'not_found' });
  });

  app.post('/v1/test-alert', async (req, reply) => {
    const uid = await gate(req);
    if (!uid) return reply.code(401).send({ error: 'unauthorized' });
    const r = await d.service.sendTest(uid);
    return r === 'rate_limited' ? reply.code(429).send({ error: 'rate_limited' }) : reply.send(r);
  });
}
