import type { Admin, AdminActions, AreaRow, DirectoryEdit, DirectoryRow, AdminRequest, AdminStore, Approval, RequestState, SosSummary } from './types.js';
import { NIGERIA_STATES } from './areas.js';
import type { MemorySosStore } from '../sos/memory-store.js';

export class MemoryAdminStore implements AdminStore {
  private admins = new Map<string, Admin>();
  private requests = new Map<string, AdminRequest>();
  private approvals: Approval[] = [];

  async createAdmin(a: Admin) { this.admins.set(a.id, { ...a }); }
  async getAdmin(id: string) { const a = this.admins.get(id); return a ? { ...a } : null; }
  async getAdminByEmail(email: string) { return [...this.admins.values()].find((a) => a.email === email) ?? null; }
  async listAdmins() { return [...this.admins.values()].map((a) => ({ ...a })); }
  async countActiveAdmins() { return [...this.admins.values()].filter((a) => !a.disabledAt).length; }

  async recordLoginFailure(id: string, now: number, max: number, lockMs: number) {
    const a = this.admins.get(id);
    if (!a) return;
    a.failedLogins += 1;
    if (a.failedLogins >= max) { a.lockedUntil = now + lockMs; a.failedLogins = 0; }
  }

  async recordLoginSuccess(id: string, step: number) {
    const a = this.admins.get(id);
    if (!a || step <= a.lastTotpStep) return false;
    a.lastTotpStep = step;
    a.failedLogins = 0;
    return true;
  }

  async disableAdmin(id: string, now: number) {
    const a = this.admins.get(id);
    if (!a || a.disabledAt) return false;
    a.disabledAt = now;
    return true;
  }

  async createRequest(r: AdminRequest) { this.requests.set(r.id, { ...r }); }
  async getRequest(id: string) { const r = this.requests.get(id); return r ? { ...r } : null; }
  async listRequests(states?: RequestState[]) {
    return [...this.requests.values()].filter((r) => !states || states.includes(r.state)).sort((a, b) => b.createdAt - a.createdAt).map((r) => ({ ...r }));
  }

  async transitionRequest(id: string, from: RequestState[], to: RequestState, patch: Partial<AdminRequest> = {}) {
    const r = this.requests.get(id);
    if (!r || !from.includes(r.state)) return null;
    Object.assign(r, patch, { state: to });
    return { ...r };
  }

  async addApproval(a: Approval) {
    const req = this.requests.get(a.requestId);
    if (req && req.requestedBy === a.adminId) throw new Error('an admin cannot answer their own request'); // mirrors the database trigger
    if (this.approvals.some((x) => x.requestId === a.requestId && x.adminId === a.adminId)) return false;
    this.approvals.push({ ...a });
    return true;
  }

  async getApprovals(requestId: string) { return this.approvals.filter((a) => a.requestId === requestId); }
}

/** Dev/test actions. The in-memory directory has no verify step, so that action reports "not found". */
export class MemoryAdminActions implements AdminActions {
  constructor(private readonly sos: MemorySosStore) {}
  private rooms = new Map<string, DirectoryRow>();
  private n = 0;
  async listAreas(): Promise<AreaRow[]> { return NIGERIA_STATES.map((name, i) => ({ id: i + 1, name, level: 1 })); }
  async listDirectory() { return [...this.rooms.values()].map((r) => ({ ...r })); }
  async verifyControlRoom(id: string, _by: string, at: number) {
    const r = this.rooms.get(id);
    if (!r) return false;
    r.verified = true; r.verifiedAt = at;
    return true;
  }
  async upsertControlRoom(e: DirectoryEdit, _at: number) {
    const area = NIGERIA_STATES[e.adminAreaId - 1];
    if (!area) return null;
    const old = e.controlRoomId ? this.rooms.get(e.controlRoomId) : undefined;
    if (e.controlRoomId && !old) return null;
    const id = old?.id ?? `00000000-0000-4000-9000-${String(++this.n).padStart(12, '0')}`;
    // Any edit drops verification, so a changed number must be re-checked before it can be used.
    this.rooms.set(id, { id, areaId: e.adminAreaId, area, name: e.name, kind: e.kind, officialPhone: e.officialPhone, officialSms: e.officialSms, source: e.source, verified: false, active: true });
    return id;
  }
  async retireControlRoom(id: string) {
    const r = this.rooms.get(id);
    if (!r) return false;
    r.active = false;
    return true;
  }
  async recentEvents(userId: string, sinceMs: number, limit: number): Promise<SosSummary[]> {
    return this.sos.eventsForUser(userId)
      .filter((e) => e.startedAt >= sinceMs)
      .sort((a, b) => b.startedAt - a.startedAt)
      .slice(0, limit)
      .map((e) => ({ id: e.id, state: e.state, trigger: e.trigger, startedAt: e.startedAt, endedAt: e.endedAt, lastGeo: e.lastGeo ? { lat: e.lastGeo.lat, lon: e.lastGeo.lon, at: e.lastGeo.at } : undefined }));
  }
}
