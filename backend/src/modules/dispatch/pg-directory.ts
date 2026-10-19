import type { Pool } from 'pg';
import type { GeoPoint } from '../../domain/types.js';
import type { ControlRoom, Directory } from './directory.js';

/**
 * Resolves the control room for a location with PostGIS.
 * Only rows with verified_at set are ever routable, so unverified imports can't receive alerts.
 * Most specific area wins (LGA over state), then control_room > area_command > state_command.
 */
export class PgDirectory implements Directory {
  constructor(
    private readonly pool: Pool,
    private readonly fallbackCountry = 'NG',
  ) {}

  private static readonly SELECT = `cr.id, cr.name, cr.kind, cr.official_phone, cr.official_sms`;
  private static readonly RANK = `CASE cr.kind WHEN 'control_room' THEN 0 WHEN 'area_command' THEN 1 WHEN 'state_command' THEN 2 ELSE 3 END`;

  private static toRoom(r: Record<string, unknown>): ControlRoom {
    return {
      id: r.id as string,
      name: r.name as string,
      kind: r.kind as ControlRoom['kind'],
      officialPhone: (r.official_phone as string | null) ?? undefined,
      officialSms: (r.official_sms as string | null) ?? undefined,
    };
  }

  async resolve(geo?: GeoPoint): Promise<ControlRoom | null> {
    if (geo) {
      const r = await this.pool.query(
        `SELECT ${PgDirectory.SELECT}
           FROM control_rooms cr JOIN admin_areas a ON a.id = cr.admin_area_id
          WHERE cr.active AND cr.verified_at IS NOT NULL
            AND ST_Covers(a.boundary, ST_SetSRID(ST_MakePoint($1, $2), 4326)::geography)
          ORDER BY a.level DESC, ${PgDirectory.RANK}
          LIMIT 1`,
        [geo.lon, geo.lat],
      );
      if (r.rows[0]) return PgDirectory.toRoom(r.rows[0]);
    }
    // No area matched (or no location): fall back to the country's verified emergency line.
    const f = await this.pool.query(
      `SELECT ${PgDirectory.SELECT}
         FROM control_rooms cr JOIN admin_areas a ON a.id = cr.admin_area_id
        WHERE cr.active AND cr.verified_at IS NOT NULL AND cr.kind = 'emergency_line' AND a.country_code = $1
        LIMIT 1`,
      [this.fallbackCountry],
    );
    return f.rows[0] ? PgDirectory.toRoom(f.rows[0]) : null;
  }
}
