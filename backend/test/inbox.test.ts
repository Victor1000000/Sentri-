import { describe, expect, it } from 'vitest';
import { buildApp } from '../src/app.js';
import { FixedWindowLimiter } from '../src/lib/rate-limit.js';
import { createPinPair } from '../src/lib/pin.js';
import { HashChainAudit } from '../src/modules/audit/audit.js';
import { MemoryInbox } from '../src/modules/inbox/memory-inbox.js';
import { registerInboxRoutes } from '../src/modules/inbox/routes.js';
import { InboxService } from '../src/modules/inbox/service.js';
import { ALL_ALERT_TEXTS, alertText } from '../src/modules/inbox/texts.js';
import { ContactNotifier, type PushPayload, type PushSender } from '../src/modules/notify/contact-notifier.js';
import { SosEngine } from '../src/modules/sos/engine.js';
import { MemorySosStore } from '../src/modules/sos/memory-store.js';
import type { Locale } from '../src/domain/types.js';
import { FakeClock, FakeScheduler, GEO, PEPPER, RecordingDispatcher } from './helpers.js';

class RecordingPush implements PushSender {
  sent: { userId: string; p: PushPayload }[] = [];
  ok = true;
  async sendToContact() {
    return false;
  }
  async sendToUser(userId: string, p: PushPayload) {
    this.sent.push({ userId, p });
    return this.ok;
  }
}

/** Owner u1 ("Ada") has three contacts. Only c1 (uc1) and c2 (uc2) have the app. c3 has not installed it. */
async function rig() {
  const clock = new FakeClock();
  const sched = new FakeScheduler(clock);
  const store = new MemorySosStore();
  const push = new RecordingPush();
  const pins = await createPinPair('1234', '4321', PEPPER);
  store.addUser({ id: 'u1', phone: '+2348000000000', locale: 'en', name: 'Ada' }, pins, [
    { id: 'c1', userId: 'u1', phone: '+2348000000001', locale: 'en', hasApp: false, priority: 0 },
    { id: 'c2', userId: 'u1', phone: '+2348000000002', locale: 'pcm', hasApp: false, priority: 1 },
    { id: 'c3', userId: 'u1', phone: '+2348000000003', locale: 'ha', hasApp: false, priority: 2 },
  ]);
  store.putUser({ id: 'uc1', phone: '+2348000000001', locale: 'en' });
  store.putUser({ id: 'uc2', phone: '+2348000000002', locale: 'pcm' });
  store.putUser({ id: 'stranger', phone: '+2348999999999', locale: 'en' });
  const inbox = new MemoryInbox(store);
  let svc!: InboxService;
  const notifier = new ContactNotifier({ deliver: (m) => svc.deliver(m), over: (s, r) => svc.alertOver(s, r) }, push);
  let n = 0;
  const engine = new SosEngine({
    store,
    scheduler: sched,
    notifier,
    dispatcher: new RecordingDispatcher(),
    audit: new HashChainAudit(clock.fn),
    lowBatteryLimiter: new FixedWindowLimiter(1, 30 * 60_000, clock.fn),
    clock: clock.fn,
    newId: () => `sos-${++n}`,
    cfg: {
      cancelWindowMs: 5000, repeatMs: 25000, maxRepeats: 240, offlineAfterMs: 90000, pinMaxAttempts: 5,
      pinLockoutMs: 300000, retentionMs: 72 * 3_600_000, baseUrl: 'https://sentri.example', tokenSecret: 't'.repeat(32), pinPepper: PEPPER,
    },
  });
  let ids = 0;
  svc = new InboxService(store, inbox, push, engine, {
    retentionMs: 72 * 3_600_000,
    clock: clock.fn,
    newId: () => `item-${++ids}`,
    testLimiter: new FixedWindowLimiter(1, 10 * 60_000, clock.fn),
  });
  return { clock, sched, store, push, inbox, engine, svc };
}

describe('alert texts', () => {
  const locales = Object.keys(ALL_ALERT_TEXTS) as Locale[];
  const kinds = ['sos', 'duress', 'offline', 'low_battery', 'test'] as const;

  it('every language has every kind, uses the name, and never contains a link or a phone number', () => {
    for (const l of locales) for (const k of kinds) {
      const t = alertText(k, l, 'Ada');
      expect(t, `${l}/${k}`).toContain('Ada');
      expect(t, `${l}/${k}`).not.toMatch(/https?:|www\.|\d{6}/i);
    }
  });

  it('falls back to a neutral word when the sender gave no name', () => {
    expect(alertText('sos', 'en')).toMatch(/^Someone needs/);
    expect(alertText('sos', 'en', '   ')).toMatch(/^Someone needs/);
  });

  it('the duress text tells contacts not to call', () => {
    for (const l of locales) expect(alertText('duress', l, 'Ada').length).toBeGreaterThan(20);
    expect(alertText('duress', 'en', 'Ada')).toContain('Do NOT call');
  });
});

describe('alerts reach contacts only inside the app', () => {
  it('stores an inbox item and pushes to contacts who have the app; contacts without it get nothing', async () => {
    const r = await rig();
    await r.engine.start('u1', 'shake', GEO);
    await r.sched.advance(5000);
    expect(r.push.sent.map((s) => s.userId).sort()).toEqual(['uc1', 'uc2']);
    const first = r.push.sent.find((s) => s.userId === 'uc1')!;
    expect(first.p.kind).toBe('sos');
    expect(first.p.text).toContain('Ada');
    expect(first.p.inboxId).toBeTruthy();
    expect(JSON.stringify(first.p)).not.toMatch(/https?:/); // no link, ever
    expect((await r.svc.list('uc1')).items).toHaveLength(1);
    expect((await r.svc.list('uc2')).items[0]!.text).toContain('Ada'); // rendered per the contact's own language
  });

  it('repeats re-ring the phone but keep one inbox entry', async () => {
    const r = await rig();
    await r.engine.start('u1', 'shake', GEO);
    await r.sched.advance(5000 + 25_000 * 3);
    expect(r.push.sent.filter((s) => s.userId === 'uc1').length).toBeGreaterThanOrEqual(4);
    expect((await r.svc.list('uc1')).items).toHaveLength(1);
  });

  it('an undelivered push still leaves the alert in the inbox', async () => {
    const r = await rig();
    r.push.ok = false;
    await r.engine.start('u1', 'shake', GEO);
    await r.sched.advance(5000);
    expect((await r.svc.list('uc1')).items).toHaveLength(1);
  });

  it('a contact who installs the app later is reached without re-saving the list', async () => {
    const r = await rig();
    r.store.putUser({ id: 'uc3', phone: '+2348000000003', locale: 'ha' });
    await r.engine.start('u1', 'shake', GEO);
    await r.sched.advance(5000);
    expect(r.push.sent.some((s) => s.userId === 'uc3')).toBe(true);
  });

  it('a declined contact gets nothing', async () => {
    const r = await rig();
    expect(await r.svc.decideInvite('uc1', 'c1', 'decline')).toBe(true);
    await r.engine.start('u1', 'shake', GEO);
    await r.sched.advance(5000);
    expect(r.push.sent.some((s) => s.userId === 'uc1')).toBe(false);
    expect(r.push.sent.some((s) => s.userId === 'uc2')).toBe(true);
  });
});

describe('reading and answering an alert', () => {
  async function live() {
    const r = await rig();
    await r.engine.start('u1', 'shake', GEO);
    await r.sched.advance(5000);
    const id = (await r.svc.list('uc1')).items[0]!.id;
    return { r, id };
  }

  it('shows the position, a call button and the respond option, and marks it read', async () => {
    const { r, id } = await live();
    expect((await r.svc.list('uc1')).unread).toBe(1);
    const d = (await r.svc.open('uc1', id))!;
    expect(d.state).toBe('active');
    expect(d.geo).toMatchObject({ lat: GEO.lat, lon: GEO.lon });
    expect(d.callPhone).toBe('+2348000000000');
    expect(d.canRespond).toBe(true);
    expect((await r.svc.list('uc1')).unread).toBe(0);
  });

  it('"I\'m responding" stops the repeats, tells the sender, and a second contact sees it taken', async () => {
    const { r, id } = await live();
    expect(await r.svc.respond('uc1', id)).toBe('ok');
    expect(r.push.sent.some((s) => s.userId === 'u1' && s.p.kind === 'acknowledged')).toBe(true);
    const before = r.push.sent.length;
    await r.sched.advance(60_000);
    expect(r.push.sent.length).toBe(before); // nothing further rings
    const id2 = (await r.svc.list('uc2')).items[0]!.id;
    expect(await r.svc.respond('uc2', id2)).toBe('already_responding');
    expect((await r.svc.open('uc2', id2))!.state).toBe('responding');
  });

  it('when one contact responds, every contact\'s phone is told to stop ringing', async () => {
    const { r, id } = await live();
    await r.svc.respond('uc1', id);
    const clears = r.push.sent.filter((s) => s.p.kind === 'clear');
    expect(clears.map((c) => c.userId).sort()).toEqual(['uc1', 'uc2']);
    expect(clears.every((c) => c.p.sosId && c.p.inboxId)).toBe(true);
    expect(clears[0]!.p.text).toBe('responded');
  });

  it('when the person cancels, contacts\' phones stop ringing; a duress "cancel" does not stop them', async () => {
    const a = await live();
    const sosId = (await a.r.store.getLiveEvent('u1'))!.id;
    await a.r.engine.submitPin('u1', sosId, '1234');
    expect(a.r.push.sent.filter((s) => s.p.kind === 'clear' && s.p.text === 'cancelled').map((c) => c.userId).sort()).toEqual(['uc1', 'uc2']);

    const b = await live();
    const sos2 = (await b.r.store.getLiveEvent('u1'))!.id;
    await b.r.engine.submitPin('u1', sos2, '4321'); // duress: looks cancelled to a watcher
    expect(b.r.push.sent.some((s) => s.p.kind === 'clear')).toBe(false);
  });

  it('nobody else can open or answer someone else\'s alert', async () => {
    const { r, id } = await live();
    expect(await r.svc.open('stranger', id)).toBeNull();
    expect(await r.svc.open('uc2', id)).toBeNull();
    expect(await r.svc.respond('stranger', id)).toBe('not_found');
  });

  it('no call button under duress, and the alert says not to call', async () => {
    const r = await rig();
    const { sosId } = await r.engine.start('u1', 'shake', GEO);
    await r.sched.advance(5000);
    await r.engine.submitPin('u1', sosId, '4321'); // duress PIN
    await r.sched.advance(25_000);
    const duress = (await r.svc.list('uc1')).items.find((i) => i.kind === 'duress');
    expect(duress).toBeTruthy();
    expect((await r.svc.open('uc1', duress!.id))!.callPhone).toBeNull();
  });

  it('shows an ended alert as ended, with no position', async () => {
    const { r, id } = await live();
    const sosId = (await r.store.getLiveEvent('u1'))!.id;
    await r.engine.submitPin('u1', sosId, '1234');
    const d = (await r.svc.open('uc1', id))!;
    expect(d.state).toBe('ended');
    expect(d.geo).toBeNull();
    expect(d.canRespond).toBe(false);
    expect(await r.svc.respond('uc1', id)).toBe('ended');
  });

  it('low-battery notices keep a fixed position and cannot be "responded" to', async () => {
    const r = await rig();
    await r.engine.lowBattery('u1', GEO);
    const e = (await r.svc.list('uc1')).items[0]!;
    expect(e.kind).toBe('low_battery');
    const d = (await r.svc.open('uc1', e.id))!;
    expect(d.geo).toMatchObject({ lat: GEO.lat });
    expect(d.canRespond).toBe(false);
    expect(await r.svc.respond('uc1', e.id)).toBe('not_allowed');
  });
});

describe('invitations', () => {
  it('a person who has the app sees who added them, and can accept or decline', async () => {
    const r = await rig();
    const inv = (await r.svc.list('uc1')).invites;
    expect(inv).toEqual([{ contactId: 'c1', fromUserId: 'u1', fromName: 'Ada' }]);
    expect(await r.svc.decideInvite('uc1', 'c1', 'accept')).toBe(true);
    expect((await r.svc.list('uc1')).invites).toHaveLength(0);
  });

  it('only the person the contact entry belongs to can answer it', async () => {
    const r = await rig();
    expect(await r.svc.decideInvite('stranger', 'c1', 'decline')).toBe(false);
    expect(await r.svc.decideInvite('uc2', 'c1', 'accept')).toBe(false);
    expect((await r.store.getContacts('u1')).map((c) => c.id)).toContain('c1');
  });
});

describe('test alert', () => {
  it('lets the owner check that contacts are reachable, rate limited, and cannot be answered', async () => {
    const r = await rig();
    const out = await r.svc.sendTest('u1');
    expect(out).toEqual({ sent: 2, reachable: 2, total: 3 });
    const e = (await r.svc.list('uc1')).items[0]!;
    expect(e.kind).toBe('test');
    expect(await r.svc.respond('uc1', e.id)).toBe('not_allowed');
    expect(await r.svc.sendTest('u1')).toBe('rate_limited');
  });
});

describe('inbox retention', () => {
  it('drops items past their purge time', async () => {
    const r = await rig();
    await r.engine.lowBattery('u1', GEO);
    expect(await r.inbox.purge(r.clock.now + 73 * 3_600_000)).toBe(2);
    expect((await r.svc.list('uc1')).items).toHaveLength(0);
  });
});

describe('inbox HTTP API', () => {
  async function api() {
    const r = await rig();
    const app = buildApp({ engine: r.engine, authenticate: async (req) => (req.headers['x-user'] as string | undefined) ?? null, startLimiter: new FixedWindowLimiter(5, 60_000) });
    registerInboxRoutes(app, { service: r.svc, authenticate: async (req) => (req.headers['x-user'] as string | undefined) ?? null, limiter: new FixedWindowLimiter(100, 60_000) });
    await r.engine.start('u1', 'shake', GEO);
    await r.sched.advance(5000);
    return { r, app };
  }
  const as = (u: string) => ({ 'x-user': u });

  it('needs a signed-in user', async () => {
    const { app } = await api();
    expect((await app.inject({ method: 'GET', url: '/v1/inbox' })).statusCode).toBe(401);
    expect((await app.inject({ method: 'POST', url: '/v1/test-alert' })).statusCode).toBe(401);
  });

  it('lists, opens and answers an alert', async () => {
    const { app } = await api();
    const list = (await app.inject({ method: 'GET', url: '/v1/inbox', headers: as('uc1') })).json();
    expect(list.unread).toBe(1);
    const id = list.items[0].id as string;
    const open = await app.inject({ method: 'GET', url: `/v1/inbox/${id}`, headers: as('uc1') });
    expect(open.json()).toMatchObject({ state: 'active', canRespond: true });
    const res = await app.inject({ method: 'POST', url: `/v1/inbox/${id}/respond`, headers: as('uc1') });
    expect(res.json()).toEqual({ result: 'ok' });
  });

  it('answers 404 for someone else\'s item and 403 for an item that cannot be answered', async () => {
    const { app, r } = await api();
    const id = (await r.svc.list('uc1')).items[0]!.id;
    expect((await app.inject({ method: 'GET', url: `/v1/inbox/${id}`, headers: as('stranger') })).statusCode).toBe(404);
    await r.svc.sendTest('u1');
    const test = (await r.svc.list('uc1')).items.find((i) => i.kind === 'test')!;
    expect((await app.inject({ method: 'POST', url: `/v1/inbox/${test.id}/respond`, headers: as('uc1') })).statusCode).toBe(403);
  });

  it('validates the invitation answer', async () => {
    const { app } = await api();
    expect((await app.inject({ method: 'POST', url: '/v1/invites/c1', headers: as('uc1'), payload: { decision: 'maybe' } })).statusCode).toBe(400);
    expect((await app.inject({ method: 'POST', url: '/v1/invites/c1', headers: as('stranger'), payload: { decision: 'accept' } })).statusCode).toBe(404);
    expect((await app.inject({ method: 'POST', url: '/v1/invites/c1', headers: as('uc1'), payload: { decision: 'accept' } })).statusCode).toBe(204);
  });
});
