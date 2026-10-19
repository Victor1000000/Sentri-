import { Queue, Worker } from 'bullmq';
import { Redis } from 'ioredis';
import type { Logger, Scheduler } from '../domain/types.js';
import { noopLogger } from '../domain/types.js';

export type JobHandler = (key: string) => Promise<void>;

/**
 * Redis/BullMQ scheduler. Alert jobs survive a restart of the API process.
 *
 * Why the sequence number: a repeat job schedules its own successor while it is still running,
 * and BullMQ rejects a second job with the same id. So every job gets a unique id and carries a
 * `seq`; Redis holds the current `seq` per key. Cancelling just deletes the Redis key, and a job
 * whose seq no longer matches is dropped when it fires. (The engine also re-checks SOS state.)
 */
export class BullScheduler implements Scheduler {
  private readonly queue: Queue;
  private worker?: Worker;

  constructor(
    private readonly redis: Redis,
    private readonly log: Logger = noopLogger,
    queueName = 'sentri-sos',
  ) {
    // BullMQ needs maxRetriesPerRequest=null on its connection; callers create `redis` accordingly.
    this.queue = new Queue(queueName, { connection: redis });
    this.queueName = queueName;
  }
  private readonly queueName: string;

  private seqKey = (key: string) => `sched:${key}`;

  async schedule(key: string, delayMs: number): Promise<void> {
    const seq = `${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
    await this.redis.set(this.seqKey(key), seq, 'EX', 7 * 24 * 3600);
    await this.queue.add(
      key,
      { key, seq },
      { delay: delayMs, attempts: 3, backoff: { type: 'exponential', delay: 1000 }, removeOnComplete: true, removeOnFail: 1000 },
    );
  }

  async cancel(key: string): Promise<void> {
    await this.redis.del(this.seqKey(key));
  }

  /** Starts processing jobs. `handler` maps `activate:<id>` -> engine.activate, `repeat:<id>` -> engine.tick. */
  start(handler: JobHandler, concurrency = 20): void {
    this.worker = new Worker(
      this.queueName,
      async (job) => {
        const { key, seq } = job.data as { key: string; seq: string };
        if ((await this.redis.get(this.seqKey(key))) !== seq) return; // cancelled or superseded
        await handler(key);
      },
      { connection: this.redis.duplicate({ maxRetriesPerRequest: null }), concurrency },
    );
    this.worker.on('failed', (job, err) => this.log.error({ key: job?.name, err: err.message }, 'sos job failed'));
  }

  async close(): Promise<void> {
    await this.worker?.close();
    await this.queue.close();
  }
}

export function createRedis(url: string): Redis {
  return new Redis(url, { maxRetriesPerRequest: null });
}

/** Maps a job key to an engine call. Unknown keys are ignored (and logged by the caller). */
export function engineJobHandler(engine: { activate(id: string): Promise<void>; tick(id: string): Promise<void> }): JobHandler {
  return async (key) => {
    const i = key.indexOf(':');
    const kind = key.slice(0, i);
    const id = key.slice(i + 1);
    if (kind === 'activate') return engine.activate(id);
    if (kind === 'repeat') return engine.tick(id);
    throw new Error(`unknown job kind: ${kind}`);
  };
}
