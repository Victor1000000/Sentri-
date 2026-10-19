import type {
  ConsentStatus,
  ConsentStore,
  Contact,
  Link,
  SosEvent,
  SosState,
  SosStore,
  User,
  UserPins,
} from '../../domain/types.js';

/** In-memory store for tests and local development. Postgres implementation follows in step 1b. */
export class MemorySosStore implements SosStore, ConsentStore {
  private events = new Map<string, SosEvent>();
  private users = new Map<string, User>();
  private contacts = new Map<string, Contact[]>();
  private pins = new Map<string, UserPins>();
  private links = new Map<string, Link>();

  // --- seeding helpers (not part of the SosStore port) ---
  addUser(u: User, pins: UserPins, contacts: Contact[]): void {
    this.users.set(u.id, u);
    this.pins.set(u.id, pins);
    this.contacts.set(u.id, contacts);
  }

  /** Used by MemoryUserRepo (onboarding in dev/tests). */
  putUser(u: User): void {
    this.users.set(u.id, u);
  }
  setContacts(userId: string, contacts: Contact[]): void {
    this.contacts.set(userId, contacts);
  }
  setPins(userId: string, pins: UserPins): void {
    this.pins.set(userId, pins);
  }
  setUserName(userId: string, name: string): void {
    const u = this.users.get(userId);
    if (u) u.name = name;
  }
  allContactLists(): Contact[][] {
    return [...this.contacts.values()];
  }
  contactListEntries(): [string, Contact[]][] {
    return [...this.contacts.entries()];
  }
  findUserByPhone(phone: string): User | undefined {
    return [...this.users.values()].find((u) => u.phone === phone);
  }
  hasLiveSos(userId: string): boolean {
    return [...this.events.values()].some((e) => e.userId === userId && (e.state === 'countdown' || e.state === 'active'));
  }
  hasUserPhone(phone: string): boolean {
    return !!this.findUserByPhone(phone);
  }

  async createEventIfNoActive(e: SosEvent): Promise<{ created: boolean; event: SosEvent }> {
    for (const ev of this.events.values()) {
      if (ev.userId === e.userId && (ev.state === 'countdown' || ev.state === 'active')) {
        return { created: false, event: structuredClone(ev) };
      }
    }
    this.events.set(e.id, structuredClone(e));
    return { created: true, event: structuredClone(e) };
  }

  async getEvent(id: string): Promise<SosEvent | null> {
    const e = this.events.get(id);
    return e ? structuredClone(e) : null;
  }

  async getLiveEvent(userId: string): Promise<SosEvent | null> {
    for (const e of this.events.values()) {
      if (e.userId === userId && (e.state === 'countdown' || e.state === 'active')) return structuredClone(e);
    }
    return null;
  }

  async updateEvent(id: string, patch: Partial<SosEvent>): Promise<SosEvent | null> {
    const e = this.events.get(id);
    if (!e) return null;
    Object.assign(e, patch);
    return structuredClone(e);
  }

  async transition(id: string, from: SosState[], patch: Partial<SosEvent>): Promise<SosEvent | null> {
    const e = this.events.get(id);
    if (!e || !from.includes(e.state)) return null;
    Object.assign(e, patch);
    return structuredClone(e);
  }

  async getUser(id: string): Promise<User | null> {
    return this.users.get(id) ?? null;
  }

  async getContacts(userId: string): Promise<Contact[]> {
    return [...(this.contacts.get(userId) ?? [])]
      .filter((c) => c.consent !== 'declined')
      .sort((a, b) => a.priority - b.priority)
      .map((c) => ({ ...c, hasApp: c.hasApp || this.hasUserPhone(c.phone) })); // a contact who installs later becomes reachable
  }

  /** Used by MemoryUserRepo to keep earlier answers when the list is re-saved. */
  allContacts(userId: string): Contact[] {
    return this.contacts.get(userId) ?? [];
  }

  /** Used by the admin break-glass read in dev and tests. */
  eventsForUser(userId: string): SosEvent[] {
    return [...this.events.values()].filter((e) => e.userId === userId);
  }

  async setConsent(contactId: string, status: ConsentStatus): Promise<boolean> {
    for (const list of this.contacts.values()) {
      const c = list.find((x) => x.id === contactId);
      if (c) {
        c.consent = status;
        return true;
      }
    }
    return false;
  }

  async getPins(userId: string): Promise<UserPins | null> {
    return this.pins.get(userId) ?? null;
  }

  async saveLink(l: Link): Promise<void> {
    this.links.set(l.hash, l);
  }

  async getLink(hash: string): Promise<Link | null> {
    return this.links.get(hash) ?? null;
  }
}
