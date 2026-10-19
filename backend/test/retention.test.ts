import { describe, expect, it } from 'vitest';
import { NoLock, RetentionJob, type RetentionTask, type RunLock } from '../src/modules/retention/retention.js';

const quiet = { info: () => {}, error: () => {} };

describe('RetentionJob', () => {
  it('runs every task with the current time and reports counts', async () => {
    const seen: number[] = [];
    const tasks: RetentionTask[] = [
      { name: 'a', run: async (n) => (seen.push(n), 3) },
      { name: 'b', run: async () => 0 },
    ];
    const r = await new RetentionJob(tasks, NoLock, () => 1234, quiet).runOnce();
    expect(r).toEqual({ ran: true, deleted: { a: 3, b: 0 }, failed: [] });
    expect(seen).toEqual([1234]);
  });

  it('keeps going when one task fails, and says which', async () => {
    const tasks: RetentionTask[] = [
      { name: 'bad', run: async () => { throw new Error('db down'); } },
      { name: 'good', run: async () => 5 },
    ];
    const r = await new RetentionJob(tasks, NoLock, () => 1, quiet).runOnce();
    expect(r.failed).toEqual(['bad']);
    expect(r.deleted).toEqual({ good: 5 });
  });

  it('does nothing when another replica holds the lock', async () => {
    let ran = false;
    const held: RunLock = { tryAcquire: async () => false, release: async () => { throw new Error('should not release'); } };
    const r = await new RetentionJob([{ name: 'a', run: async () => ((ran = true), 1) }], held, () => 1, quiet).runOnce();
    expect(r.ran).toBe(false);
    expect(ran).toBe(false);
  });

  it('always releases the lock, even if tasks fail', async () => {
    let released = 0;
    const lock: RunLock = { tryAcquire: async () => true, release: async () => void released++ };
    await new RetentionJob([{ name: 'x', run: async () => { throw new Error('x'); } }], lock, () => 1, quiet).runOnce();
    expect(released).toBe(1);
  });

  it('survives a broken lock', async () => {
    const lock: RunLock = { tryAcquire: async () => { throw new Error('conn'); }, release: async () => {} };
    const r = await new RetentionJob([], lock, () => 1, quiet).runOnce();
    expect(r.ran).toBe(false);
  });
});
