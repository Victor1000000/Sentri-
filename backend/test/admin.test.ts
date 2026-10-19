import { describe, expect, it } from 'vitest';
import Fastify from 'fastify';
import { FieldCrypto } from '../src/lib/field-crypto.js';
import { FixedWindowLimiter } from '../src/lib/rate-limit.js';
import { MemoryAdminActions, MemoryAdminStore } from '../src/modules/admin/memory-admin-store.js';
import { registerAdminRoutes } from '../src/modules/admin/routes.js';
import { AdminError, AdminService, GRANT_TTL_MS, REQUEST_TTL_MS, type Provisioned } from '../src/modules/admin/service.js';
import { base32Decode, base32Encode, newTotpSecret, otpauthUri, stepOf, totpAt, verifyTotp } from '../src/modules/admin/totp.js';
import type { Admin } from '../src/modules/admin/types.js';
import { MemorySosStore } from '../src/modules/sos/memory-store.js';

describe('TOTP (RFC 6238)', () => {
  const secret = base32Encode(Buffer.from('12345678901234567890'));
  it('matches the RFC test vectors (last 6 digits of the 8-digit codes)', () => {
    expect(totpAt(secret, Math.floor(59 / 30))).toBe('287082');
    expect(totpAt(secret, Math.floor(1111111109 / 30))).toBe('081804');
    expect(totpAt(secret, Math.floor(2000000000 / 30))).toBe('279037');
  });
  it('round-trips base32', () => {
    const b = Buffer.from('hello world!!');
    expect(base32Decode(base32Encode(b)).equals(b)).toBe(true);
    expect(newTotpSecret()).toMatch(/^[A-Z2-7]{32}$/);
  });
  it('accepts one step of drift each way, and nothing further', () => {
    const now = 1_700_000_000_000;
    const step = stepOf(now);
    expect(verifyTotp(secret, totpAt(secret, step), now)).toBe(step);
    expect(verifyTotp(secret, totpAt(secret, step - 1), now)).toBe(step - 1);
    expect(verifyTotp(secret, totpAt(secret, step + 1), now)).toBe(step + 1);
    expect(verifyTotp(secret, totpAt(secret, step - 2), now)).toBeNull();
    expect(verifyTotp(secret, 'abcdef', now)).toBeNull();
    expect(verifyTotp(secret, '12345', now)).toBeNull();
  });
  it('builds an authenticator link', () => {
    expect(otpauthUri('a@b.ng', 'ABC')).toContain('secret=ABC');
  });
});

function rig() {
  let now = 1_800_000_000_000;
  const clock = () => now;
  const store = new MemoryAdminStore();
  const sos = new MemorySosStore();
  const log: { actor: string; action: string; target?: string }[] = [];
  const audit = { append: async (actor: string, action: string, target?: string) => void log.push({ actor, action, target }) };
  const fc = new FieldCrypto('ab'.repeat(32), 'cd'.repeat(32));
  let n = 0;
  const newId = () => `00000000-0000-4000-8000-${String(++n).padStart(12, '0')}`;
  const svc = new AdminService(store, new MemoryAdminActions(sos), audit, fc, 'x'.repeat(32), clock, newId);
  const tick = (ms: number) => (now += ms);
  /** Logs in with a fresh code (each code works once, so move to the next step first). */
  const loginAs = async (p: Provisioned) => {
    tick(30_000);
    const r = await svc.login(p.email, p.password, totpAt(p.totpSecret, stepOf(now)));
    return (await svc.authenticate(r.token))!;
  };
  return { svc, store, sos, log, tick, clock, loginAs };
}

async function threeAdmins() {
  const r = rig();
  const p = [await r.svc.provision('a@x.ng', 'boot'), await r.svc.provision('b@x.ng', 'boot'), await r.svc.provision('c@x.ng', 'boot')];
  const [a, b, c] = [await r.loginAs(p[0]), await r.loginAs(p[1]), await r.loginAs(p[2])] as [Admin, Admin, Admin];
  return { ...r, p, a, b, c };
}

const WHY = 'Support case 1234, user reported abuse';
const U = '11111111-1111-4111-8111-111111111111';

describe('admin login', () => {
  it('needs the right password and a fresh authenticator code', async () => {
    const r = rig();
    const p = await r.svc.provision('a@x.ng', 'boot');
    r.tick(30_000);
    const code = totpAt(p.totpSecret, stepOf(r.clock()));
    await expect(r.svc.login(p.email, 'wrong-password', code)).rejects.toMatchObject({ code: 'invalid_credentials' });
    await expect(r.svc.login(p.email, p.password, '000000')).rejects.toMatchObject({ code: 'invalid_credentials' });
    await expect(r.svc.login('nobody@x.ng', p.password, code)).rejects.toMatchObject({ code: 'invalid_credentials' });
    const ok = await r.svc.login(p.email, p.password, code);
    expect(await r.svc.authenticate(ok.token)).toMatchObject({ email: 'a@x.ng' });
  });

  it('refuses a code that was already used', async () => {
    const r = rig();
    const p = await r.svc.provision('a@x.ng', 'boot');
    r.tick(30_000);
    const code = totpAt(p.totpSecret, stepOf(r.clock()));
    await r.svc.login(p.email, p.password, code);
    await expect(r.svc.login(p.email, p.password, code)).rejects.toMatchObject({ code: 'invalid_credentials' });
  });

  it('locks the account after five failures, then lets it back in later', async () => {
    const r = rig();
    const p = await r.svc.provision('a@x.ng', 'boot');
    for (let i = 0; i < 5; i++) await expect(r.svc.login(p.email, 'bad', '000000')).rejects.toBeInstanceOf(AdminError);
    r.tick(30_000);
    await expect(r.svc.login(p.email, p.password, totpAt(p.totpSecret, stepOf(r.clock())))).rejects.toMatchObject({ code: 'locked' });
    r.tick(16 * 60_000);
    await expect(r.svc.login(p.email, p.password, totpAt(p.totpSecret, stepOf(r.clock())))).resolves.toBeTruthy();
  });

  it('a user-app token is not an admin session', async () => {
    const { signAccessToken } = await import('../src/modules/auth/jwt.js');
    const r = rig();
    expect(await r.svc.authenticate(signAccessToken({ sub: 'u1', did: 'device' }, 'x'.repeat(32), 900, r.clock()))).toBeNull();
    expect(await r.svc.authenticate(signAccessToken({ sub: 'u1', did: 'admin' }, 'y'.repeat(32), 900, r.clock()))).toBeNull();
  });
});

describe('two-person approval', () => {
  it('needs a reason, and the requester cannot approve their own request', async () => {
    const { svc, a } = await threeAdmins();
    await expect(svc.createRequest(a, 'admin_add', { email: 'd@x.ng' }, 'short')).rejects.toMatchObject({ code: 'bad_request' });
    const req = await svc.createRequest(a, 'admin_add', { email: 'd@x.ng' }, WHY);
    await expect(svc.decide(a, req.id, 'approve')).rejects.toMatchObject({ code: 'forbidden' });
    await expect(svc.execute(a, req.id)).rejects.toMatchObject({ code: 'conflict' }); // not approved yet
  });

  it('one other admin is enough for ordinary changes, and an answer cannot be given twice', async () => {
    const { svc, a, b } = await threeAdmins();
    const req = await svc.createRequest(a, 'admin_add', { email: 'd@x.ng' }, WHY);
    expect((await svc.decide(b, req.id, 'approve')).state).toBe('approved');
    await expect(svc.decide(b, req.id, 'approve')).rejects.toMatchObject({ code: 'conflict' });
  });

  it('data access needs two other people', async () => {
    const { svc, a, b, c } = await threeAdmins();
    const req = await svc.createRequest(a, 'data_access', { userId: U, sinceHours: 24 }, WHY);
    expect((await svc.decide(b, req.id, 'approve')).state).toBe('pending');
    expect((await svc.decide(c, req.id, 'approve')).state).toBe('approved');
  });

  it('a single rejection ends the request', async () => {
    const { svc, a, b, c } = await threeAdmins();
    const req = await svc.createRequest(a, 'data_access', { userId: U, sinceHours: 24 }, WHY);
    await svc.decide(b, req.id, 'approve');
    expect((await svc.decide(c, req.id, 'reject')).state).toBe('rejected');
    await expect(svc.execute(a, req.id)).rejects.toMatchObject({ code: 'conflict' });
  });

  it('requests lapse after 24 hours', async () => {
    const { svc, a, b, tick } = await threeAdmins();
    const req = await svc.createRequest(a, 'admin_add', { email: 'd@x.ng' }, WHY);
    await svc.decide(b, req.id, 'approve');
    tick(REQUEST_TTL_MS + 1);
    await expect(svc.execute(a, req.id)).rejects.toMatchObject({ code: 'expired' });
  });

  it('executes once, even if two admins press the button at the same time', async () => {
    const { svc, a, b, c } = await threeAdmins();
    const req = await svc.createRequest(a, 'admin_add', { email: 'd@x.ng' }, WHY);
    await svc.decide(b, req.id, 'approve');
    const results = await Promise.allSettled([svc.execute(a, req.id), svc.execute(c, req.id)]);
    expect(results.filter((x) => x.status === 'fulfilled')).toHaveLength(1);
  });
});

describe('what approved requests do', () => {
  it('admin_add creates an admin and hands over the one-time credentials', async () => {
    const { svc, a, b, loginAs } = await threeAdmins();
    const req = await svc.createRequest(a, 'admin_add', { email: 'new@x.ng' }, WHY);
    await svc.decide(b, req.id, 'approve');
    const out = await svc.execute(a, req.id);
    expect(out.provisioned?.email).toBe('new@x.ng');
    expect(out.provisioned?.password.length).toBeGreaterThan(15);
    expect((await loginAs(out.provisioned!)).email).toBe('new@x.ng');
  });

  it('admin_remove disables the account and its sessions stop working', async () => {
    const { svc, store, p, a, b, c } = await threeAdmins();
    const req = await svc.createRequest(a, 'admin_remove', { adminId: c.id }, WHY);
    await svc.decide(b, req.id, 'approve');
    await svc.execute(a, req.id);
    expect(await store.countActiveAdmins()).toBe(2);
    const stale = (await import('../src/modules/auth/jwt.js')).signAccessToken({ sub: c.id, did: 'admin' }, 'x'.repeat(32), 900, 1_800_000_000_000 + 1);
    expect(await svc.authenticate(stale)).toBeNull();
    expect(p.length).toBe(3);
  });

  it('you cannot remove yourself, and the last two admins cannot be removed', async () => {
    const { svc, store, a, b, c } = await threeAdmins();
    await expect(svc.createRequest(a, 'admin_remove', { adminId: a.id }, WHY)).rejects.toMatchObject({ code: 'forbidden' });
    const r1 = await svc.createRequest(a, 'admin_remove', { adminId: c.id }, WHY);
    await svc.decide(b, r1.id, 'approve');
    await svc.execute(a, r1.id);
    const r2 = await svc.createRequest(a, 'admin_remove', { adminId: b.id }, WHY);
    await svc.decide(b, r2.id, 'approve');
    const out = await svc.execute(a, r2.id);
    expect(out.note).toContain('refused');
    expect(await store.countActiveAdmins()).toBe(2);
  });

  it('directory_verify marks an entry verified (reports not found when it does not exist)', async () => {
    const { svc, a, b } = await threeAdmins();
    const req = await svc.createRequest(a, 'directory_verify', { controlRoomId: U, source: 'Letter from Lagos command, 2026-10-01' }, WHY);
    await svc.decide(b, req.id, 'approve');
    expect((await svc.execute(a, req.id)).note).toBe('control room not found'); // memory actions have no directory
  });
});

describe('break-glass data access', () => {
  async function granted() {
    const t = await threeAdmins();
    t.sos.putUser({ id: U, phone: '+2348000000000', locale: 'en' });
    await t.sos.createEventIfNoActive({
      id: 'e1', userId: U, state: 'active', duress: true, trigger: 'shake', startedAt: t.clock() - 3_600_000, cancelWindowEndsAt: 0,
      repeatCount: 0, lastGeo: { lat: 6.5, lon: 3.3, at: t.clock() }, lastSeenAt: 0, offlineNotified: false, dispatched: false, pinFailures: 0, pinLockedUntil: 0, purgeAfter: 0,
    });
    const req = await t.svc.createRequest(t.a, 'data_access', { userId: U, sinceHours: 24 }, WHY);
    await t.svc.decide(t.b, req.id, 'approve');
    await t.svc.decide(t.c, req.id, 'approve');
    return { ...t, req };
  }

  it('nothing is readable before execution', async () => {
    const { svc, a, req } = await granted();
    await expect(svc.readEvents(a, req.id)).rejects.toMatchObject({ code: 'forbidden' });
  });

  it('after execution only the requester can read, the duress flag is never included, and every read is logged', async () => {
    const { svc, a, b, req, log } = await granted();
    await svc.execute(b, req.id);
    await expect(svc.readEvents(b, req.id)).rejects.toMatchObject({ code: 'forbidden' });
    const events = await svc.readEvents(a, req.id);
    expect(events).toHaveLength(1);
    expect(JSON.stringify(events)).not.toContain('duress');
    expect(JSON.stringify(events)).not.toContain('2348000000000');
    await svc.readEvents(a, req.id);
    expect(log.filter((l) => l.action === 'data_access.read')).toHaveLength(2);
    expect(JSON.stringify(log)).not.toContain('6.5'); // audit never holds coordinates
  });

  it('the grant ends after an hour', async () => {
    const { svc, a, req, tick } = await granted();
    await svc.execute(a, req.id);
    tick(GRANT_TTL_MS + 1);
    await expect(svc.readEvents(a, req.id)).rejects.toMatchObject({ code: 'expired' });
  });
});

describe('admin HTTP API', () => {
  it('requires a session, validates payloads, and runs a request end to end', async () => {
    const t = rig();
    const pa = await t.svc.provision('a@x.ng', 'boot');
    const pb = await t.svc.provision('b@x.ng', 'boot');
    const app = Fastify();
    registerAdminRoutes(app, { admin: t.svc, loginLimiter: new FixedWindowLimiter(50, 60_000) });

    expect((await app.inject({ url: '/admin/v1/me' })).statusCode).toBe(401);
    const login = async (p: Provisioned) => {
      t.tick(30_000);
      const r = await app.inject({ method: 'POST', url: '/admin/v1/login', payload: { email: p.email, password: p.password, code: totpAt(p.totpSecret, stepOf(t.clock())) } });
      expect(r.statusCode).toBe(200);
      return { authorization: `Bearer ${r.json().token}` };
    };
    const ha = await login(pa);
    const hb = await login(pb);
    expect((await app.inject({ url: '/admin/v1/me', headers: ha })).json().email).toBe('a@x.ng');

    const bad = await app.inject({ method: 'POST', url: '/admin/v1/requests', headers: ha, payload: { kind: 'admin_add', payload: { email: 'd@x.ng', extra: 1 }, reason: WHY } });
    expect(bad.statusCode).toBe(400); // unknown fields are rejected

    const made = await app.inject({ method: 'POST', url: '/admin/v1/requests', headers: ha, payload: { kind: 'admin_add', payload: { email: 'd@x.ng' }, reason: WHY } });
    const id = made.json().request.id;
    expect((await app.inject({ method: 'POST', url: `/admin/v1/requests/${id}/approve`, headers: ha })).statusCode).toBe(403);
    expect((await app.inject({ method: 'POST', url: `/admin/v1/requests/${id}/approve`, headers: hb })).json().request.state).toBe('approved');
    const done = await app.inject({ method: 'POST', url: `/admin/v1/requests/${id}/execute`, headers: ha });
    expect(done.statusCode).toBe(200);
    expect(done.json().provisioned.email).toBe('d@x.ng');
    expect((await app.inject({ method: 'POST', url: `/admin/v1/requests/${id}/execute`, headers: ha })).statusCode).toBe(409);
  });

  it('rate limits logins', async () => {
    const t = rig();
    const app = Fastify();
    registerAdminRoutes(app, { admin: t.svc, loginLimiter: new FixedWindowLimiter(2, 60_000) });
    const go = () => app.inject({ method: 'POST', url: '/admin/v1/login', payload: { email: 'a@x.ng', password: 'x', code: '000000' } });
    await go();
    await go();
    expect((await go()).statusCode).toBe(429);
  });
});

describe('police directory editing', () => {
  const ROOM = { adminAreaId: 25, name: 'Lagos State Police Command', kind: 'state_command', officialPhone: '+234 803 000 0000', source: 'Letter ref LAG/2026/14' } as const;

  /** Request, get a second admin to approve, carry it out. */
  async function run(t: Awaited<ReturnType<typeof threeAdmins>>, kind: Parameters<AdminService['createRequest']>[1], payload: Record<string, unknown>) {
    const req = await t.svc.createRequest(t.a, kind, payload, WHY);
    await t.svc.decide(t.b, req.id, 'approve');
    return t.svc.execute(t.a, req.id);
  }

  it('a new entry starts unverified, and needs a second person before it exists', async () => {
    const t = await threeAdmins();
    const req = await t.svc.createRequest(t.a, 'directory_upsert', { ...ROOM }, WHY);
    expect(await t.svc.directory()).toHaveLength(0);
    await expect(t.svc.decide(t.a, req.id, 'approve')).rejects.toMatchObject({ code: 'forbidden' });
    await t.svc.decide(t.b, req.id, 'approve');
    const done = await t.svc.execute(t.c, req.id);
    expect(done.note).toMatch(/UNVERIFIED/);
    const [room] = await t.svc.directory();
    expect(room).toMatchObject({ area: 'Lagos', name: 'Lagos State Police Command', verified: false, active: true });
  });

  it('verification is its own approved step, and editing the number clears it again', async () => {
    const t = await threeAdmins();
    await run(t, 'directory_upsert', { ...ROOM });
    const [room] = await t.svc.directory();
    // The in-memory directory supports verification through its own marker.
    const verify = await t.svc.createRequest(t.a, 'directory_verify', { controlRoomId: room.id, source: 'Called the duty officer 2026-10-15' }, WHY);
    await t.svc.decide(t.b, verify.id, 'approve');
    await t.svc.execute(t.a, verify.id);
    expect((await t.svc.directory())[0].verified).toBe(true);

    await run(t, 'directory_upsert', { ...ROOM, controlRoomId: room.id, officialPhone: '08031112222' });
    const after = (await t.svc.directory())[0];
    expect(after.verified).toBe(false);
    expect(after.officialPhone).toBe('08031112222');
  });

  it('retiring stops routing but keeps the record; unknown ids are reported, not crashed on', async () => {
    const t = await threeAdmins();
    await run(t, 'directory_upsert', { ...ROOM });
    const [room] = await t.svc.directory();
    await run(t, 'directory_retire', { controlRoomId: room.id });
    expect((await t.svc.directory())[0].active).toBe(false);
    const missing = await run(t, 'directory_retire', { controlRoomId: '99999999-9999-4999-8999-999999999999' });
    expect(missing.note).toMatch(/not found/);
    const noArea = await run(t, 'directory_upsert', { ...ROOM, adminAreaId: 9999 });
    expect(noArea.note).toMatch(/not found/);
  });

  it('records who changed the directory, without storing the numbers in the audit log', async () => {
    const t = await threeAdmins();
    await run(t, 'directory_upsert', { ...ROOM });
    expect(t.log.some((l) => l.action === 'directory.upserted')).toBe(true);
    expect(JSON.stringify(t.log)).not.toContain('803');
  });

  it('the console API validates entries, serves the page with a strict CSP, and lists areas and admins', async () => {
    const t = rig();
    const pa = await t.svc.provision('a@x.ng', 'boot');
    const pb = await t.svc.provision('b@x.ng', 'boot');
    const app = Fastify();
    registerAdminRoutes(app, { admin: t.svc, loginLimiter: new FixedWindowLimiter(50, 60_000) });
    const login = async (p: Provisioned) => {
      t.tick(30_000);
      const r = await app.inject({ method: 'POST', url: '/admin/v1/login', payload: { email: p.email, password: p.password, code: totpAt(p.totpSecret, stepOf(t.clock())) } });
      return { authorization: `Bearer ${r.json().token}` };
    };
    const ha = await login(pa);
    const hb = await login(pb);

    const page = await app.inject({ url: '/admin' });
    expect(page.statusCode).toBe(200);
    expect(page.headers['content-security-policy']).toMatch(/default-src 'none'.*script-src 'sha256-/);
    expect(page.headers['content-security-policy']).not.toMatch(/unsafe-inline|unsafe-eval/);
    expect(page.body).toContain('Sentri admin');

    expect((await app.inject({ url: '/admin/v1/directory' })).statusCode).toBe(401);
    expect((await app.inject({ url: '/admin/v1/areas', headers: ha })).json().areas).toHaveLength(37);
    expect((await app.inject({ url: '/admin/v1/admins', headers: ha })).json().admins.map((a: { email: string }) => a.email).sort()).toEqual(['a@x.ng', 'b@x.ng']);

    const post = (payload: object) => app.inject({ method: 'POST', url: '/admin/v1/requests', headers: ha, payload: { kind: 'directory_upsert', payload, reason: WHY } });
    expect((await post({ ...ROOM, officialPhone: 'call me maybe' })).statusCode).toBe(400);
    expect((await post({ ...ROOM, officialPhone: undefined })).statusCode).toBe(400); // needs a phone or SMS
    expect((await post({ ...ROOM, source: 'x' })).statusCode).toBe(400);
    expect((await post({ ...ROOM, extra: 1 })).statusCode).toBe(400);

    const ok = await post({ ...ROOM });
    expect(ok.statusCode).toBe(200);
    expect(ok.json().request.payload.officialPhone).toBe('+2348030000000'); // spaces stripped
    const id = ok.json().request.id;
    await app.inject({ method: 'POST', url: `/admin/v1/requests/${id}/approve`, headers: hb });
    await app.inject({ method: 'POST', url: `/admin/v1/requests/${id}/execute`, headers: ha });
    const rooms = (await app.inject({ url: '/admin/v1/directory', headers: ha })).json().rooms;
    expect(rooms).toHaveLength(1);
    expect(rooms[0].verified).toBe(false);
  });
});
