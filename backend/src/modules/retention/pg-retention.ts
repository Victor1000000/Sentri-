import type { Pool, PoolClient } from 'pg';
import type { RetentionTask, RunLock } from './retention.js';

const DAY = 86_400_000;

/** Arbitrary constant that identifies the retention job to pg_try_advisory_lock. */
const LOCK_KEY = 7_302_024;

/** Holds one dedicated connection while running, because advisory locks belong to a connection. */
export class PgAdvisoryLock implements RunLock {
  private client: PoolClient | undefined;
  constructor(private readonly pool: Pool) {}

  async tryAcquire(): Promise<boolean> {
    const c = await this.pool.connect();
    const r = await c.query('SELECT pg_try_advisory_lock($1) AS ok', [LOCK_KEY]);
    if (r.rows[0]?.ok === true) {
      this.client = c;
      return true;
    }
    c.release();
    return false;
  }

  async release(): Promise<void> {
    const c = this.client;
    this.client = undefined;
    if (!c) return;
    try {
      await c.query('SELECT pg_advisory_unlock($1)', [LOCK_KEY]);
    } finally {
      c.release();
    }
  }
}

/** The tasks that clean Postgres. Order matters: SOS events go before the users that own them. */
export function pgRetentionTasks(
  pool: Pool,
  purgeSos: (now: number) => Promise<number>,
  purgeInbox: (now: number) => Promise<number> = async () => 0,
  purgeShares: (now: number) => Promise<number> = async () => 0,
  opts: { deletedUserGraceMs?: number; revokedDeviceGraceMs?: number; otpGraceMs?: number } = {},
): RetentionTask[] {
  const userGrace = opts.deletedUserGraceMs ?? 30 * DAY;
  const deviceGrace = opts.revokedDeviceGraceMs ?? 30 * DAY;
  const otpGrace = opts.otpGraceMs ?? DAY;
  return [
    { name: 'sos_events', run: purgeSos },
    { name: 'inbox_items', run: purgeInbox },
    { name: 'location_shares', run: purgeShares },
    {
      name: 'otp_challenges',
      run: async (now) => (await pool.query('DELETE FROM otp_challenges WHERE expires_at < $1', [now - otpGrace])).rowCount ?? 0,
    },
    {
      name: 'devices',
      run: async (now) =>
        (await pool.query('DELETE FROM devices WHERE revoked_at IS NOT NULL AND revoked_at < $1', [now - deviceGrace])).rowCount ?? 0,
    },
    {
      // Contacts and devices go with the user (ON DELETE CASCADE). Users with SOS events still on
      // file are kept until those are purged, because sos_events.user_id has no cascade.
      name: 'deleted_users',
      run: async (now) =>
        (
          await pool.query(
            `DELETE FROM users u
              WHERE u.deleted_at IS NOT NULL AND u.deleted_at < $1
                AND NOT EXISTS (SELECT 1 FROM sos_events e WHERE e.user_id = u.id)`,
            [now - userGrace],
          )
        ).rowCount ?? 0,
    },
  ];
}
