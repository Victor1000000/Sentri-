/**
 * Data retention. Sentri keeps as little as possible for as short a time as possible:
 *  - finished SOS events (with their last location) and response links: after RETENTION_HOURS
 *  - one-time-code challenges: one day after they expire
 *  - revoked devices: 30 days after revocation
 *  - accounts the user deleted: 30 days after deletion, once they have no SOS events left
 *
 * The runner is safe with several API replicas: a Postgres advisory lock lets one run at a time.
 * A failing task is logged and the others still run. Nothing here ever throws into the server.
 */
export interface RetentionTask {
  name: string;
  /** Deletes what is past its time and returns how many rows went. */
  run(now: number): Promise<number>;
}

/** Lets only one replica run the job at a time. The memory version always grants it. */
export interface RunLock {
  tryAcquire(): Promise<boolean>;
  release(): Promise<void>;
}

export const NoLock: RunLock = { tryAcquire: async () => true, release: async () => {} };

export interface RetentionLog {
  info(o: Record<string, unknown>, m?: string): void;
  error(o: Record<string, unknown>, m?: string): void;
}

export interface RetentionResult {
  ran: boolean;
  deleted: Record<string, number>;
  failed: string[];
}

export class RetentionJob {
  private timer: NodeJS.Timeout | undefined;
  constructor(
    private readonly tasks: RetentionTask[],
    private readonly lock: RunLock,
    private readonly clock: () => number,
    private readonly log: RetentionLog,
  ) {}

  async runOnce(): Promise<RetentionResult> {
    const result: RetentionResult = { ran: false, deleted: {}, failed: [] };
    let got = false;
    try {
      got = await this.lock.tryAcquire();
    } catch (e) {
      this.log.error({ err: String(e) }, 'retention lock failed');
      return result;
    }
    if (!got) return result; // another replica is on it
    try {
      result.ran = true;
      const now = this.clock();
      for (const t of this.tasks) {
        try {
          result.deleted[t.name] = await t.run(now);
        } catch (e) {
          result.failed.push(t.name);
          this.log.error({ task: t.name, err: String(e) }, 'retention task failed');
        }
      }
      this.log.info({ deleted: result.deleted, failed: result.failed }, 'retention run');
    } finally {
      await this.lock.release().catch(() => {});
    }
    return result;
  }

  start(everyMs = 3_600_000): void {
    if (this.timer) return;
    this.timer = setInterval(() => void this.runOnce(), everyMs);
    this.timer.unref();
    void this.runOnce();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
  }
}
