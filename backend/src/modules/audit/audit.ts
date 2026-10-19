import { createHash } from 'node:crypto';
import type { AuditSink } from '../../domain/types.js';

export interface AuditEntry {
  at: number;
  actor: string;
  action: string;
  target?: string;
  prevHash: string;
  hash: string;
}

/** Shared by the in-memory and Postgres audit logs so both chains verify the same way. */
export function chainHash(prev: string, at: number, actor: string, action: string, target?: string): string {
  return createHash('sha256').update(`${prev}|${at}|${actor}|${action}|${target ?? ''}`).digest('hex');
}

/** Tamper-evident, hash-chained audit log, in memory (tests and dev). See PgAudit for the real one. */
export class HashChainAudit implements AuditSink {
  readonly entries: AuditEntry[] = [];

  constructor(private readonly clock: () => number = Date.now) {}

  async append(actor: string, action: string, target?: string): Promise<void> {
    const prevHash = this.entries.at(-1)?.hash ?? 'GENESIS';
    const at = this.clock();
    const hash = createHash('sha256')
      .update(`${prevHash}|${at}|${actor}|${action}|${target ?? ''}`)
      .digest('hex');
    this.entries.push({ at, actor, action, target, prevHash, hash });
  }

  /** Recomputes the chain; false means an entry was altered, removed, or reordered. */
  verify(): boolean {
    let prev = 'GENESIS';
    for (const e of this.entries) {
      const expect = createHash('sha256')
        .update(`${prev}|${e.at}|${e.actor}|${e.action}|${e.target ?? ''}`)
        .digest('hex');
      if (e.prevHash !== prev || e.hash !== expect) return false;
      prev = e.hash;
    }
    return true;
  }
}
