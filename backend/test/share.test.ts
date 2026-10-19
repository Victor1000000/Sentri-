import { describe, expect, it } from 'vitest';
import Fastify from 'fastify';
import { FixedWindowLimiter } from '../src/lib/rate-limit.js';
import { createPinPair } from '../src/lib/pin.js';
import { MemoryInbox } from '../src/modules/inbox/memory-inbox.js';
import { InboxService } from '../src/modules/inbox/service.js';
import { alertText } from '../src/modules/inbox/texts.js';
import type { PushPayload, PushSender } from '../src/modules/notify/contact-notifier.js';
import { MemoryShares } from '../src/modules/share/memory-share.js';
import { registerShareRoutes } from '../src/modules/share/routes.js';
import { ShareService } from '../src/modules/share/service.js';
import { MemorySosStore } from '../src/modules/sos/memory-store.js';
import { FakeClock, PEPPER } from './helpers.js';

class RecordingPush implements PushSender {
  sent: { userId: string; p: PushPayload }[] = [];
  async sendToContact() { return false; }
  async sendToUser(userId: string, p: PushPayload) { this.sent.push({ userId, p }); return true; }
}

async function rig() {
  const clock = new FakeClock();
  const store = new MemorySosStore();
  const pins = await createPinPair('1234', '4321', PEPPER);
  store.addUser({ id: 'u1', phone: '+2348000000000', locale: 'en', name: 'Ada' }, pins, [
    { id: 'c1', userId: 'u1', phone: '+2348000000001', locale: 'en', hasApp: false, priority: 0 },
    { id: 'c2', userId: 'u1', phone: '+2348000000002', locale: 'pcm', hasApp: false, priority: 1 },
    { id: 'c3', userId: 'u1', phone: '+2348000000003', locale: 'ha', hasApp: false, priority: 2 },
  ]);
  store.putUser({ id: 'uc1', phone: '+2348000000001', locale: 'en' });
  store.putUser({ id: 'uc2', phone: '+2348000000002', locale: 'pcm' });
  const inbox = new MemoryInbox(store);
  const shares = new MemoryShares();
  const push = new RecordingPush();
  let n = 0;
  const newId = () => `id-${++n}`;
  const o = { clock: clock.fn, newId, retentionMs: 72 * 3_600_000 };
  const svc = new ShareService(store, inbox, shares, push, o);
  const inboxSvc = new InboxService(store, inbox, push, { alertView: async () => 'invalid' } as never, { ...o, shares });
  return { clock, store, inbox, shares, push, svc, inboxSvc };
}

describe('live location sharing', () => {
  it('tells only the chosen contacts, and only those with the app', async () => {
    const r = await rig();
    const out = await r.svc.start('u1', ['c1', 'c3'], { lat: 6.5, lon: 3.3, at: 1 });
    expect(out).toMatchObject({ ok: true, reached: 1, unreachable: ['c3'] });
    expect(r.push.sent.map((s) => s.userId)).toEqual(['uc1']);
    expect(r.push.sent[0]!.p.kind).toBe('share_start');
    expect(r.push.sent[0]!.p.text).toContain('Ada');
    expect(JSON.stringify(r.push.sent[0]!.p)).not.toMatch(/https?:/);
    expect((await r.inboxSvc.list('uc2')).items).toHaveLength(0);
  });

  it('refuses contacts that are not yours, empty choices and nobody reachable', async () => {
    const r = await rig();
    expect(await r.svc.start('u1', [])).toEqual({ ok: false, error: 'no_contacts' });
    expect(await r.svc.start('u1', ['nope'])).toEqual({ ok: false, error: 'unknown_contact' });
    expect(await r.svc.start('u1', ['c3'])).toEqual({ ok: false, error: 'none_reachable' });
    expect(await r.svc.start('uc1', ['c1'])).toEqual({ ok: false, error: 'unknown_contact' });
  });

  it('the contact follows the latest position while sharing, and nobody else can update it', async () => {
    const r = await rig();
    const s = (await r.svc.start('u1', ['c1'], { lat: 1, lon: 1, at: 1 })) as { id: string };
    expect(await r.svc.update('u1', s.id, { lat: 6.6, lon: 3.4, at: 2 })).toBe(true);
    expect(await r.svc.update('uc1', s.id, { lat: 0, lon: 0, at: 3 })).toBe(false);
    const item = (await r.inboxSvc.list('uc1')).items[0]!;
    expect(item.live).toBe(true);
    const d = (await r.inboxSvc.open('uc1', item.id))!;
    expect(d.state).toBe('active');
    expect(d.geo).toMatchObject({ lat: 6.6, lon: 3.4 });
    expect(d.canRespond).toBe(false);
    expect(await r.inboxSvc.respond('uc1', item.id)).toBe('not_allowed');
  });

  it('stopping alerts the contact once, ends the live view and refuses later updates', async () => {
    const r = await rig();
    const s = (await r.svc.start('u1', ['c1', 'c2'])) as { id: string };
    r.push.sent.length = 0;
    expect(await r.svc.stop('u1', s.id)).toBe(true);
    expect(await r.svc.stop('u1', s.id)).toBe(false);
    expect(r.push.sent.filter((x) => x.p.kind === 'share_stop').map((x) => x.userId).sort()).toEqual(['uc1', 'uc2']);
    const items = (await r.inboxSvc.list('uc1')).items;
    expect(items.find((i) => i.kind === 'share_start')!.live).toBe(false);
    expect(items.find((i) => i.kind === 'share_stop')!.text).toContain('stopped');
    expect(await r.svc.update('u1', s.id, { lat: 1, lon: 1, at: 9 })).toBe(false);
    expect(await r.svc.active('u1')).toEqual([]);
  });

  it('only the owner can stop it', async () => {
    const r = await rig();
    const s = (await r.svc.start('u1', ['c1'])) as { id: string };
    expect(await r.svc.stop('uc1', s.id)).toBe(false);
    expect(await r.svc.active('u1')).toHaveLength(1);
  });

  it('a forgotten share ends by itself after the safety limit, and the contact is told', async () => {
    const r = await rig();
    await r.svc.start('u1', ['c1']);
    r.clock.now += 7 * 3_600_000;
    expect(await r.svc.expireDue()).toBe(0);
    r.clock.now += 2 * 3_600_000;
    r.push.sent.length = 0;
    expect(await r.svc.expireDue()).toBe(1);
    expect(r.push.sent.map((x) => x.p.kind)).toEqual(['share_stop']);
    expect(await r.svc.expireDue()).toBe(0);
  });

  it('extending keeps it going but never beyond the maximum', async () => {
    const r = await rig();
    const s = (await r.svc.start('u1', ['c1'])) as { id: string; expiresAt: number };
    expect(await r.svc.extend('u1', s.id, 2 * 3_600_000)).toBe(s.expiresAt + 2 * 3_600_000);
    expect(await r.svc.extend('u1', s.id, 100 * 3_600_000)).toBe(r.clock.now + 24 * 3_600_000);
    expect(await r.svc.extend('uc1', s.id, 1000)).toBeNull();
  });

  it('start duration is clamped', async () => {
    const r = await rig();
    const a = (await r.svc.start('u1', ['c1'], undefined, 1)) as { expiresAt: number };
    expect(a.expiresAt - r.clock.now).toBe(15 * 60_000);
  });

  it('purges old shares', async () => {
    const r = await rig();
    await r.svc.start('u1', ['c1']);
    r.clock.now += 200 * 3_600_000;
    expect(await r.shares.purge(r.clock.now)).toBe(1);
  });

  it('texts exist in every language without links', () => {
    for (const l of ['en', 'pcm', 'ha', 'yo', 'ig'] as const) for (const k of ['share_start', 'share_stop'] as const) {
      const t = alertText(k, l, 'Ada');
      expect(t).toContain('Ada');
      expect(t).not.toMatch(/https?:|www\./);
    }
  });
});

describe('share routes', () => {
  async function app() {
    const r = await rig();
    const a = Fastify();
    registerShareRoutes(a, {
      service: r.svc,
      authenticate: async (req) => (req.headers['x-user'] as string | undefined) ?? null,
      limiter: new FixedWindowLimiter(100, 60_000),
      updateLimiter: new FixedWindowLimiter(100, 60_000),
      clock: r.clock.fn,
    });
    return { a, r };
  }
  const h = { 'x-user': 'u1' };

  it('requires sign-in', async () => {
    const { a } = await app();
    expect((await a.inject({ method: 'GET', url: '/v1/shares' })).statusCode).toBe(401);
  });

  it('start, update, list, stop', async () => {
    const { a } = await app();
    const st = await a.inject({ method: 'POST', url: '/v1/shares', headers: h, payload: { contactIds: ['c1'], geo: { lat: 6.5, lon: 3.3 } } });
    expect(st.statusCode).toBe(201);
    const { id } = st.json();
    expect((await a.inject({ method: 'PUT', url: `/v1/shares/${id}/location`, headers: h, payload: { lat: 6.6, lon: 3.4 } })).statusCode).toBe(204);
    expect((await a.inject({ method: 'GET', url: '/v1/shares', headers: h })).json().shares).toHaveLength(1);
    expect((await a.inject({ method: 'DELETE', url: `/v1/shares/${id}`, headers: h })).statusCode).toBe(204);
    expect((await a.inject({ method: 'DELETE', url: `/v1/shares/${id}`, headers: h })).statusCode).toBe(404);
    expect((await a.inject({ method: 'PUT', url: `/v1/shares/${id}/location`, headers: h, payload: { lat: 6.6, lon: 3.4 } })).statusCode).toBe(404);
  });

  it('maps errors', async () => {
    const { a } = await app();
    expect((await a.inject({ method: 'POST', url: '/v1/shares', headers: h, payload: { contactIds: ['zzz'] } })).statusCode).toBe(404);
    expect((await a.inject({ method: 'POST', url: '/v1/shares', headers: h, payload: { contactIds: ['c3'] } })).statusCode).toBe(422);
  });
});
