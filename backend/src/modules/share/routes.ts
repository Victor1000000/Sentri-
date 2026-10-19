import type { FastifyInstance, FastifyRequest } from 'fastify';
import { z } from 'zod';
import type { FixedWindowLimiter } from '../../lib/rate-limit.js';
import type { ShareService } from './service.js';

export interface ShareRouteDeps {
  service: ShareService;
  authenticate: (req: FastifyRequest) => Promise<string | null>;
  limiter: FixedWindowLimiter;
  /** Position updates arrive every few seconds, so they get a separate, larger allowance. */
  updateLimiter: FixedWindowLimiter;
  clock: () => number;
}

const Id = z.string().min(1).max(64);
const Geo = z.object({ lat: z.number().min(-90).max(90), lon: z.number().min(-180).max(180), accuracyM: z.number().min(0).max(100_000).optional() });

export function registerShareRoutes(app: FastifyInstance, d: ShareRouteDeps): void {
  const gate = async (req: FastifyRequest, l = d.limiter): Promise<string | null> => {
    const uid = await d.authenticate(req);
    return uid && l.allow(`share:${uid}`) ? uid : null;
  };

  app.get('/v1/shares', async (req, reply) => {
    const uid = await gate(req);
    if (!uid) return reply.code(401).send({ error: 'unauthorized' });
    return reply.send({ shares: await d.service.active(uid) });
  });

  app.post('/v1/shares', async (req, reply) => {
    const uid = await gate(req);
    if (!uid) return reply.code(401).send({ error: 'unauthorized' });
    const b = z
      .object({ contactIds: z.array(Id).min(1).max(10), geo: Geo.optional(), hours: z.number().min(0.25).max(24).optional() })
      .parse(req.body);
    const r = await d.service.start(uid, b.contactIds, b.geo ? { ...b.geo, at: d.clock() } : undefined, b.hours ? b.hours * 3_600_000 : undefined);
    if (r.ok) return reply.code(201).send(r);
    return reply.code(r.error === 'unknown_contact' ? 404 : 422).send({ error: r.error });
  });

  app.put<{ Params: { id: string } }>('/v1/shares/:id/location', async (req, reply) => {
    const uid = await gate(req, d.updateLimiter);
    if (!uid) return reply.code(401).send({ error: 'unauthorized' });
    const g = Geo.parse(req.body);
    const ok = await d.service.update(uid, Id.parse(req.params.id), { ...g, at: d.clock() });
    return ok ? reply.code(204).send() : reply.code(404).send({ error: 'not_found' });
  });

  app.post<{ Params: { id: string } }>('/v1/shares/:id/extend', async (req, reply) => {
    const uid = await gate(req);
    if (!uid) return reply.code(401).send({ error: 'unauthorized' });
    const { hours } = z.object({ hours: z.number().min(0.25).max(24) }).parse(req.body);
    const exp = await d.service.extend(uid, Id.parse(req.params.id), hours * 3_600_000);
    return exp ? reply.send({ expiresAt: exp }) : reply.code(404).send({ error: 'not_found' });
  });

  app.delete<{ Params: { id: string } }>('/v1/shares/:id', async (req, reply) => {
    const uid = await gate(req);
    if (!uid) return reply.code(401).send({ error: 'unauthorized' });
    const ok = await d.service.stop(uid, Id.parse(req.params.id));
    return ok ? reply.code(204).send() : reply.code(404).send({ error: 'not_found' });
  });
}
