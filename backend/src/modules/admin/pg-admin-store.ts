import type { Pool } from 'pg';
import type { Admin, AdminActions, AreaRow, DirectoryEdit, DirectoryRow, AdminRequest, AdminStore, Approval, RequestState, SosSummary } from './types.js';

const toAdmin = (r: Record<string, any>): Admin => ({
  id: r.id, email: r.email, password: r.password, totpEnc: r.totp_enc, failedLogins: r.failed_logins,
  lockedUntil: Number(r.locked_until), lastTotpStep: Number(r.last_totp_step), createdAt: Number(r.created_at),
  disabledAt: r.disabled_at == null ? undefined : Number(r.disabled_at),
});

const toRequest = (r: Record<string, any>): AdminRequest => ({
  id: r.id, kind: r.kind, payload: r.payload, reason: r.reason, requestedBy: r.requested_by, state: r.state,
  createdAt: Number(r.created_at), expiresAt: Number(r.expires_at),
  executedAt: r.executed_at == null ? undefined : Number(r.executed_at),
  grantExpiresAt: r.grant_expires_at == null ? undefined : Number(r.grant_expires_at),
});

export class PgAdminStore implements AdminStore {
  constructor(private readonly pool: Pool) {}

  async createAdmin(a: Admin) {
    await this.pool.query(
      'INSERT INTO admins (id, email, password, totp_enc, failed_logins, locked_until, last_totp_step, created_at) VALUES ($1,$2,$3,$4,0,0,0,$5)',
      [a.id, a.email, JSON.stringify(a.password), a.totpEnc, a.createdAt],
    );
  }
  async getAdmin(id: string) {
    const r = await this.pool.query('SELECT * FROM admins WHERE id = $1', [id]);
    return r.rows[0] ? toAdmin(r.rows[0]) : null;
  }
  async getAdminByEmail(email: string) {
    const r = await this.pool.query('SELECT * FROM admins WHERE email = $1', [email]);
    return r.rows[0] ? toAdmin(r.rows[0]) : null;
  }
  async listAdmins() {
    return (await this.pool.query('SELECT * FROM admins ORDER BY created_at')).rows.map(toAdmin);
  }
  async countActiveAdmins() {
    return Number((await this.pool.query('SELECT count(*)::int AS n FROM admins WHERE disabled_at IS NULL')).rows[0].n);
  }
  async recordLoginFailure(id: string, now: number, max: number, lockMs: number) {
    await this.pool.query(
      `UPDATE admins SET failed_logins = CASE WHEN failed_logins + 1 >= $2 THEN 0 ELSE failed_logins + 1 END,
                         locked_until = CASE WHEN failed_logins + 1 >= $2 THEN $3::bigint ELSE locked_until END
        WHERE id = $1`,
      [id, max, now + lockMs],
    );
  }
  async recordLoginSuccess(id: string, step: number) {
    const r = await this.pool.query('UPDATE admins SET last_totp_step = $2, failed_logins = 0 WHERE id = $1 AND last_totp_step < $2', [id, step]);
    return (r.rowCount ?? 0) > 0;
  }
  async disableAdmin(id: string, now: number) {
    const r = await this.pool.query('UPDATE admins SET disabled_at = $2 WHERE id = $1 AND disabled_at IS NULL', [id, now]);
    return (r.rowCount ?? 0) > 0;
  }

  async createRequest(r: AdminRequest) {
    await this.pool.query(
      'INSERT INTO admin_requests (id, kind, payload, reason, requested_by, state, created_at, expires_at) VALUES ($1,$2,$3,$4,$5,$6,$7,$8)',
      [r.id, r.kind, JSON.stringify(r.payload), r.reason, r.requestedBy, r.state, r.createdAt, r.expiresAt],
    );
  }
  async getRequest(id: string) {
    const r = await this.pool.query('SELECT * FROM admin_requests WHERE id = $1', [id]);
    return r.rows[0] ? toRequest(r.rows[0]) : null;
  }
  async listRequests(states?: RequestState[]) {
    const r = states
      ? await this.pool.query('SELECT * FROM admin_requests WHERE state = ANY($1::text[]) ORDER BY created_at DESC LIMIT 200', [states])
      : await this.pool.query('SELECT * FROM admin_requests ORDER BY created_at DESC LIMIT 200');
    return r.rows.map(toRequest);
  }
  async transitionRequest(id: string, from: RequestState[], to: RequestState, patch: Partial<AdminRequest> = {}) {
    const r = await this.pool.query(
      `UPDATE admin_requests SET state = $3,
         executed_at = COALESCE($4, executed_at), grant_expires_at = COALESCE($5, grant_expires_at)
       WHERE id = $1 AND state = ANY($2::text[]) RETURNING *`,
      [id, from, to, patch.executedAt ?? null, patch.grantExpiresAt ?? null],
    );
    return r.rows[0] ? toRequest(r.rows[0]) : null;
  }
  async addApproval(a: Approval) {
    const r = await this.pool.query(
      'INSERT INTO admin_approvals (request_id, admin_id, decision, at) VALUES ($1,$2,$3,$4) ON CONFLICT DO NOTHING',
      [a.requestId, a.adminId, a.decision, a.at],
    );
    return (r.rowCount ?? 0) > 0;
  }
  async getApprovals(requestId: string) {
    const r = await this.pool.query('SELECT request_id, admin_id, decision, at FROM admin_approvals WHERE request_id = $1 ORDER BY at', [requestId]);
    return r.rows.map((x) => ({ requestId: x.request_id, adminId: x.admin_id, decision: x.decision, at: Number(x.at) }));
  }
}

export class PgAdminActions implements AdminActions {
  constructor(private readonly pool: Pool) {}

  async verifyControlRoom(controlRoomId: string, verifiedBy: string, at: number) {
    const r = await this.pool.query('UPDATE control_rooms SET verified_by = $2, verified_at = $3 WHERE id = $1', [controlRoomId, verifiedBy, at]);
    return (r.rowCount ?? 0) > 0;
  }

  async upsertControlRoom(e: DirectoryEdit, at: number) {
    if (e.controlRoomId) {
      // Editing clears verification: the changed entry must be verified again before it can be routed to.
      const r = await this.pool.query(
        `UPDATE control_rooms SET admin_area_id=$2, name=$3, kind=$4, official_phone=$5, official_sms=$6, source=$7,
                updated_at=$8, verified_by=NULL, verified_at=NULL, active=TRUE
          WHERE id=$1 RETURNING id`,
        [e.controlRoomId, e.adminAreaId, e.name, e.kind, e.officialPhone ?? null, e.officialSms ?? null, e.source, at],
      );
      return (r.rows[0]?.id as string | undefined) ?? null;
    }
    const area = await this.pool.query('SELECT 1 FROM admin_areas WHERE id = $1', [e.adminAreaId]);
    if (!area.rowCount) return null;
    const r = await this.pool.query(
      `INSERT INTO control_rooms (admin_area_id, name, kind, official_phone, official_sms, source, updated_at)
       VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING id`,
      [e.adminAreaId, e.name, e.kind, e.officialPhone ?? null, e.officialSms ?? null, e.source, at],
    );
    return r.rows[0].id as string;
  }

  async retireControlRoom(id: string) {
    const r = await this.pool.query('UPDATE control_rooms SET active = FALSE WHERE id = $1', [id]);
    return (r.rowCount ?? 0) > 0;
  }

  async listAreas(): Promise<AreaRow[]> {
    const r = await this.pool.query('SELECT id, name, level FROM admin_areas ORDER BY level, name');
    return r.rows.map((x) => ({ id: x.id, name: x.name, level: x.level }));
  }

  async listDirectory(): Promise<DirectoryRow[]> {
    const r = await this.pool.query(
      `SELECT cr.id, cr.admin_area_id, a.name AS area, cr.name, cr.kind, cr.official_phone, cr.official_sms,
              cr.source, cr.verified_at, cr.active
         FROM control_rooms cr JOIN admin_areas a ON a.id = cr.admin_area_id
        ORDER BY a.name, cr.name`,
    );
    return r.rows.map((x) => ({
      id: x.id, areaId: x.admin_area_id, area: x.area, name: x.name, kind: x.kind,
      officialPhone: x.official_phone ?? undefined, officialSms: x.official_sms ?? undefined, source: x.source ?? undefined,
      verified: x.verified_at != null, verifiedAt: x.verified_at == null ? undefined : Number(x.verified_at), active: x.active,
    }));
  }

  async recentEvents(userId: string, sinceMs: number, limit: number): Promise<SosSummary[]> {
    const r = await this.pool.query(
      `SELECT id, state, trigger_type, started_at, ended_at, last_geo FROM sos_events
        WHERE user_id = $1 AND started_at >= $2 ORDER BY started_at DESC LIMIT $3`,
      [userId, sinceMs, limit],
    );
    return r.rows.map((x) => ({
      id: x.id, state: x.state, trigger: x.trigger_type, startedAt: Number(x.started_at),
      endedAt: x.ended_at == null ? undefined : Number(x.ended_at),
      lastGeo: x.last_geo ? { lat: x.last_geo.lat, lon: x.last_geo.lon, at: x.last_geo.at } : undefined,
    }));
  }
}
