import type { LocationShare, ShareGeo, ShareStore } from './types.js';

export class MemoryShares implements ShareStore {
  private rows = new Map<string, LocationShare>();
  async create(s: LocationShare) {
    this.rows.set(s.id, structuredClone(s));
  }
  async get(id: string) {
    const r = this.rows.get(id);
    return r ? structuredClone(r) : null;
  }
  async active(userId: string, now: number) {
    return [...this.rows.values()].filter((s) => s.userId === userId && s.endedAt === undefined && s.expiresAt > now).map((s) => structuredClone(s));
  }
  async updateGeo(userId: string, id: string, geo: ShareGeo, now: number) {
    const s = this.rows.get(id);
    if (!s || s.userId !== userId || s.endedAt !== undefined || s.expiresAt <= now) return false;
    s.lastGeo = geo;
    return true;
  }
  async end(userId: string, id: string, at: number) {
    const s = this.rows.get(id);
    if (!s || s.userId !== userId || s.endedAt !== undefined) return null;
    s.endedAt = at;
    return structuredClone(s);
  }
  async extend(userId: string, id: string, expiresAt: number, now: number) {
    const s = this.rows.get(id);
    if (!s || s.userId !== userId || s.endedAt !== undefined || s.expiresAt <= now) return false;
    s.expiresAt = expiresAt;
    return true;
  }
  async due(now: number) {
    return [...this.rows.values()].filter((s) => s.endedAt === undefined && s.expiresAt <= now).map((s) => structuredClone(s));
  }
  async purge(now: number) {
    let n = 0;
    for (const [id, s] of this.rows) if (s.purgeAfter < now) { this.rows.delete(id); n++; }
    return n;
  }
}
