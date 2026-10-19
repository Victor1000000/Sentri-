export class FixedWindowLimiter {
  private hits = new Map<string, { count: number; resetAt: number }>();
  private nextSweepAt = 0;

  constructor(
    private readonly max: number,
    private readonly windowMs: number,
    private readonly clock: () => number = Date.now,
    /** Hard cap on tracked keys, so a flood of different keys cannot use up the server's memory. */
    private readonly maxKeys = 50_000,
  ) {}

  /** Returns true if the call is allowed. In-memory only; swap for Redis when running >1 instance. */
  allow(key: string): boolean {
    const now = this.clock();
    this.sweep(now);
    const h = this.hits.get(key);
    if (!h || now >= h.resetAt) {
      // A full table with no expired keys means a flood: refuse new keys rather than grow.
      if (!h && this.hits.size >= this.maxKeys) return false;
      this.hits.set(key, { count: 1, resetAt: now + this.windowMs });
      return true;
    }
    if (h.count >= this.max) return false;
    h.count += 1;
    return true;
  }

  /** Number of keys currently tracked (for tests and monitoring). */
  size(): number {
    return this.hits.size;
  }

  /** Drops expired windows at most once per window, or sooner when the table is nearly full. */
  private sweep(now: number): void {
    if (now < this.nextSweepAt && this.hits.size < this.maxKeys) return;
    for (const [k, h] of this.hits) if (now >= h.resetAt) this.hits.delete(k);
    this.nextSweepAt = now + Math.min(this.windowMs, 60_000);
  }
}
