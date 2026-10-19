import type { Pool } from 'pg';
import type { LocationShare, ShareGeo, ShareStore } from './types.js';

/** node-postgres returns uuid[] as an array; a driver that does not gives "{a,b}", so both are accepted. */
const ids = (v: unknown): string[] => (Array.isArray(v) ? v.map(String) : String(v).replace(/^\{|\}$/g, '').split(',').filter(Boolean));

const toShare = (r: Record<string, any>): LocationShare => ({
  id: r.id,
  userId: r.user_id,
  recipientIds: ids(r.recipient_ids),
  startedAt: Number(r.started_at),
  expiresAt: Number(r.expires_at),
  endedAt: r.ended_at == null ? undefined : Number(r.ended_at),
  lastGeo: r.last_geo ?? undefined,
  purgeAfter: Number(r.purge_after),
});

export class PgShares implements ShareStore {
  constructor(private readonly pool: Pool) {}

  async create(s: LocationShare) {
    await this.pool.query(
      'INSERT INTO location_shares (id, user_id, recipient_ids, started_at, expires_at, last_geo, purge_after) VALUES ($1,$2,$3::uuid[],$4,$5,$6,$7)',
      [s.id, s.userId, s.recipientIds, s.startedAt, s.expiresAt, s.lastGeo ? JSON.stringify(s.lastGeo) : null, s.purgeAfter],
    );
  }
  async get(id: string) {
    const r = await this.pool.query('SELECT * FROM location_shares WHERE id = $1', [id]);
    return r.rows[0] ? toShare(r.rows[0]) : null;
  }
  async active(userId: string, now: number) {
    const r = await this.pool.query('SELECT * FROM location_shares WHERE user_id = $1 AND ended_at IS NULL AND expires_at > $2', [userId, now]);
    return r.rows.map(toShare);
  }
  async updateGeo(userId: string, id: string, geo: ShareGeo, now: number) {
    const r = await this.pool.query(
      'UPDATE location_shares SET last_geo = $3 WHERE id = $1 AND user_id = $2 AND ended_at IS NULL AND expires_at > $4',
      [id, userId, JSON.stringify(geo), now],
    );
    return (r.rowCount ?? 0) > 0;
  }
  async end(userId: string, id: string, at: number) {
    const r = await this.pool.query('UPDATE location_shares SET ended_at = $3 WHERE id = $1 AND user_id = $2 AND ended_at IS NULL RETURNING *', [id, userId, at]);
    return r.rows[0] ? toShare(r.rows[0]) : null;
  }
  async extend(userId: string, id: string, expiresAt: number, now: number) {
    const r = await this.pool.query(
      'UPDATE location_shares SET expires_at = $3 WHERE id = $1 AND user_id = $2 AND ended_at IS NULL AND expires_at > $4',
      [id, userId, expiresAt, now],
    );
    return (r.rowCount ?? 0) > 0;
  }
  async due(now: number) {
    const r = await this.pool.query('SELECT * FROM location_shares WHERE ended_at IS NULL AND expires_at <= $1', [now]);
    return r.rows.map(toShare);
  }
  async purge(now: number) {
    return (await this.pool.query('DELETE FROM location_shares WHERE purge_after < $1', [now])).rowCount ?? 0;
  }
}
