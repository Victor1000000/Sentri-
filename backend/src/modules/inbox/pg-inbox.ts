import type { Pool } from 'pg';
import type { Locale } from '../../domain/types.js';
import type { FieldCrypto } from '../../lib/field-crypto.js';
import type { InboxItem, InboxKind, InboxStore, Invite } from './types.js';

export class PgInbox implements InboxStore {
  constructor(
    private readonly pool: Pool,
    private readonly fc: FieldCrypto,
  ) {}

  private name(buf: Buffer | null): string | undefined {
    if (!buf) return undefined;
    try {
      return this.fc.decrypt(buf);
    } catch {
      return undefined; // key changed: show "Someone" rather than fail the alert
    }
  }

  private toItem(r: Record<string, any>): InboxItem {
    return {
      id: r.id,
      userId: r.user_id,
      fromUserId: r.from_user_id,
      fromName: this.name(r.from_name_enc),
      kind: r.kind as InboxKind,
      sosId: r.sos_id ?? null,
      shareId: r.share_id ?? null,
      locale: r.locale as Locale,
      geo: r.geo ?? undefined,
      createdAt: Number(r.created_at),
      updatedAt: Number(r.updated_at),
      readAt: r.read_at == null ? undefined : Number(r.read_at),
      purgeAfter: Number(r.purge_after),
    };
  }

  async forSos(sosId: string) {
    const r = await this.pool.query("SELECT user_id, id FROM inbox_items WHERE sos_id = $1 AND kind IN ('sos','duress','offline')", [sosId]);
    return r.rows.map((x) => ({ userId: x.user_id as string, itemId: x.id as string }));
  }

  async recipientFor(contactId: string) {
    const r = await this.pool.query(
      `SELECT u.id FROM contacts c JOIN users u ON u.phone_hmac = c.phone_hmac AND u.deleted_at IS NULL WHERE c.id = $1`,
      [contactId],
    );
    return (r.rows[0]?.id as string | undefined) ?? null;
  }

  async contactIdFor(fromUserId: string, recipientUserId: string) {
    const r = await this.pool.query(
      `SELECT c.id FROM contacts c JOIN users u ON u.phone_hmac = c.phone_hmac AND u.deleted_at IS NULL
        WHERE c.user_id = $1 AND u.id = $2`,
      [fromUserId, recipientUserId],
    );
    return (r.rows[0]?.id as string | undefined) ?? null;
  }

  async displayName(userId: string) {
    const r = await this.pool.query('SELECT name_enc FROM users WHERE id = $1', [userId]);
    return this.name(r.rows[0]?.name_enc ?? null) ?? null;
  }

  async phoneOf(userId: string) {
    const r = await this.pool.query('SELECT phone_enc FROM users WHERE id = $1 AND deleted_at IS NULL', [userId]);
    return r.rows[0] ? this.fc.decrypt(r.rows[0].phone_enc) : null;
  }

  async upsert(i: InboxItem): Promise<InboxItem> {
    const nameEnc = i.fromName ? this.fc.encrypt(i.fromName) : null;
    const geo = i.geo ? JSON.stringify(i.geo) : null;
    const cols = [i.id, i.userId, i.fromUserId, nameEnc, i.kind, i.sosId, i.shareId ?? null, i.locale, geo, i.createdAt, i.updatedAt, i.purgeAfter];
    const insert = `INSERT INTO inbox_items (id,user_id,from_user_id,from_name_enc,kind,sos_id,share_id,locale,geo,created_at,updated_at,purge_after)
         VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)`;
    const refresh = `DO UPDATE SET updated_at = EXCLUDED.updated_at, geo = COALESCE(EXCLUDED.geo, inbox_items.geo),
                       from_name_enc = COALESCE(EXCLUDED.from_name_enc, inbox_items.from_name_enc)
         RETURNING *`;
    const sql = i.sosId
      ? `${insert} ON CONFLICT (user_id, sos_id, kind) WHERE sos_id IS NOT NULL ${refresh}`
      : i.shareId
        ? `${insert} ON CONFLICT (user_id, share_id, kind) WHERE share_id IS NOT NULL ${refresh}`
        : `${insert} RETURNING *`;
    return this.toItem((await this.pool.query(sql, cols)).rows[0]);
  }

  async list(userId: string, limit: number) {
    const r = await this.pool.query('SELECT * FROM inbox_items WHERE user_id = $1 ORDER BY updated_at DESC LIMIT $2', [userId, limit]);
    return r.rows.map((x) => this.toItem(x));
  }

  async get(userId: string, id: string) {
    const r = await this.pool.query('SELECT * FROM inbox_items WHERE user_id = $1 AND id = $2', [userId, id]);
    return r.rows[0] ? this.toItem(r.rows[0]) : null;
  }

  async markRead(userId: string, id: string, at: number) {
    const r = await this.pool.query('UPDATE inbox_items SET read_at = COALESCE(read_at, $3) WHERE user_id = $1 AND id = $2', [userId, id, at]);
    return (r.rowCount ?? 0) > 0;
  }

  async invitesFor(userId: string): Promise<Invite[]> {
    const r = await this.pool.query(
      `SELECT c.id, c.user_id, o.name_enc
         FROM contacts c
         JOIN users me ON me.phone_hmac = c.phone_hmac AND me.deleted_at IS NULL
         JOIN users o ON o.id = c.user_id AND o.deleted_at IS NULL
        WHERE me.id = $1 AND c.consent_status = 'pending'
        ORDER BY c.id`,
      [userId],
    );
    return r.rows.map((x) => ({ contactId: x.id, fromUserId: x.user_id, fromName: this.name(x.name_enc) }));
  }

  async decideInvite(userId: string, contactId: string, status: 'accepted' | 'declined') {
    const r = await this.pool.query(
      `UPDATE contacts c SET consent_status = $3
         FROM users me
        WHERE c.id = $2 AND me.id = $1 AND me.phone_hmac = c.phone_hmac AND me.deleted_at IS NULL`,
      [userId, contactId, status],
    );
    return (r.rowCount ?? 0) > 0;
  }

  async purge(now: number) {
    return (await this.pool.query('DELETE FROM inbox_items WHERE purge_after < $1', [now])).rowCount ?? 0;
  }
}
