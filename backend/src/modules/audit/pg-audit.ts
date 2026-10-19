import type { Pool } from 'pg';
import type { AuditSink } from '../../domain/types.js';
import { chainHash } from './audit.js';

/** Postgres-backed hash-chained audit log. Appends are serialised so the chain stays linear. */
export class PgAudit implements AuditSink {
  constructor(
    private readonly pool: Pool,
    private readonly clock: () => number = Date.now,
  ) {}

  async append(actor: string, action: string, target?: string): Promise<void> {
    const c = await this.pool.connect();
    try {
      await c.query('BEGIN');
      await c.query('SELECT pg_advisory_xact_lock(7001)');
      const last = await c.query('SELECT entry_hash FROM audit_log ORDER BY id DESC LIMIT 1');
      const prev: string = last.rows[0]?.entry_hash ?? 'GENESIS';
      const at = this.clock();
      await c.query(
        'INSERT INTO audit_log (at, actor, action, target, prev_hash, entry_hash) VALUES ($1,$2,$3,$4,$5,$6)',
        [at, actor, action, target ?? null, prev, chainHash(prev, at, actor, action, target)],
      );
      await c.query('COMMIT');
    } catch (err) {
      await c.query('ROLLBACK');
      throw err;
    } finally {
      c.release();
    }
  }

  /** Recomputes the whole chain. Run it from a scheduled job and alert on false. */
  async verify(): Promise<boolean> {
    const r = await this.pool.query('SELECT at, actor, action, target, prev_hash, entry_hash FROM audit_log ORDER BY id');
    let prev = 'GENESIS';
    for (const e of r.rows) {
      if (e.prev_hash !== prev || e.entry_hash !== chainHash(prev, Number(e.at), e.actor, e.action, e.target ?? undefined)) {
        return false;
      }
      prev = e.entry_hash;
    }
    return true;
  }
}
