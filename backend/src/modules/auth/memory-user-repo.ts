import { createHash, randomUUID } from 'node:crypto';
import type { Locale, UserPins } from '../../domain/types.js';
import type { MemorySosStore } from '../sos/memory-store.js';
import { LiveSosError } from './phone.js';
import type { ContactSummary, SavedContact, UserRepo } from './pg-user-repo.js';

/** In-memory UserRepo for tests and local dev. Mirrors PgUserRepo behaviour. */
export class MemoryUserRepo implements UserRepo {
  devices = new Map<string, { userId: string; refreshHash: string; pushToken?: string; revoked?: boolean }>();
  profiles = new Map<string, { locale?: Locale; dataSaver?: boolean }>();

  constructor(private readonly store: MemorySosStore) {}

  async findOrCreateUserByPhone(phone: string, locale: Locale): Promise<{ userId: string; isNew: boolean }> {
    const existing = this.store.findUserByPhone(phone);
    if (existing) return { userId: existing.id, isNew: false };
    const id = randomUUID();
    this.store.putUser({ id, phone, locale });
    return { userId: id, isNew: true };
  }

  async getPhone(userId: string): Promise<string | null> {
    return (await this.store.getUser(userId))?.phone ?? null;
  }

  async registerDevice(userId: string, _d: unknown, refreshHash: string): Promise<string> {
    const id = randomUUID();
    this.devices.set(id, { userId, refreshHash });
    return id;
  }

  async rotateRefresh(deviceId: string, oldHash: string, newHash: string): Promise<string | null> {
    const d = this.devices.get(deviceId);
    if (!d || d.revoked || d.refreshHash !== oldHash) return null;
    d.refreshHash = newHash;
    return d.userId;
  }

  async replaceContacts(userId: string, contacts: { phone: string; locale: Locale }[]): Promise<SavedContact[]> {
    if (this.store.hasLiveSos(userId)) throw new LiveSosError();
    const before = new Map(this.store.allContacts(userId).map((c) => [c.id, c]));
    const saved = contacts.map((c, i) => {
      const id = createHash('sha256').update(`${userId}|${c.phone}`).digest('hex').slice(0, 32);
      const old = before.get(id);
      return {
        contact: {
          id,
          userId,
          phone: c.phone,
          locale: c.locale,
          hasApp: this.store.hasUserPhone(c.phone),
          priority: i,
          consent: old?.consent ?? ('pending' as const),
        },
        isNew: !old,
      };
    });
    this.store.setContacts(userId, saved.map((s) => s.contact));
    return saved.map((s) => ({ id: s.contact.id, phone: s.contact.phone, locale: s.contact.locale, isNew: s.isNew }));
  }

  async listContacts(userId: string): Promise<ContactSummary[]> {
    return this.store.allContacts(userId).map((c) => ({ id: c.id, phone: c.phone, locale: c.locale, consent: c.consent ?? 'pending', reachable: this.store.hasUserPhone(c.phone) }));
  }

  async setPins(userId: string, pins: UserPins): Promise<void> {
    this.store.setPins(userId, pins);
  }

  async updateProfile(userId: string, p: { locale?: Locale; dataSaver?: boolean; name?: string }): Promise<void> {
    if (p.name) this.store.setUserName(userId, p.name);
    this.profiles.set(userId, { ...this.profiles.get(userId), ...p });
  }

  async setPushToken(userId: string, deviceId: string, token: string): Promise<void> {
    const d = this.devices.get(deviceId);
    if (d && d.userId === userId) d.pushToken = token;
  }
}
