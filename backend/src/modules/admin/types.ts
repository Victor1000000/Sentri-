export type RequestKind = 'directory_verify' | 'directory_upsert' | 'directory_retire' | 'data_access' | 'admin_add' | 'admin_remove';
export type RequestState = 'pending' | 'approved' | 'rejected' | 'executed' | 'expired';

export interface Admin {
  id: string;
  email: string;
  /** scrypt record, base64 */
  password: { salt: string; hash: string };
  /** AES-GCM encrypted base32 TOTP secret */
  totpEnc: Buffer;
  failedLogins: number;
  lockedUntil: number;
  /** Last TOTP step accepted. A code for this step or an older one is refused. */
  lastTotpStep: number;
  createdAt: number;
  disabledAt?: number;
}

export interface AdminRequest {
  id: string;
  kind: RequestKind;
  payload: Record<string, unknown>;
  reason: string;
  requestedBy: string;
  state: RequestState;
  createdAt: number;
  /** Pending and approved requests lapse at this time. */
  expiresAt: number;
  executedAt?: number;
  /** For data_access: reads are allowed until this time. */
  grantExpiresAt?: number;
}

export interface Approval {
  requestId: string;
  adminId: string;
  decision: 'approve' | 'reject';
  at: number;
}

/** Storage port. Memory and Postgres implementations. */
export interface AdminStore {
  createAdmin(a: Admin): Promise<void>;
  getAdmin(id: string): Promise<Admin | null>;
  getAdminByEmail(email: string): Promise<Admin | null>;
  countActiveAdmins(): Promise<number>;
  listAdmins(): Promise<Admin[]>;
  /** Atomically bumps the failure counter and locks the account when it reaches `max`. */
  recordLoginFailure(id: string, now: number, max: number, lockMs: number): Promise<void>;
  /** Clears failures and stores the accepted TOTP step, only if it is newer than the last one. Returns false if it is not. */
  recordLoginSuccess(id: string, step: number): Promise<boolean>;
  disableAdmin(id: string, now: number): Promise<boolean>;

  createRequest(r: AdminRequest): Promise<void>;
  getRequest(id: string): Promise<AdminRequest | null>;
  listRequests(states?: RequestState[]): Promise<AdminRequest[]>;
  /** Compare-and-set on state. */
  transitionRequest(id: string, from: RequestState[], to: RequestState, patch?: Partial<AdminRequest>): Promise<AdminRequest | null>;
  /** One answer per admin per request. Returns false if this admin already answered. */
  addApproval(a: Approval): Promise<boolean>;
  getApprovals(requestId: string): Promise<Approval[]>;
}

/** Actions an approved request can perform. Implemented outside this module. */
export interface AdminActions {
  /** Marks a police control-room entry as verified. */
  verifyControlRoom(controlRoomId: string, verifiedBy: string, at: number): Promise<boolean>;
  /**
   * Adds a control room, or edits one when `controlRoomId` is set. The result is always UNVERIFIED:
   * a new or changed entry cannot receive alerts until a separate directory_verify request is approved.
   * Returns the entry id, or null when the id or area does not exist.
   */
  upsertControlRoom(e: DirectoryEdit, at: number): Promise<string | null>;
  /** Stops routing to an entry (it is kept for the record). */
  retireControlRoom(controlRoomId: string): Promise<boolean>;
  listDirectory(): Promise<DirectoryRow[]>;
  listAreas(): Promise<AreaRow[]>;
  /** Recent SOS events for a user: the minimum needed for an investigation. */
  recentEvents(userId: string, sinceMs: number, limit: number): Promise<SosSummary[]>;
}

export interface SosSummary {
  id: string;
  state: string;
  trigger: string;
  startedAt: number;
  endedAt?: number;
  lastGeo?: { lat: number; lon: number; at: number };
}

export type ControlRoomKind = 'state_command' | 'area_command' | 'control_room' | 'emergency_line';

export interface DirectoryEdit {
  controlRoomId?: string;
  adminAreaId: number;
  name: string;
  kind: ControlRoomKind;
  officialPhone?: string;
  officialSms?: string;
  /** Where the number was confirmed (a URL, a letter reference, a call log). Required. */
  source: string;
}

export interface DirectoryRow {
  id: string;
  areaId: number;
  area: string;
  name: string;
  kind: ControlRoomKind;
  officialPhone?: string;
  officialSms?: string;
  source?: string;
  verified: boolean;
  verifiedAt?: number;
  active: boolean;
}

export interface AreaRow {
  id: number;
  name: string;
  level: number;
}

export interface AdminSummary {
  id: string;
  email: string;
  active: boolean;
}
