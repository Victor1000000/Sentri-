import type { Pool } from 'pg';
import type { ConsentStatus, ConsentStore, Contact, Link, Locale, SosEvent, SosState, SosStore, User, UserPins } from '../../domain/types.js';
import type { FieldCrypto } from '../../lib/field-crypto.js';

/** SosEvent field -> column. Patches are translated through this map, so only known columns are ever written. */
const COLS: Record<keyof SosEvent, string> = {
  id: 'id',
  userId: 'user_id',
  state: 'state',
  duress: 'duress',
  trigger: 'trigger_type',
  startedAt: 'started_at',
  cancelWindowEndsAt: 'cancel_window_ends_at',
  ackedAt: 'acked_at',
  ackedBy: 'acked_by',
  endedAt: 'ended_at',
  repeatCount: 'repeat_count',
  lastGeo: 'last_geo',
  lastSeenAt: 'last_seen_at',
  offlineNotified: 'offline_notified',
  dispatched: 'dispatched',
  pinFailures: 'pin_failures',
  pinLockedUntil: 'pin_locked_until',
  purgeAfter: 'purge_after',
};

type Row = Record<string, unknown>;

function toEvent(r: Row): SosEvent {
  return {
    id: r.id as string,
    userId: r.user_id as string,
    state: r.state as SosState,
    duress: r.duress as boolean,
    trigger: r.trigger_type as SosEvent['trigger'],
    startedAt: Number(r.started_at),
    cancelWindowEndsAt: Number(r.cancel_window_ends_at),
    ackedAt: r.acked_at == null ? undefined : Number(r.acked_at),
    ackedBy: (r.acked_by as string | null) ?? undefined,
    endedAt: r.ended_at == null ? undefined : Number(r.ended_at),
    repeatCount: r.repeat_count as number,
    lastGeo: (r.last_geo as SosEvent['lastGeo']) ?? undefined,
    lastSeenAt: Number(r.last_seen_at),
    offlineNotified: r.offline_notified as boolean,
    dispatched: r.dispatched as boolean,
    pinFailures: r.pin_failures as number,
    pinLockedUntil: Number(r.pin_locked_until),
    purgeAfter: Number(r.purge_after),
  };
}

function setClause(patch: Partial<SosEvent>, firstParam: number): { sql: string; values: unknown[] } {
  const parts: string[] = [];
  const values: unknown[] = [];
  for (const [k, v] of Object.entries(patch) as [keyof SosEvent, unknown][]) {
    if (v === undefined) continue;
    // Own keys of the fixed map only, so a key like "constructor" or "__proto__" can never become SQL.
    const col = Object.hasOwn(COLS, k) ? COLS[k] : undefined;
    if (!col) throw new Error(`unknown SosEvent field: ${String(k)}`);
    values.push(k === 'lastGeo' ? JSON.stringify(v) : v);
    parts.push(`${col} = $${firstParam + values.length - 1}`);
  }
  return { sql: parts.join(', '), values };
}

export class PgSosStore implements SosStore, ConsentStore {
  constructor(
    private readonly pool: Pool,
    private readonly fc: FieldCrypto,
  ) {}

  async createEventIfNoActive(e: SosEvent): Promise<{ created: boolean; event: SosEvent }> {
    const ins = await this.pool.query(
      `INSERT INTO sos_events (id, user_id, state, duress, trigger_type, started_at, cancel_window_ends_at,
         repeat_count, last_geo, last_seen_at, offline_notified, dispatched, pin_failures, pin_locked_until, purge_after)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15)
       ON CONFLICT DO NOTHING RETURNING *`,
      [
        e.id, e.userId, e.state, e.duress, e.trigger, e.startedAt, e.cancelWindowEndsAt,
        e.repeatCount, e.lastGeo ? JSON.stringify(e.lastGeo) : null, e.lastSeenAt,
        e.offlineNotified, e.dispatched, e.pinFailures, e.pinLockedUntil, e.purgeAfter,
      ],
    );
    if (ins.rows[0]) return { created: true, event: toEvent(ins.rows[0]) };
    // The partial unique index rejected it: this user already has a live SOS.
    const cur = await this.pool.query(
      `SELECT * FROM sos_events WHERE user_id = $1 AND state IN ('countdown','active') LIMIT 1`,
      [e.userId],
    );
    if (!cur.rows[0]) throw new Error('sos insert conflicted but no live event found');
    return { created: false, event: toEvent(cur.rows[0]) };
  }

  async getEvent(id: string): Promise<SosEvent | null> {
    const r = await this.pool.query('SELECT * FROM sos_events WHERE id = $1', [id]);
    return r.rows[0] ? toEvent(r.rows[0]) : null;
  }

  async getLiveEvent(userId: string): Promise<SosEvent | null> {
    const r = await this.pool.query(
      `SELECT * FROM sos_events WHERE user_id = $1 AND state IN ('countdown','active') LIMIT 1`,
      [userId],
    );
    return r.rows[0] ? toEvent(r.rows[0]) : null;
  }

  async updateEvent(id: string, patch: Partial<SosEvent>): Promise<SosEvent | null> {
    const { sql, values } = setClause(patch, 2);
    if (!sql) return this.getEvent(id);
    const r = await this.pool.query(`UPDATE sos_events SET ${sql} WHERE id = $1 RETURNING *`, [id, ...values]);
    return r.rows[0] ? toEvent(r.rows[0]) : null;
  }

  async transition(id: string, from: SosState[], patch: Partial<SosEvent>): Promise<SosEvent | null> {
    const { sql, values } = setClause(patch, 3);
    if (!sql) throw new Error('transition needs a non-empty patch');
    const r = await this.pool.query(
      `UPDATE sos_events SET ${sql} WHERE id = $1 AND state = ANY($2::sos_state[]) RETURNING *`,
      [id, from, ...values],
    );
    return r.rows[0] ? toEvent(r.rows[0]) : null;
  }

  async getUser(id: string): Promise<User | null> {
    const r = await this.pool.query('SELECT id, phone_enc, locale FROM users WHERE id = $1 AND deleted_at IS NULL', [id]);
    const row = r.rows[0];
    return row ? { id: row.id, phone: this.fc.decrypt(row.phone_enc), locale: row.locale as Locale } : null;
  }

  async getContacts(userId: string): Promise<Contact[]> {
    const r = await this.pool.query(
      `SELECT c.id, c.user_id, c.phone_enc, c.locale, c.priority,
              EXISTS (SELECT 1 FROM users u WHERE u.phone_hmac = c.phone_hmac AND u.deleted_at IS NULL) AS has_app
         FROM contacts c
        WHERE c.user_id = $1 AND c.consent_status <> 'declined' ORDER BY c.priority, c.id`,
      [userId],
    );
    return r.rows.map((row) => ({
      id: row.id,
      userId: row.user_id,
      phone: this.fc.decrypt(row.phone_enc),
      locale: row.locale as Locale,
      hasApp: row.has_app,
      priority: row.priority,
    }));
  }

  async getPins(userId: string): Promise<UserPins | null> {
    const r = await this.pool.query('SELECT cancel_pin, duress_pin FROM users WHERE id = $1', [userId]);
    const row = r.rows[0];
    return row?.cancel_pin && row?.duress_pin ? { cancel: row.cancel_pin, duress: row.duress_pin } : null;
  }

  async saveLink(l: Link): Promise<void> {
    await this.pool.query(
      `INSERT INTO links (hash, kind, subject, contact_id, expires_at) VALUES ($1,$2,$3,$4,$5)
       ON CONFLICT (hash) DO UPDATE SET expires_at = EXCLUDED.expires_at`,
      [l.hash, l.kind, l.subject, l.contactId, l.expiresAt],
    );
  }

  async getLink(hash: string): Promise<Link | null> {
    const r = await this.pool.query('SELECT hash, kind, subject, contact_id, expires_at FROM links WHERE hash = $1', [hash]);
    const row = r.rows[0];
    return row
      ? { hash: row.hash, kind: row.kind, subject: row.subject, contactId: row.contact_id, expiresAt: Number(row.expires_at) }
      : null;
  }

  async setConsent(contactId: string, status: ConsentStatus): Promise<boolean> {
    const r = await this.pool.query('UPDATE contacts SET consent_status = $2 WHERE id = $1', [contactId, status]);
    return (r.rowCount ?? 0) > 0;
  }

  /** Retention job: removes finished SOS events (and their links) past `purge_after`. Returns rows deleted. */
  async purgeExpired(now: number): Promise<number> {
    await this.pool.query('DELETE FROM links WHERE expires_at < $1', [now]);
    const r = await this.pool.query(
      `DELETE FROM sos_events WHERE purge_after < $1 AND state IN ('acknowledged','cancelled','expired')`,
      [now],
    );
    return r.rowCount ?? 0;
  }
}
