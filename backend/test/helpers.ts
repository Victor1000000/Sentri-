import type {
  ContactMessage,
  DispatchInfo,
  Dispatcher,
  Notifier,
  Scheduler,
} from '../src/domain/types.js';
import { FixedWindowLimiter } from '../src/lib/rate-limit.js';
import { createPinPair } from '../src/lib/pin.js';
import { HashChainAudit } from '../src/modules/audit/audit.js';
import { SosEngine, type EngineConfig } from '../src/modules/sos/engine.js';
import { MemorySosStore } from '../src/modules/sos/memory-store.js';

export const PEPPER = Buffer.from('p'.repeat(32));
export const GEO = { lat: 6.5244, lon: 3.3792, accuracyM: 12, at: 0 };

export class FakeClock {
  now = 1_700_000_000_000;
  fn = () => this.now;
}

/** Deterministic scheduler: jobs only run when the test advances time. */
export class FakeScheduler implements Scheduler {
  private jobs = new Map<string, { at: number; fn: () => Promise<void> }>();
  constructor(private readonly clock: FakeClock) {}

  schedule(key: string, delayMs: number, fn: () => Promise<void>): void {
    this.jobs.set(key, { at: this.clock.now + delayMs, fn });
  }
  cancel(key: string): void {
    this.jobs.delete(key);
  }
  pending(): string[] {
    return [...this.jobs.keys()];
  }
  async advance(ms: number): Promise<void> {
    const target = this.clock.now + ms;
    for (;;) {
      let nextKey: string | undefined;
      let nextAt = Infinity;
      for (const [k, j] of this.jobs) {
        if (j.at <= target && j.at < nextAt) {
          nextKey = k;
          nextAt = j.at;
        }
      }
      if (nextKey === undefined) break;
      const job = this.jobs.get(nextKey)!;
      this.jobs.delete(nextKey);
      this.clock.now = Math.max(this.clock.now, job.at);
      await job.fn();
    }
    this.clock.now = target;
  }
}

export class RecordingNotifier implements Notifier {
  messages: ContactMessage[] = [];
  userNotices: { userId: string; sosId: string }[] = [];
  async sendToContact(m: ContactMessage): Promise<void> {
    this.messages.push(m);
  }
  async notifyUser(userId: string, n: { kind: 'acknowledged'; sosId: string }): Promise<void> {
    this.userNotices.push({ userId, sosId: n.sosId });
  }
  ofKind(kind: string): ContactMessage[] {
    return this.messages.filter((m) => m.kind === kind);
  }
}

export class RecordingDispatcher implements Dispatcher {
  calls: DispatchInfo[] = [];
  async dispatch(i: DispatchInfo): Promise<void> {
    this.calls.push(i);
  }
}

export async function harness(over: Partial<EngineConfig> = {}) {
  const clock = new FakeClock();
  const sched = new FakeScheduler(clock);
  const store = new MemorySosStore();
  const notifier = new RecordingNotifier();
  const dispatcher = new RecordingDispatcher();
  const audit = new HashChainAudit(clock.fn);
  const pins = await createPinPair('1234', '4321', PEPPER);
  store.addUser({ id: 'u1', phone: '+2348000000000', locale: 'en' }, pins, [
    { id: 'c1', userId: 'u1', phone: '+2348000000001', locale: 'en', hasApp: false, priority: 0 },
    { id: 'c2', userId: 'u1', phone: '+2348000000002', locale: 'pcm', hasApp: false, priority: 1 },
    { id: 'c3', userId: 'u1', phone: '+2348000000003', locale: 'ha', hasApp: false, priority: 2 },
  ]);
  let n = 0;
  const engine = new SosEngine({
    store,
    scheduler: sched,
    notifier,
    dispatcher,
    audit,
    lowBatteryLimiter: new FixedWindowLimiter(1, 30 * 60_000, clock.fn),
    clock: clock.fn,
    newId: () => `sos-${++n}`,
    cfg: {
      cancelWindowMs: 5000,
      repeatMs: 25000,
      maxRepeats: 240,
      offlineAfterMs: 90000,
      pinMaxAttempts: 5,
      pinLockoutMs: 300000,
      retentionMs: 72 * 3_600_000,
      baseUrl: 'https://sentri.example',
      tokenSecret: 't'.repeat(32),
      pinPepper: PEPPER,
      ...over,
    },
  });
  return { engine, store, clock, sched, notifier, dispatcher, audit };
}

/** Pulls the raw ack token out of an ack URL. */
export const tokenOf = (url: string | undefined): string => url!.split('/').pop()!;
