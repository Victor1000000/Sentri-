import { describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';
import { FixedWindowLimiter } from '../src/lib/rate-limit.js';
import { GEO, harness } from './helpers.js';

async function appFor(over = {}) {
  const h = await harness(over);
  const app = buildApp({
    engine: h.engine,
    authenticate: async (req) => (req.headers['x-user'] as string | undefined) ?? null,
    startLimiter: new FixedWindowLimiter(2, 60_000),
    ackLimiter: new FixedWindowLimiter(100, 60_000),
  });
  return { h, app };
}

const hdr = { 'x-user': 'u1' };

describe('HTTP API', () => {
  it('rejects unauthenticated calls', async () => {
    const { app } = await appFor();
    expect((await app.inject({ method: 'POST', url: '/v1/sos', payload: { trigger: 'shake' } })).statusCode).toBe(401);
  });

  it('validates input', async () => {
    const { app } = await appFor();
    const r = await app.inject({ method: 'POST', url: '/v1/sos', headers: hdr, payload: { trigger: 'nope' } });
    expect(r.statusCode).toBe(400);
    const r2 = await app.inject({ method: 'POST', url: '/v1/sos', headers: hdr, payload: { trigger: 'shake', lat: 999, lon: 0 } });
    expect(r2.statusCode).toBe(400);
  });

  it('starts an SOS, and rate limits repeated starts per user', async () => {
    const { app } = await appFor();
    const post = () => app.inject({ method: 'POST', url: '/v1/sos', headers: hdr, payload: { trigger: 'shake', ...GEO } });
    const first = await post();
    expect(first.statusCode).toBe(201);
    expect(first.json()).toMatchObject({ state: 'countdown' });
    expect((await post()).statusCode).toBe(201);
    expect((await post()).statusCode).toBe(429);
  });

  it('PIN endpoint returns the same shape for cancel and duress', async () => {
    const { app } = await appFor();
    const { sosId } = (await app.inject({ method: 'POST', url: '/v1/sos', headers: hdr, payload: { trigger: 'shake' } })).json();
    const r = await app.inject({ method: 'POST', url: `/v1/sos/${sosId}/pin`, headers: hdr, payload: { pin: '4321' } });
    expect(r.json()).toEqual({ result: 'cancelled', keepTracking: true });
  });

  it('"current" PIN endpoint cancels the live alert without knowing its id, and 404s when none', async () => {
    const { h, app } = await appFor();
    const none = await app.inject({ method: 'POST', url: '/v1/sos/current/pin', headers: hdr, payload: { pin: '1234' } });
    expect(none.statusCode).toBe(404);

    const { sosId } = (await app.inject({ method: 'POST', url: '/v1/sos', headers: hdr, payload: { trigger: 'shake' } })).json();
    const r = await app.inject({ method: 'POST', url: '/v1/sos/current/pin', headers: hdr, payload: { pin: '1234' } });
    expect(r.json()).toEqual({ result: 'cancelled', keepTracking: false });
    expect((await h.store.getEvent(sosId))!.state).toBe('cancelled');
    await h.sched.advance(60_000);
    expect(h.notifier.messages).toHaveLength(0);
  });

  it('the old public link pages are gone, and every response is uncached and unframeable', async () => {
    const { app } = await appFor();
    for (const url of ['/r/AAAAAAAAAAAAAAAA', '/l/AAAAAAAAAAAAAAAA', '/c/AAAAAAAAAAAAAAAA']) {
      const r = await app.inject({ method: 'GET', url });
      expect(r.statusCode, url).toBe(404);
      expect(r.headers['cache-control']).toBe('no-store');
      expect(r.headers['referrer-policy']).toBe('no-referrer');
      expect(r.headers['content-security-policy']).toContain("frame-ancestors 'none'");
    }
  });

  it('keeps a page\'s own security policy instead of overwriting it (the admin console relies on this)', async () => {
    const { app } = await appFor();
    app.get('/own-policy', async (_req, reply) => reply.header('content-security-policy', "default-src 'none'; script-src 'sha256-abc'").send('x'));
    expect((await app.inject({ url: '/own-policy' })).headers['content-security-policy']).toContain("script-src 'sha256-abc'");
    expect((await app.inject({ url: '/healthz' })).headers['content-security-policy']).toContain("default-src 'none'");
  });
});
