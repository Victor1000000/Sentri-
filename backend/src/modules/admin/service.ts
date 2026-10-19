import { randomBytes, randomUUID, scrypt, timingSafeEqual } from 'node:crypto';
import type { AuditSink } from '../../domain/types.js';
import type { FieldCrypto } from '../../lib/field-crypto.js';
import { signAccessToken, verifyAccessToken } from '../auth/jwt.js';
import { newTotpSecret, otpauthUri, verifyTotp } from './totp.js';
import type { Admin, AdminActions, AdminSummary, AreaRow, DirectoryEdit, DirectoryRow, AdminRequest, AdminStore, Approval, RequestKind, SosSummary } from './types.js';

/**
 * Two-person control. No admin can act alone on anything sensitive:
 *   - every sensitive action starts as a request with a written reason;
 *   - someone other than the requester must approve it (data access needs two other people);
 *   - any other admin can reject, and one rejection ends it;
 *   - approved requests expire after 24 hours, and data access grants last one hour;
 *   - every step is written to the tamper-evident audit log (who, what, never the data itself).
 */
export const APPROVALS_REQUIRED: Record<RequestKind, number> = {
  directory_verify: 1,
  directory_upsert: 1,
  directory_retire: 1,
  admin_add: 1,
  admin_remove: 1,
  data_access: 2,
};

export const REQUEST_TTL_MS = 24 * 3_600_000;
export const GRANT_TTL_MS = 3_600_000;
export const SESSION_TTL_SEC = 15 * 60;
const MAX_FAILED_LOGINS = 5;
const LOCK_MS = 15 * 60_000;
export const MIN_ACTIVE_ADMINS = 2;

export class AdminError extends Error {
  constructor(
    public readonly code:
      | 'invalid_credentials' | 'locked' | 'not_found' | 'forbidden' | 'conflict' | 'expired' | 'bad_request',
    message?: string,
  ) {
    super(message ?? code);
  }
}

function hashPassword(pw: string, salt: Buffer): Promise<Buffer> {
  return new Promise((res, rej) => scrypt(pw, salt, 32, { N: 32768, r: 8, p: 1, maxmem: 64 * 1024 * 1024 }, (e, k) => (e ? rej(e) : res(k))));
}

export async function makePassword(pw: string): Promise<{ salt: string; hash: string }> {
  const salt = randomBytes(16);
  return { salt: salt.toString('base64'), hash: (await hashPassword(pw, salt)).toString('base64') };
}

async function checkPassword(pw: string, rec: { salt: string; hash: string }): Promise<boolean> {
  const got = await hashPassword(pw, Buffer.from(rec.salt, 'base64'));
  const want = Buffer.from(rec.hash, 'base64');
  return got.length === want.length && timingSafeEqual(got, want);
}

/** A random password that is easy to type once and must be changed by policy. */
const newPassword = () => randomBytes(15).toString('base64url');

export interface Provisioned {
  adminId: string;
  email: string;
  password: string;
  totpSecret: string;
  otpauthUri: string;
}

export class AdminService {
  constructor(
    private readonly store: AdminStore,
    private readonly actions: AdminActions,
    private readonly audit: AuditSink,
    private readonly fc: FieldCrypto,
    private readonly jwtSecret: string,
    private readonly clock: () => number = Date.now,
    private readonly newId: () => string = randomUUID,
  ) {}

  // ---- accounts and sessions ----

  /** Creates an admin and returns the one-time credentials. Used by the bootstrap script and by approved admin_add requests. */
  async provision(email: string, actor: string): Promise<Provisioned> {
    const clean = email.trim().toLowerCase();
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(clean)) throw new AdminError('bad_request', 'invalid email');
    if (await this.store.getAdminByEmail(clean)) throw new AdminError('conflict', 'that admin already exists');
    const password = newPassword();
    const totp = newTotpSecret();
    const id = this.newId();
    await this.store.createAdmin({
      id,
      email: clean,
      password: await makePassword(password),
      totpEnc: this.fc.encrypt(totp),
      failedLogins: 0,
      lockedUntil: 0,
      lastTotpStep: 0,
      createdAt: this.clock(),
    });
    await this.audit.append(actor, 'admin.created', id);
    return { adminId: id, email: clean, password, totpSecret: totp, otpauthUri: otpauthUri(clean, totp) };
  }

  /** Same message for every failure, so the response never says whether the email exists. */
  async login(email: string, password: string, code: string): Promise<{ token: string; expiresIn: number }> {
    const now = this.clock();
    const admin = await this.store.getAdminByEmail(email.trim().toLowerCase());
    if (!admin || admin.disabledAt) {
      await checkPassword(password, { salt: Buffer.alloc(16).toString('base64'), hash: Buffer.alloc(32).toString('base64') }); // keep timing similar
      throw new AdminError('invalid_credentials');
    }
    if (admin.lockedUntil > now) throw new AdminError('locked', 'too many attempts, try again later');
    const pwOk = await checkPassword(password, admin.password);
    const step = verifyTotp(this.fc.decrypt(admin.totpEnc), code, now);
    if (!pwOk || step === null) {
      await this.store.recordLoginFailure(admin.id, now, MAX_FAILED_LOGINS, LOCK_MS);
      await this.audit.append(admin.id, 'admin.login_failed', admin.id);
      throw new AdminError('invalid_credentials');
    }
    if (!(await this.store.recordLoginSuccess(admin.id, step))) {
      await this.audit.append(admin.id, 'admin.login_replayed_code', admin.id);
      throw new AdminError('invalid_credentials'); // that code was already used
    }
    await this.audit.append(admin.id, 'admin.login', admin.id);
    return { token: signAccessToken({ sub: admin.id, did: 'admin' }, this.jwtSecret, SESSION_TTL_SEC, now), expiresIn: SESSION_TTL_SEC };
  }

  /** Returns the admin id for a valid, unexpired admin session whose account is still active. */
  async authenticate(token: string | undefined): Promise<Admin | null> {
    if (!token) return null;
    const c = verifyAccessToken(token, this.jwtSecret, this.clock());
    if (!c || c.did !== 'admin') return null;
    const a = await this.store.getAdmin(c.sub);
    return a && !a.disabledAt ? a : null;
  }

  // ---- requests ----

  async createRequest(actor: Admin, kind: RequestKind, payload: Record<string, unknown>, reason: string): Promise<AdminRequest> {
    const why = reason.trim();
    if (why.length < 10) throw new AdminError('bad_request', 'give a reason of at least 10 characters');
    if (kind === 'admin_remove') {
      const target = String(payload.adminId ?? '');
      if (target === actor.id) throw new AdminError('forbidden', 'you cannot remove yourself');
    }
    const now = this.clock();
    const r: AdminRequest = { id: this.newId(), kind, payload, reason: why, requestedBy: actor.id, state: 'pending', createdAt: now, expiresAt: now + REQUEST_TTL_MS };
    await this.store.createRequest(r);
    await this.audit.append(actor.id, `request.created.${kind}`, r.id);
    return r;
  }

  private async load(id: string): Promise<AdminRequest> {
    const r = await this.store.getRequest(id);
    if (!r) throw new AdminError('not_found');
    if ((r.state === 'pending' || r.state === 'approved') && r.expiresAt <= this.clock()) {
      await this.store.transitionRequest(id, ['pending', 'approved'], 'expired');
      throw new AdminError('expired');
    }
    return r;
  }

  async view(id: string): Promise<{ request: AdminRequest; approvals: Approval[] }> {
    return { request: await this.load(id), approvals: await this.store.getApprovals(id) };
  }

  async list(states?: AdminRequest['state'][]): Promise<AdminRequest[]> {
    return this.store.listRequests(states);
  }

  async decide(actor: Admin, id: string, decision: 'approve' | 'reject'): Promise<AdminRequest> {
    const r = await this.load(id);
    if (r.state !== 'pending') throw new AdminError('conflict', `request is ${r.state}`);
    if (r.requestedBy === actor.id) throw new AdminError('forbidden', 'you cannot answer your own request');
    const fresh = await this.store.addApproval({ requestId: id, adminId: actor.id, decision, at: this.clock() });
    if (!fresh) throw new AdminError('conflict', 'you already answered this request');
    await this.audit.append(actor.id, `request.${decision}.${r.kind}`, id);
    if (decision === 'reject') {
      return (await this.store.transitionRequest(id, ['pending'], 'rejected')) ?? (await this.load(id));
    }
    const approvals = (await this.store.getApprovals(id)).filter((a) => a.decision === 'approve');
    if (approvals.length >= APPROVALS_REQUIRED[r.kind]) {
      return (await this.store.transitionRequest(id, ['pending'], 'approved')) ?? (await this.load(id));
    }
    return r;
  }

  /** Carries out an approved request. Only the requester or another active admin may press the button, and only once. */
  async execute(actor: Admin, id: string): Promise<{ request: AdminRequest; provisioned?: Provisioned; note?: string }> {
    const r = await this.load(id);
    if (r.state !== 'approved') throw new AdminError('conflict', `request is ${r.state}, it needs approval first`);
    const now = this.clock();
    // Claim it first. If two admins press execute at once, only one gets past this line.
    const claimed = await this.store.transitionRequest(id, ['approved'], 'executed', {
      executedAt: now,
      ...(r.kind === 'data_access' ? { grantExpiresAt: now + GRANT_TTL_MS } : {}),
    });
    if (!claimed) throw new AdminError('conflict', 'already executed');
    await this.audit.append(actor.id, `request.executed.${r.kind}`, id);

    switch (r.kind) {
      case 'directory_verify': {
        const ok = await this.actions.verifyControlRoom(String(r.payload.controlRoomId), r.requestedBy, now);
        if (!ok) return { request: claimed, note: 'control room not found' };
        return { request: claimed };
      }
      case 'directory_upsert': {
        const p = r.payload as unknown as DirectoryEdit;
        const id = await this.actions.upsertControlRoom(p, now);
        if (!id) return { request: claimed, note: 'area or entry not found' };
        await this.audit.append(actor.id, 'directory.upserted', id);
        return { request: claimed, note: 'saved as UNVERIFIED. Request verification before it can receive alerts.' };
      }
      case 'directory_retire': {
        const ok = await this.actions.retireControlRoom(String(r.payload.controlRoomId));
        if (ok) await this.audit.append(actor.id, 'directory.retired', String(r.payload.controlRoomId));
        return { request: claimed, note: ok ? undefined : 'control room not found' };
      }
      case 'admin_add':
        return { request: claimed, provisioned: await this.provision(String(r.payload.email), actor.id) };
      case 'admin_remove': {
        if ((await this.store.countActiveAdmins()) <= MIN_ACTIVE_ADMINS) {
          return { request: claimed, note: `refused: at least ${MIN_ACTIVE_ADMINS} active admins must remain` };
        }
        const ok = await this.store.disableAdmin(String(r.payload.adminId), now);
        return { request: claimed, note: ok ? undefined : 'admin not found' };
      }
      case 'data_access':
        return { request: claimed, note: `access open for ${GRANT_TTL_MS / 60_000} minutes to the requester` };
    }
  }

  // ---- read-only helpers for the console ----

  directory(): Promise<DirectoryRow[]> { return this.actions.listDirectory(); }
  areas(): Promise<AreaRow[]> { return this.actions.listAreas(); }
  async admins(): Promise<AdminSummary[]> {
    return (await this.store.listAdmins()).map((a) => ({ id: a.id, email: a.email, active: !a.disabledAt }));
  }

  /** The break-glass read. Only the requester, only inside the grant window, and every read is logged. */
  async readEvents(actor: Admin, id: string): Promise<SosSummary[]> {
    const r = await this.load(id);
    if (r.kind !== 'data_access' || r.state !== 'executed') throw new AdminError('forbidden', 'no active grant');
    if (r.requestedBy !== actor.id) throw new AdminError('forbidden', 'the grant belongs to the requester');
    if (!r.grantExpiresAt || r.grantExpiresAt <= this.clock()) throw new AdminError('expired', 'the grant has ended');
    await this.audit.append(actor.id, 'data_access.read', id);
    const hours = Math.min(Math.max(Number(r.payload.sinceHours ?? 24), 1), 720);
    return this.actions.recentEvents(String(r.payload.userId), this.clock() - hours * 3_600_000, 50);
  }
}
