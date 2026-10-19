import type { MemorySosStore } from '../sos/memory-store.js';
import type { InboxItem, InboxStore, Invite } from './types.js';

/** In-memory inbox for tests and local development. Mirrors PgInbox. */
export class MemoryInbox implements InboxStore {
  private items: InboxItem[] = [];
  constructor(private readonly sos: MemorySosStore) {}

  private contactById(contactId: string) {
    for (const list of this.sos.allContactLists()) {
      const c = list.find((x) => x.id === contactId);
      if (c) return c;
    }
    return undefined;
  }

  async forSos(sosId: string) {
    return this.items.filter((i) => i.sosId === sosId && (i.kind === 'sos' || i.kind === 'duress' || i.kind === 'offline')).map((i) => ({ userId: i.userId, itemId: i.id }));
  }
  async recipientFor(contactId: string) {
    const c = this.contactById(contactId);
    return c ? (this.sos.findUserByPhone(c.phone)?.id ?? null) : null;
  }
  async contactIdFor(fromUserId: string, recipientUserId: string) {
    const phone = (await this.sos.getUser(recipientUserId))?.phone;
    return this.sos.allContacts(fromUserId).find((c) => c.phone === phone)?.id ?? null;
  }
  async displayName(userId: string) {
    return (await this.sos.getUser(userId))?.name ?? null;
  }
  async phoneOf(userId: string) {
    return (await this.sos.getUser(userId))?.phone ?? null;
  }

  async upsert(i: InboxItem): Promise<InboxItem> {
    const old = i.sosId
      ? this.items.find((x) => x.userId === i.userId && x.sosId === i.sosId && x.kind === i.kind)
      : i.shareId
        ? this.items.find((x) => x.userId === i.userId && x.shareId === i.shareId && x.kind === i.kind)
        : undefined;
    if (old) {
      old.updatedAt = i.updatedAt;
      old.geo = i.geo ?? old.geo;
      old.fromName = i.fromName ?? old.fromName;
      return { ...old };
    }
    this.items.push({ ...i });
    return { ...i };
  }
  async list(userId: string, limit: number) {
    return this.items
      .filter((x) => x.userId === userId)
      .sort((a, b) => b.updatedAt - a.updatedAt)
      .slice(0, limit)
      .map((x) => ({ ...x }));
  }
  async get(userId: string, id: string) {
    const x = this.items.find((i) => i.id === id && i.userId === userId);
    return x ? { ...x } : null;
  }
  async markRead(userId: string, id: string, at: number) {
    const x = this.items.find((i) => i.id === id && i.userId === userId);
    if (!x) return false;
    x.readAt ??= at;
    return true;
  }

  async invitesFor(userId: string): Promise<Invite[]> {
    const me = (await this.sos.getUser(userId))?.phone;
    if (!me) return [];
    const out: Invite[] = [];
    for (const [owner, list] of this.sos.contactListEntries()) {
      for (const c of list) {
        if (c.phone === me && (c.consent ?? 'pending') === 'pending') {
          out.push({ contactId: c.id, fromUserId: owner, fromName: (await this.sos.getUser(owner))?.name });
        }
      }
    }
    return out;
  }
  async decideInvite(userId: string, contactId: string, status: 'accepted' | 'declined') {
    const me = (await this.sos.getUser(userId))?.phone;
    const c = this.contactById(contactId);
    if (!me || !c || c.phone !== me) return false;
    return this.sos.setConsent(contactId, status);
  }
  async purge(now: number) {
    const before = this.items.length;
    this.items = this.items.filter((x) => x.purgeAfter >= now);
    return before - this.items.length;
  }
}
