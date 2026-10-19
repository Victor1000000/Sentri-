/**
 * Integration tests against a real PostgreSQL + PostGIS. Skipped unless TEST_DATABASE_URL is set.
 *
 *   docker compose up -d postgres
 *   createdb -h localhost -U <user> sentri_test      # the database name must contain "test"
 *   TEST_DATABASE_URL=postgres://<user>:<pw>@localhost:5432/sentri_test npm run test:integration
 *
 * The test database is wiped at the start of the run. A guard refuses names without "test".
 */
import { randomUUID } from 'node:crypto';
import pg from 'pg';
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import type { SosEvent } from '../src/domain/types.js';
import { createPool, migrate } from '../src/db/migrate.js';
import { FieldCrypto } from '../src/lib/field-crypto.js';
import { PgAudit } from '../src/modules/audit/pg-audit.js';
import { LiveSosError } from '../src/modules/auth/phone.js';
import { PgUserRepo } from '../src/modules/auth/pg-user-repo.js';
import { PgDirectory } from '../src/modules/dispatch/pg-directory.js';
import { PgPushTokens } from '../src/modules/notify/pg-push-tokens.js';
import { PgShares } from '../src/modules/share/pg-share.js';
import { PgInbox } from '../src/modules/inbox/pg-inbox.js';
import { pgRetentionTasks } from '../src/modules/retention/pg-retention.js';
import { PgSosStore } from '../src/modules/sos/pg-store.js';
import { PgAdminActions, PgAdminStore } from '../src/modules/admin/pg-admin-store.js';
import { AdminService, type Provisioned } from '../src/modules/admin/service.js';
import { stepOf, totpAt } from '../src/modules/admin/totp.js';

const URL_ = process.env.TEST_DATABASE_URL;
const DAY = 86_400_000;

describe.skipIf(!URL_)('PostgreSQL integration', () => {
  let pool: pg.Pool;
  const fc = new FieldCrypto('ab'.repeat(32), 'cd'.repeat(32));
  let now = 1_800_000_000_000;
  const clock = () => now;
  let store: PgSosStore;
  let repo: PgUserRepo;

  beforeAll(async () => {
    if (!/test/i.test(new globalThis.URL(URL_!).pathname)) throw new Error('TEST_DATABASE_URL must point at a database whose name contains "test"');
    pool = createPool(URL_!);
    await pool.query('DROP SCHEMA public CASCADE; CREATE SCHEMA public;');
    await migrate(pool);
    store = new PgSosStore(pool, fc);
    repo = new PgUserRepo(pool, fc, clock);
  });

  afterAll(async () => {
    await pool?.end();
  });

  beforeEach(async () => {
    await pool.query('TRUNCATE sos_events, location_shares, links, contacts, devices, otp_challenges, users, audit_log RESTART IDENTITY CASCADE');
  });

  const newUser = async (phone: string) => (await repo.findOrCreateUserByPhone(phone, 'en')).userId;
  const event = (userId: string, over: Partial<SosEvent> = {}): SosEvent => ({
    id: randomUUID(), userId, state: 'active', duress: false, trigger: 'shake', startedAt: now, cancelWindowEndsAt: now + 5000,
    repeatCount: 0, lastSeenAt: now, offlineNotified: false, dispatched: false, pinFailures: 0, pinLockedUntil: 0, purgeAfter: now + DAY, ...over,
  });
  const three = [
    { phone: '+2348031111111', locale: 'en' as const },
    { phone: '+2348032222222', locale: 'pcm' as const },
    { phone: '+2348033333333', locale: 'ha' as const },
  ];

  it('applies migrations once and is idempotent', async () => {
    expect(await migrate(pool)).toEqual([]);
    const r = await pool.query("SELECT name FROM schema_migrations ORDER BY name");
    expect(r.rows.map((x) => x.name)).toContain('002_consent_links.sql');
  });

  it('encrypts phone numbers at rest and finds them by blind index', async () => {
    const id = await newUser('+2348000000001');
    const raw = await pool.query('SELECT phone_enc FROM users WHERE id = $1', [id]);
    expect(Buffer.from(raw.rows[0].phone_enc).toString('utf8')).not.toContain('2348000000001');
    expect((await repo.findOrCreateUserByPhone('+2348000000001', 'en')).isNew).toBe(false);
    expect(await repo.getPhone(id)).toBe('+2348000000001');
  });

  describe('SOS store', () => {
    it('allows only one live SOS per user', async () => {
      const u = await newUser('+2348000000002');
      const a = await store.createEventIfNoActive(event(u));
      const b = await store.createEventIfNoActive(event(u));
      expect(a.created).toBe(true);
      expect(b.created).toBe(false);
      expect(b.event.id).toBe(a.event.id);
      expect((await store.getLiveEvent(u))?.id).toBe(a.event.id);
    });

    it('compare-and-set: of two racing transitions exactly one wins', async () => {
      const u = await newUser('+2348000000003');
      const { event: e } = await store.createEventIfNoActive(event(u));
      const [x, y] = await Promise.all([
        store.transition(e.id, ['active'], { state: 'acknowledged', ackedAt: now }),
        store.transition(e.id, ['active'], { state: 'cancelled', endedAt: now }),
      ]);
      expect([x, y].filter(Boolean)).toHaveLength(1);
      expect(await store.transition(e.id, ['active'], { state: 'expired' })).toBeNull();
    });

    it('round-trips the last location and duress flag', async () => {
      const u = await newUser('+2348000000004');
      const { event: e } = await store.createEventIfNoActive(event(u));
      await store.updateEvent(e.id, { lastGeo: { lat: 6.5244, lon: 3.3792, accuracyM: 12, at: now }, duress: true });
      const got = await store.getEvent(e.id);
      expect(got?.lastGeo?.lat).toBeCloseTo(6.5244);
      expect(got?.duress).toBe(true);
    });

    it('purges only finished events past their purge time', async () => {
      const u1 = await newUser('+2348000000005');
      const u2 = await newUser('+2348000000006');
      const u3 = await newUser('+2348000000007');
      const old = await store.createEventIfNoActive(event(u1, { state: 'cancelled', purgeAfter: now - 1 }));
      const fresh = await store.createEventIfNoActive(event(u2, { state: 'cancelled', purgeAfter: now + DAY }));
      const live = await store.createEventIfNoActive(event(u3, { state: 'active', purgeAfter: now - 1 }));
      expect(await store.purgeExpired(now)).toBe(1);
      expect(await store.getEvent(old.event.id)).toBeNull();
      expect(await store.getEvent(fresh.event.id)).not.toBeNull();
      expect(await store.getEvent(live.event.id)).not.toBeNull(); // never purge a live alert
    });
  });

  describe('contacts and consent', () => {
    it('stores contacts encrypted, returns ids, and marks who already has the app', async () => {
      const owner = await newUser('+2348000000010');
      await newUser('+2348031111111'); // a contact who also uses Sentri
      const saved = await repo.replaceContacts(owner, three);
      expect(saved.every((c) => c.isNew)).toBe(true);
      const list = await store.getContacts(owner);
      expect(list.map((c) => c.phone)).toEqual(three.map((c) => c.phone));
      expect(list.map((c) => c.hasApp)).toEqual([true, false, false]);
    });

    it('a declined contact gets no alerts, and stays declined when the list is saved again', async () => {
      const owner = await newUser('+2348000000011');
      const saved = await repo.replaceContacts(owner, three);
      expect(await store.setConsent(saved[1].id, 'declined')).toBe(true);
      expect((await store.getContacts(owner)).map((c) => c.phone)).toEqual([three[0].phone, three[2].phone]);
      const again = await repo.replaceContacts(owner, three);
      expect(again.map((c) => c.isNew)).toEqual([false, false, false]);
      expect((await store.getContacts(owner)).map((c) => c.phone)).not.toContain(three[1].phone);
    });

    it('refuses to change contacts while an alert is live', async () => {
      const owner = await newUser('+2348000000012');
      await repo.replaceContacts(owner, three);
      await store.createEventIfNoActive(event(owner));
      await expect(repo.replaceContacts(owner, three)).rejects.toBeInstanceOf(LiveSosError);
      expect(await store.getContacts(owner)).toHaveLength(3); // rolled back, nothing lost
    });

    it('accepts consent links in the links table', async () => {
      const owner = await newUser('+2348000000013');
      const saved = await repo.replaceContacts(owner, three);
      await store.saveLink({ hash: 'h'.repeat(64), kind: 'consent', subject: `c:${saved[0].id}`, contactId: saved[0].id, expiresAt: now + DAY });
      expect((await store.getLink('h'.repeat(64)))?.kind).toBe('consent');
    });
  });

  describe('in-app inbox', () => {
    const itemFor = (userId: string, fromUserId: string, sosId: string | null, over: Record<string, unknown> = {}) => ({
      id: randomUUID(), userId, fromUserId, fromName: 'Ada', kind: 'sos' as const, sosId, locale: 'en' as const,
      createdAt: now, updatedAt: now, purgeAfter: now + DAY, ...over,
    });

    it('finds the person behind a contact entry only when they have the app, and reports them as reachable', async () => {
      const owner = await newUser('+2348000000030');
      const friend = await newUser('+2348031111111');
      const saved = await repo.replaceContacts(owner, three);
      const inbox = new PgInbox(pool, fc);
      expect(await inbox.recipientFor(saved[0].id)).toBe(friend);
      expect(await inbox.recipientFor(saved[1].id)).toBeNull();
      expect((await repo.listContacts(owner)).map((c) => c.reachable)).toEqual([true, false, false]);
      // a contact who signs up later becomes reachable without saving the list again
      await newUser('+2348032222222');
      expect((await repo.listContacts(owner)).map((c) => c.reachable)).toEqual([true, true, false]);
      expect((await store.getContacts(owner)).map((c) => c.hasApp)).toEqual([true, true, false]);
    });

    it('keeps the sender name encrypted, and one row per alert however often it repeats', async () => {
      const owner = await newUser('+2348000000031');
      const friend = await newUser('+2348031111111');
      await repo.updateProfile(owner, { name: 'Ada' });
      const inbox = new PgInbox(pool, fc);
      expect(await inbox.displayName(owner)).toBe('Ada');
      const raw = await pool.query('SELECT name_enc FROM users WHERE id = $1', [owner]);
      expect(Buffer.from(raw.rows[0].name_enc).toString('utf8')).not.toContain('Ada');
      const sos = randomUUID();
      const a = await inbox.upsert(itemFor(friend, owner, sos));
      const b = await inbox.upsert(itemFor(friend, owner, sos, { updatedAt: now + 25_000 }));
      expect(b.id).toBe(a.id);
      expect(b.updatedAt).toBe(now + 25_000);
      expect((await inbox.list(friend, 10))).toHaveLength(1);
      expect((await inbox.list(friend, 10))[0]!.fromName).toBe('Ada');
      const nameCol = await pool.query('SELECT from_name_enc FROM inbox_items');
      expect(Buffer.from(nameCol.rows[0].from_name_enc).toString('utf8')).not.toContain('Ada');
    });

    it('only the recipient can read, mark or purge their items; items without an SOS are separate rows', async () => {
      const owner = await newUser('+2348000000032');
      const friend = await newUser('+2348031111111');
      const other = await newUser('+2348034444444');
      const inbox = new PgInbox(pool, fc);
      const i = await inbox.upsert(itemFor(friend, owner, null, { kind: 'test' }));
      await inbox.upsert(itemFor(friend, owner, null, { kind: 'test' }));
      expect(await inbox.list(friend, 10)).toHaveLength(2);
      expect(await inbox.get(other, i.id)).toBeNull();
      expect(await inbox.markRead(other, i.id, now)).toBe(false);
      expect(await inbox.markRead(friend, i.id, now)).toBe(true);
      expect((await inbox.get(friend, i.id))!.readAt).toBe(now);
      expect(await inbox.purge(now + 2 * DAY)).toBe(2);
    });

    it('invitations: found by phone, answered only by that person, and a decline stops alerts', async () => {
      const owner = await newUser('+2348000000033');
      const friend = await newUser('+2348031111111');
      const stranger = await newUser('+2348035555555');
      const saved = await repo.replaceContacts(owner, three);
      const inbox = new PgInbox(pool, fc);
      expect((await inbox.invitesFor(friend)).map((x) => x.contactId)).toEqual([saved[0].id]);
      expect(await inbox.invitesFor(stranger)).toEqual([]);
      expect(await inbox.decideInvite(stranger, saved[0].id, 'declined')).toBe(false);
      expect(await inbox.contactIdFor(owner, friend)).toBe(saved[0].id);
      expect(await inbox.decideInvite(friend, saved[0].id, 'declined')).toBe(true);
      expect(await inbox.invitesFor(friend)).toEqual([]);
      expect((await store.getContacts(owner)).map((c) => c.phone)).not.toContain(three[0].phone);
    });

    it('is cleared with the account that owns it', async () => {
      const owner = await newUser('+2348000000034');
      const friend = await newUser('+2348031111111');
      const inbox = new PgInbox(pool, fc);
      await inbox.upsert(itemFor(friend, owner, randomUUID()));
      await pool.query('DELETE FROM users WHERE id = $1', [friend]);
      expect((await pool.query('SELECT 1 FROM inbox_items')).rowCount).toBe(0);
    });
  });

  describe('location shares', () => {
    it('keeps only the latest position, ends once, and refuses updates from anyone else or after the end', async () => {
      const owner = await newUser('+2348000000040');
      const friend = await newUser('+2348031111111');
      const shares = new PgShares(pool);
      const id = randomUUID();
      await shares.create({ id, userId: owner, recipientIds: [friend], startedAt: now, expiresAt: now + 3_600_000, purgeAfter: now + DAY });
      expect(await shares.updateGeo(friend, id, { lat: 1, lon: 1, at: now }, now)).toBe(false);
      expect(await shares.updateGeo(owner, id, { lat: 6.5, lon: 3.3, accuracyM: 8, at: now }, now)).toBe(true);
      expect(await shares.updateGeo(owner, id, { lat: 6.6, lon: 3.4, at: now + 1 }, now)).toBe(true);
      expect((await shares.get(id))!.lastGeo).toMatchObject({ lat: 6.6, lon: 3.4 });
      expect((await shares.get(id))!.recipientIds).toEqual([friend]);
      expect(await shares.active(owner, now)).toHaveLength(1);
      expect(await shares.due(now)).toHaveLength(0);
      expect(await shares.due(now + 3_600_001)).toHaveLength(1);
      expect(await shares.updateGeo(owner, id, { lat: 1, lon: 1, at: now }, now + 3_600_001)).toBe(false);
      expect(await shares.extend(owner, id, now + 7_200_000, now)).toBe(true);
      expect(await shares.end(friend, id, now)).toBeNull();
      expect((await shares.end(owner, id, now))!.endedAt).toBe(now);
      expect(await shares.end(owner, id, now)).toBeNull();
      expect(await shares.active(owner, now)).toHaveLength(0);
      expect(await shares.purge(now + 2 * DAY)).toBe(1);
    });

    it('share inbox items are one row per share and kind, and go with the account', async () => {
      const owner = await newUser('+2348000000041');
      const friend = await newUser('+2348031111111');
      const inbox = new PgInbox(pool, fc);
      const sid = randomUUID();
      const mk = (kind: 'share_start' | 'share_stop', at: number) => ({
        id: randomUUID(), userId: friend, fromUserId: owner, fromName: 'Ada', kind, sosId: null, shareId: sid, locale: 'en' as const,
        createdAt: at, updatedAt: at, purgeAfter: now + DAY,
      });
      const a = await inbox.upsert(mk('share_start', now));
      const b = await inbox.upsert(mk('share_start', now + 5));
      await inbox.upsert(mk('share_stop', now + 9));
      expect(b.id).toBe(a.id);
      expect((await inbox.list(friend, 10)).map((i) => i.kind).sort()).toEqual(['share_start', 'share_stop']);
      expect((await inbox.get(friend, a.id))!.shareId).toBe(sid);
      await pool.query('DELETE FROM users WHERE id = $1', [friend]);
      expect((await pool.query('SELECT 1 FROM inbox_items')).rowCount).toBe(0);
    });
  });

  describe('retention tasks', () => {
    it('removes old OTPs, revoked devices and deleted accounts, and keeps what is still needed', async () => {
      const keep = await newUser('+2348000000020');
      const gone = await newUser('+2348000000021');
      const blocked = await newUser('+2348000000022');
      await pool.query('UPDATE users SET deleted_at = $2 WHERE id = $1', [gone, now - 31 * DAY]);
      await pool.query('UPDATE users SET deleted_at = $2 WHERE id = $1', [blocked, now - 31 * DAY]);
      // `blocked` still has an SOS event on file, so the account must stay until that is purged.
      await store.createEventIfNoActive(event(blocked, { state: 'cancelled', purgeAfter: now + DAY }));
      const dev = (rev: number | null) => pool.query(
        `INSERT INTO devices (user_id, platform, public_key, box_public_key, refresh_hash, revoked_at) VALUES ($1,'android',$2,$2,'x',$3)`,
        [keep, Buffer.from('k'), rev],
      );
      await dev(now - 40 * DAY); // revoked long ago: goes
      await dev(now - 1 * DAY); // revoked recently: stays
      await dev(null); // active: stays
      const otp = (exp: number) => pool.query('INSERT INTO otp_challenges (phone_hmac, code_hash, created_at, expires_at) VALUES ($1,$2,$3,$4)', [Buffer.from('p'), Buffer.from('c'), exp - 300_000, exp]);
      await otp(now - 2 * DAY); // goes
      await otp(now + 60_000); // still valid: stays

      const tasks = pgRetentionTasks(pool, (n) => store.purgeExpired(n));
      const counts: Record<string, number> = {};
      for (const t of tasks) counts[t.name] = await t.run(now);
      expect(counts).toEqual({ sos_events: 0, inbox_items: 0, location_shares: 0, otp_challenges: 1, devices: 1, deleted_users: 1 });
      expect((await pool.query('SELECT id FROM users')).rows.map((r) => r.id).sort()).toEqual([keep, blocked].sort());
      expect((await pool.query('SELECT 1 FROM devices')).rowCount).toBe(2);
    });
  });

  describe('police directory (PostGIS)', () => {
    async function seed(verified: boolean) {
      await pool.query("INSERT INTO countries (code, name, default_emergency_number) VALUES ('NG','Nigeria','112') ON CONFLICT DO NOTHING");
      const a = await pool.query(
        `INSERT INTO admin_areas (country_code, level, name, boundary)
         VALUES ('NG', 1, 'Testland', ST_GeogFromText('MULTIPOLYGON(((3.0 6.0, 4.0 6.0, 4.0 7.0, 3.0 7.0, 3.0 6.0)))')) RETURNING id`,
      );
      await pool.query(
        `INSERT INTO control_rooms (admin_area_id, name, kind, official_phone, verified_by, verified_at)
         VALUES ($1, 'Testland Command', 'state_command', '+2340000000000', $2, $3)`,
        [a.rows[0].id, verified ? 'test' : null, verified ? now : null],
      );
    }
    beforeEach(async () => {
      await pool.query('TRUNCATE control_rooms, admin_areas, countries RESTART IDENTITY CASCADE');
    });

    it('routes a point inside the area to its verified command', async () => {
      await seed(true);
      const room = await new PgDirectory(pool).resolve({ lat: 6.5, lon: 3.5, at: now });
      expect(room?.name).toBe('Testland Command');
    });

    it('never routes to an unverified entry', async () => {
      await seed(false);
      expect(await new PgDirectory(pool).resolve({ lat: 6.5, lon: 3.5, at: now })).toBeNull();
    });

    it('returns nothing for a point outside every area', async () => {
      await seed(true);
      expect(await new PgDirectory(pool).resolve({ lat: 10, lon: 10, at: now })).toBeNull();
    });
  });

  describe('push tokens', () => {
    it('finds a contact\'s devices through their phone number, skips revoked ones, and forgets bad tokens', async () => {
      const owner = await newUser('+2348000000030');
      const friend = await newUser('+2348031111111');
      const saved = await repo.replaceContacts(owner, three);
      const d1 = await repo.registerDevice(friend, { platform: 'android', publicKey: Buffer.from('a'), boxPublicKey: Buffer.from('b') }, 'h1');
      const d2 = await repo.registerDevice(friend, { platform: 'ios', publicKey: Buffer.from('a'), boxPublicKey: Buffer.from('b') }, 'h2');
      await repo.setPushToken(friend, d1, 'token-android');
      await repo.setPushToken(friend, d2, 'token-ios');
      await pool.query('UPDATE devices SET revoked_at = $2 WHERE id = $1', [d2, now]);
      const tokens = new PgPushTokens(pool, fc);
      expect((await tokens.tokensForContact(saved[0].id)).map((t) => t.token)).toEqual(['token-android']);
      expect(await tokens.tokensForContact(saved[1].id)).toEqual([]); // contact without the app
      await tokens.forgetToken(d1);
      expect(await tokens.tokensForUser(friend)).toEqual([]);
    });
  });

  describe('audit log', () => {
    it('chains each entry to the one before it', async () => {
      const audit = new PgAudit(pool, clock);
      await audit.append('system', 'sos.start', 'a');
      await audit.append('system', 'sos.cancel', 'a');
      await audit.append('system', 'sos.purge', 'a');
      const rows = (await pool.query('SELECT prev_hash, entry_hash FROM audit_log ORDER BY id')).rows;
      expect(rows).toHaveLength(3);
      expect(rows[1].prev_hash).toBe(rows[0].entry_hash);
      expect(rows[2].prev_hash).toBe(rows[1].entry_hash);
      expect(await audit.verify()).toBe(true);
    });
  });
  describe('admin console and directory editing', () => {
    let t = 1_800_000_000_000;
    let n = 0;
    const svc = () => new AdminService(new PgAdminStore(pool), new PgAdminActions(pool), new PgAudit(pool, () => t), fc, 'x'.repeat(32), () => t, () => `00000000-0000-4000-8000-${String(++n).padStart(12, '0')}`);
    const loginAs = async (s: AdminService, p: Provisioned) => {
      t += 30_000; // each authenticator code works once
      const r = await s.login(p.email, p.password, totpAt(p.totpSecret, stepOf(t)));
      return (await s.authenticate(r.token))!;
    };
    let areaId: number;
    beforeEach(async () => {
      await pool.query('TRUNCATE admin_approvals, admin_requests, admins, control_rooms, admin_areas, countries RESTART IDENTITY CASCADE');
      await pool.query("INSERT INTO countries (code, name) VALUES ('NG','Nigeria')");
      areaId = (await pool.query("INSERT INTO admin_areas (country_code, level, name) VALUES ('NG', 1, 'Testland') RETURNING id")).rows[0].id;
    });

    it('migration 004 seeds the 36 states and the FCT as names', async () => {
      // Seeded by the migration, then wiped by the test setup above, so check what the migration file itself would insert.
      const sql = (await import('node:fs')).readFileSync(new globalThis.URL('../src/db/migrations/004_directory_admin.sql', import.meta.url), 'utf8');
      expect((sql.match(/^\s+\('[^']+'\)/gm) ?? []).length).toBe(37);
    });

    it('runs the whole two-person flow for a police entry against the real tables', async () => {
      const s = svc();
      const pa = await s.provision('a@x.ng', 'boot');
      const pb = await s.provision('b@x.ng', 'boot');
      const [a, b] = [await loginAs(s, pa), await loginAs(s, pb)];
      const why = 'Adding command from official letter';

      const up = await s.createRequest(a, 'directory_upsert', { adminAreaId: areaId, name: 'Testland Command', kind: 'state_command', officialPhone: '08030000000', source: 'Letter 14' }, why);
      await expect(s.decide(a, up.id, 'approve')).rejects.toMatchObject({ code: 'forbidden' });
      expect((await s.decide(b, up.id, 'approve')).state).toBe('approved');
      expect((await s.execute(a, up.id)).note).toMatch(/UNVERIFIED/);
      let [room] = await s.directory();
      expect(room).toMatchObject({ area: 'Testland', name: 'Testland Command', verified: false, active: true, source: 'Letter 14' });

      const ver = await s.createRequest(b, 'directory_verify', { controlRoomId: room.id, source: 'Called the duty officer' }, why);
      await s.decide(a, ver.id, 'approve');
      await s.execute(b, ver.id);
      [room] = await s.directory();
      expect(room.verified).toBe(true);
      expect((await pool.query('SELECT verified_by FROM control_rooms WHERE id = $1', [room.id])).rows[0].verified_by).toBe(b.id);

      const edit = await s.createRequest(a, 'directory_upsert', { controlRoomId: room.id, adminAreaId: areaId, name: 'Testland Command', kind: 'state_command', officialPhone: '08031112222', source: 'Letter 15' }, why);
      await s.decide(b, edit.id, 'approve');
      await s.execute(a, edit.id);
      [room] = await s.directory();
      expect(room).toMatchObject({ verified: false, officialPhone: '08031112222' });

      const ret = await s.createRequest(a, 'directory_retire', { controlRoomId: room.id }, why);
      await s.decide(b, ret.id, 'approve');
      await s.execute(a, ret.id);
      expect((await s.directory())[0].active).toBe(false);

      expect((await s.list(['executed'])).length).toBe(4);
      expect((await s.list(['pending'])).length).toBe(0);
      expect((await s.areas()).map((x) => x.name)).toEqual(['Testland']);
      expect((await s.admins()).map((x) => x.email).sort()).toEqual(['a@x.ng', 'b@x.ng']);
      expect(await new PgAudit(pool, () => t).verify()).toBe(true);
    });

    it('the database itself refuses a self-approval, and an unknown request kind', async () => {
      const s = svc();
      const pa = await s.provision('a@x.ng', 'boot');
      const a = await loginAs(s, pa);
      const r = await s.createRequest(a, 'admin_add', { email: 'c@x.ng' }, 'A long enough reason');
      await expect(pool.query('INSERT INTO admin_approvals (request_id, admin_id, decision, at) VALUES ($1,$2,$3,$4)', [r.id, a.id, 'approve', t])).rejects.toThrow(/own request/);
      await expect(pool.query("UPDATE admin_requests SET kind = 'bogus' WHERE id = $1", [r.id])).rejects.toThrow();
    });

    it('a login code works once, and two racing executes let exactly one through', async () => {
      const s = svc();
      const pa = await s.provision('a@x.ng', 'boot');
      const pb = await s.provision('b@x.ng', 'boot');
      t += 30_000;
      const code = totpAt(pa.totpSecret, stepOf(t));
      await s.login(pa.email, pa.password, code);
      await expect(s.login(pa.email, pa.password, code)).rejects.toMatchObject({ code: 'invalid_credentials' });

      const a = await loginAs(s, pa);
      const b = await loginAs(s, pb);
      const r = await s.createRequest(a, 'admin_add', { email: 'c@x.ng' }, 'A long enough reason');
      await s.decide(b, r.id, 'approve');
      const results = await Promise.allSettled([s.execute(a, r.id), s.execute(b, r.id)]);
      expect(results.filter((x) => x.status === 'fulfilled')).toHaveLength(1);
      expect((await pool.query("SELECT count(*)::int AS n FROM admins WHERE email = 'c@x.ng'")).rows[0].n).toBe(1);
    });
  });
});
