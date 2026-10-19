import type { Scheduler } from '../domain/types.js';

/** Single-process scheduler for development. Production uses a BullMQ adapter (step 1b) so jobs survive restarts. */
export class TimerScheduler implements Scheduler {
  private timers = new Map<string, NodeJS.Timeout>();

  constructor(private readonly onError: (e: unknown) => void) {}

  schedule(key: string, delayMs: number, fn: () => Promise<void>): void {
    this.cancel(key);
    const t = setTimeout(() => {
      this.timers.delete(key);
      fn().catch(this.onError);
    }, delayMs);
    this.timers.set(key, t);
  }

  cancel(key: string): void {
    const t = this.timers.get(key);
    if (t) clearTimeout(t);
    this.timers.delete(key);
  }
}
