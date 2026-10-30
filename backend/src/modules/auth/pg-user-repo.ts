import type { Pool } from 'pg';
import type { Locale, UserPins } from '../../domain/types.js';
import type { FieldCrypto } from '../../lib/field-crypto.js';
import type { OtpRecord, OtpStore } from './otp.js';
import { LiveSosError } from './phone.js';

/** A contact as stored. `isNew` is false when the same number was already on the list (its consent answer is kept). */
export interface SavedContact {
  id: string;
  phone: string;
  locale: Locale;
  isNew: boolean;
}

/** What the owner sees about their contact list. */
export interface ContactSummary {
  id: string;
  phone: string;
  locale: Locale;
  consent: 'pending' | 'accepted' | 'declined';
  /** The person has the app, so an alert can actually reach them. */
  reachable: boolean;
}

export interface UserRepo {
  findOrCreateUserByPhone(phone: string, locale: Locale): Promise<{ userId: string; isNew: boolean }>;
  getPhone(userId: string): Promise<string | null>;
  registerDevice(
    userId: string,
    d: { platform: 'android' | 'ios'; publicKey: Buffer; boxPublicKey: Buffer },
    refreshHash: string,
  ): Promise<string>;
  /** Swaps the refresh token if `oldHash` matches. Returns the user id, or null if it doesn't. */
  rotateRefresh(deviceId: string, oldHash: string, newHash: string): Promise<string | null>;
  replaceContacts(userId: string, contacts: { phone: string; locale: Locale }[]): Promise<SavedContact[]>;
  listContacts(userId: string): Promise<ContactSummary[]>;
  setPins(userId: string, pins: UserPins): Promise<void>;
  updateProfile(userId: string, p: { locale?: Locale; dataSaver?: boolean; name?: string }): Promise<void>;
  setPushToken(userId: string, deviceId: string, token: string): Promise<void>;
}

export class PgUserRepo implements UserRepo, OtpStore {
  constructor(
    private readonly pool: Pool,
    private readonly fc: FieldCrypto,
    private readonly clock: () => number = Date.now,
  ) {}

  // ---- users / devices ----

  async findOrCreateUserByPhone(phone: string, locale: Locale): Promise<{ userId: string; isNew: boolean }> {
    const idx = this.fc.blindIndex(phone);
    const ins = await this.pool.query(
      `INSERT INTO users (phone_hmac, phone_enc, locale, created_at) VALUES ($1,$2,$3,$4)
       ON CONFLICT (phone_hmac) DO NOTHING RETURNING id`,
      [idx, this.fc.encrypt(phone), locale, this.clock()],
    );
    if (ins.rows[0]) return { userId: ins.rows[0].id, isNew: true };
    const r = await this.pool.query('SELECT id FROM users WHERE phone_hmac = $1 AND deleted_at IS NULL', [idx]);
    if (!r.rows[0]) throw new Error('account unavailable');
    return { userId: r.rows[0].id, isNew: false };
  }

  async getPhone(userId: string): Promise<string | null> {
    const r = await this.pool.query('SELECT phone_enc FROM users WHERE id = $1', [userId]);
    return r.rows[0] ? this.fc.decrypt(r.rows[0].phone_enc) : null;
  }

  async registerDevice(
    userId: string,
    d: { platform: 'android' | 'ios'; publicKey: Buffer; boxPublicKey: Buffer },
    refreshHash: string,
  ): Promise<string> {
    const r = await this.pool.query(
      `INSERT INTO devices (user_id, platform, public_key, box_public_key, refresh_hash, last_seen_at)
       VALUES ($1,$2,$3,$4,$5,$6) RETURNING id`,
      [userId, d.platform, d.publicKey, d.boxPublicKey, refreshHash, this.clock()],
    );
    return r.rows[0].id;
  }

  async rotateRefresh(deviceId: string, oldHash: string, newHash: string): Promise<string | null> {
    const r = await this.pool.query(
      `UPDATE devices SET refresh_hash = $3, last_seen_at = $4
        WHERE id = $1 AND refresh_hash = $2 AND revoked_at IS NULL RETURNING user_id`,
      [deviceId, oldHash, newHash, this.clock()],
    );
    return r.rows[0]?.user_id ?? null;
  }

  // ---- onboarding ----

  async replaceContacts(userId: string, contacts: { phone: string; locale: Locale }[]): Promise<SavedContact[]> {
    const c = await this.pool.connect();
    try {
      await c.query('BEGIN');
      // Lock the user row so an SOS can't start between this check and the delete.
      await c.query('SELECT 1 FROM users WHERE id = $1 FOR UPDATE', [userId]);
      const live = await c.query(
        `SELECT 1 FROM sos_events WHERE user_id = $1 AND state IN ('countdown','active') LIMIT 1`,
        [userId],
      );
      if ((live.rowCount ?? 0) > 0) throw new LiveSosError();
      // Remember earlier consent answers by number, so re-saving the list never re-invites or un-declines anyone.
      const prior = await c.query('SELECT phone_hmac, consent_status FROM contacts WHERE user_id = $1', [userId]);
      const priorStatus = new Map<string, string>(prior.rows.map((r) => [Buffer.from(r.phone_hmac).toString('hex'), r.consent_status as string]));
      await c.query('DELETE FROM contacts WHERE user_id = $1', [userId]);
      const saved: SavedContact[] = [];
      for (const [i, ct] of contacts.entries()) {
        const idx = this.fc.blindIndex(ct.phone);
        const app = await c.query('SELECT 1 FROM users WHERE phone_hmac = $1 AND deleted_at IS NULL', [idx]);
        const before = priorStatus.get(Buffer.from(idx).toString('hex'));
        const ins = await c.query(
          `INSERT INTO contacts (user_id, phone_hmac, phone_enc, locale, has_app, priority, consent_status)
           VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING id`,
          [userId, idx, this.fc.encrypt(ct.phone), ct.locale, (app.rowCount ?? 0) > 0, i, before ?? 'pending'],
        );
        saved.push({ id: ins.rows[0].id as string, phone: ct.phone, locale: ct.locale, isNew: before === undefined });
      }
      await c.query('COMMIT');
      return saved;
    } catch (err) {
      await c.query('ROLLBACK');
      throw err;
    } finally {
      c.release();
    }
  }

  async listContacts(userId: string): Promise<ContactSummary[]> {
    const r = await this.pool.query(
      `SELECT c.id, c.phone_enc, c.locale, c.consent_status,
              EXISTS (SELECT 1 FROM users u WHERE u.phone_hmac = c.phone_hmac AND u.deleted_at IS NULL) AS reachable
         FROM contacts c WHERE c.user_id = $1 ORDER BY c.priority, c.id`,
      [userId],
    );
    return r.rows.map((row) => ({
      id: String(row.id),
      phone: this.fc.decrypt(row.phone_enc),
      locale: row.locale as Locale,
      consent: row.consent_status,
      reachable: row.reachable === true,
    }));
  }

  async setPins(userId: string, pins: UserPins): Promise<void> {
    await this.pool.query('UPDATE users SET cancel_pin = $2, duress_pin = $3 WHERE id = $1', [
      userId,
      JSON.stringify(pins.cancel),
      JSON.stringify(pins.duress),
    ]);
  }

  async updateProfile(userId: string, p: { locale?: Locale; dataSaver?: boolean; name?: string }): Promise<void> {
    await this.pool.query(
      'UPDATE users SET locale = COALESCE($2, locale), data_saver = COALESCE($3, data_saver), name_enc = COALESCE($4, name_enc) WHERE id = $1',
      [userId, p.locale ?? null, p.dataSaver ?? null, p.name ? this.fc.encrypt(p.name) : null],
    );
  }

  async setPushToken(userId: string, deviceId: string, token: string): Promise<void> {
    await this.pool.query('UPDATE devices SET push_token_enc = $3 WHERE id = $2 AND user_id = $1', [
      userId,
      deviceId,
      this.fc.encrypt(token),
    ]);
  }

  // ---- OTP store ----

  async create(c: { id: string; phoneHmac: Buffer; codeHash: Buffer; createdAt: number; expiresAt: number }): Promise<void> {
    await this.pool.query(
      'INSERT INTO otp_challenges (id, phone_hmac, code_hash, created_at, expires_at) VALUES ($1,$2,$3,$4,$5)',
      [c.id, c.phoneHmac, c.codeHash, c.createdAt, c.expiresAt],
    );
  }

  async latest(phoneHmac: Buffer): Promise<OtpRecord | null> {
    const r = await this.pool.query(
      'SELECT id, code_hash, attempts, expires_at, consumed_at FROM otp_challenges WHERE phone_hmac = $1 ORDER BY created_at DESC LIMIT 1',
      [phoneHmac],
    );
    const row = r.rows[0];
    return row
      ? {
          id: row.id,
          codeHash: row.code_hash,
          attempts: row.attempts,
          expiresAt: Number(row.expires_at),
          consumedAt: row.consumed_at == null ? undefined : Number(row.consumed_at),
        }
      : null;
  }

  async bumpAttempts(id: string): Promise<number> {
    const r = await this.pool.query('UPDATE otp_challenges SET attempts = attempts + 1 WHERE id = $1 RETURNING attempts', [id]);
    return r.rows[0] ? Number(r.rows[0].attempts) : Infinity;
  }

  async consume(id: string, at: number): Promise<boolean> {
    const r = await this.pool.query('UPDATE otp_challenges SET consumed_at = $2 WHERE id = $1 AND consumed_at IS NULL', [id, at]);
    return (r.rowCount ?? 0) === 1;
  }

  async countSince(phoneHmac: Buffer, sinceMs: number): Promise<number> {
    const r = await this.pool.query('SELECT count(*)::int AS n FROM otp_challenges WHERE phone_hmac = $1 AND created_at >= $2', [
      phoneHmac,
      sinceMs,
    ]);
    return r.rows[0].n;
  }

  async recentOpen(phoneHmac: Buffer, nowMs: number, count: number): Promise<OtpRecord[]> {
    const r = await this.pool.query(
      'SELECT id, code_hash, attempts, expires_at FROM otp_challenges WHERE phone_hmac = $1 AND consumed_at IS NULL AND expires_at > $2 ORDER BY created_at DESC LIMIT $3',
      [phoneHmac, nowMs, count],
    );
    return r.rows.map((row) => ({
      id: row.id,
      codeHash: row.code_hash,
      attempts: row.attempts,
      expiresAt: Number(row.expires_at),
    }));
  }
}
