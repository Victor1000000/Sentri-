// Core domain types and the ports (interfaces) the SOS engine depends on.
// Adapters (Postgres, Redis/BullMQ, FCM, Termii) implement these; tests use in-memory ones.

export type Locale = 'en' | 'ha' | 'yo' | 'ig' | 'pcm';
export type SosState = 'countdown' | 'active' | 'acknowledged' | 'cancelled' | 'expired';
export type TriggerType = 'floating' | 'volume' | 'shake' | 'power' | 'widget';
export type MessageKind = 'sos' | 'duress' | 'offline' | 'low_battery' | 'test' | 'share_start' | 'share_stop';

export interface GeoPoint {
  lat: number;
  lon: number;
  accuracyM?: number;
  /** epoch ms when the fix was taken */
  at: number;
}

export interface User {
  id: string;
  phone: string; // E.164
  locale: Locale;
  /** What contacts see on an alert. Chosen by the user; never verified. */
  name?: string;
}

export interface Contact {
  id: string;
  userId: string;
  phone: string; // E.164
  locale: Locale;
  /** true when the contact has the app and a push token */
  hasApp: boolean;
  priority: number;
  /** Missing means pending. Declined contacts never receive alerts. */
  consent?: ConsentStatus;
}

export type ConsentStatus = 'pending' | 'accepted' | 'declined';

/** Implemented by the stores. Kept apart from SosStore so the SOS engine does not depend on it. */
export interface ConsentStore {
  /** Returns false when the contact no longer exists. */
  setConsent(contactId: string, status: ConsentStatus): Promise<boolean>;
}

export interface PinRecord {
  salt: string; // base64
  hash: string; // base64
}

export interface UserPins {
  cancel: PinRecord;
  duress: PinRecord;
}

export interface SosEvent {
  id: string;
  userId: string;
  state: SosState;
  /** Never exposed to the user's device in a way a coercer could see. */
  duress: boolean;
  trigger: TriggerType;
  startedAt: number;
  cancelWindowEndsAt: number;
  ackedAt?: number;
  ackedBy?: string;
  endedAt?: number;
  repeatCount: number;
  lastGeo?: GeoPoint;
  lastSeenAt: number;
  offlineNotified: boolean;
  dispatched: boolean;
  pinFailures: number;
  pinLockedUntil: number;
  purgeAfter: number;
}

export interface Link {
  /** sha256(token), hex. The raw token is never stored. */
  hash: string;
  kind: 'ack' | 'loc' | 'consent';
  /** SOS id, or `u:<userId>` for location links not tied to an SOS */
  subject: string;
  contactId: string;
  expiresAt: number;
}

export interface SosStore {
  /** Atomically create the event unless the user already has a countdown/active one. */
  createEventIfNoActive(e: SosEvent): Promise<{ created: boolean; event: SosEvent }>;
  getEvent(id: string): Promise<SosEvent | null>;
  /** The user's countdown/active SOS, if any (there is at most one). */
  getLiveEvent(userId: string): Promise<SosEvent | null>;
  updateEvent(id: string, patch: Partial<SosEvent>): Promise<SosEvent | null>;
  /** Compare-and-set on state. Returns the updated event, or null if the state did not match. */
  transition(id: string, from: SosState[], patch: Partial<SosEvent>): Promise<SosEvent | null>;
  getUser(id: string): Promise<User | null>;
  getContacts(userId: string): Promise<Contact[]>;
  getPins(userId: string): Promise<UserPins | null>;
  saveLink(l: Link): Promise<void>;
  getLink(hash: string): Promise<Link | null>;
}

export interface Scheduler {
  /**
   * `key` is `activate:<sosId>` or `repeat:<sosId>`. In-process schedulers run `fn`;
   * queue-backed ones (BullMQ) ignore it and dispatch by key, since closures can't be persisted.
   */
  schedule(key: string, delayMs: number, fn: () => Promise<void>): void | Promise<void>;
  cancel(key: string): void | Promise<void>;
}

export interface ContactMessage {
  kind: MessageKind;
  sosId: string | null;
  contact: Contact;
  /** Legacy link-based acknowledgement. Alerts are no longer sent as links; contacts respond inside the app. */
  ackUrl?: string;
  locationUrl?: string;
  /** Last known position, for kinds that are not tied to a live SOS (offline, low battery). */
  geo?: GeoPoint;
  /** 0 for the first send of an alert, then 1, 2, ... */
  repeat: number;
}

export interface Notifier {
  sendToContact(m: ContactMessage): Promise<void>;
  notifyUser(userId: string, n: { kind: 'acknowledged'; sosId: string }): Promise<void>;
  /**
   * The alert is over (a contact responded, or the person cancelled): tell every contact's phone to stop
   * ringing. Optional so simple notifiers need not implement it.
   */
  alertOver?(sosId: string, reason: 'responded' | 'cancelled'): Promise<void>;
}

export interface DispatchInfo {
  sosId: string;
  geo?: GeoPoint;
  duress: boolean;
  /** true when this follows an earlier dispatch for the same SOS */
  update: boolean;
  userPhone?: string;
  at: number;
}

export interface Dispatcher {
  dispatch(i: DispatchInfo): Promise<void>;
}

export interface AuditSink {
  /** Never put phone numbers or coordinates in audit entries. */
  append(actor: string, action: string, target?: string): Promise<void>;
}

export interface Logger {
  info(o: Record<string, unknown>, msg?: string): void;
  warn(o: Record<string, unknown>, msg?: string): void;
  error(o: Record<string, unknown>, msg?: string): void;
}

export const noopLogger: Logger = { info() {}, warn() {}, error() {} };
