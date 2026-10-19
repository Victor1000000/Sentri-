import type { Contact, Logger, SosStore } from '../../domain/types.js';
import { noopLogger } from '../../domain/types.js';
import type { InboxStore } from '../inbox/types.js';
import { alertText } from '../inbox/texts.js';
import type { PushSender } from '../notify/contact-notifier.js';
import type { LocationShare, ShareGeo, ShareStore } from './types.js';

const HOUR = 3_600_000;

export type StartResult =
  | { ok: true; id: string; expiresAt: number; reached: number; unreachable: string[] }
  | { ok: false; error: 'no_contacts' | 'unknown_contact' | 'none_reachable' | 'too_many' };

export interface ShareView {
  id: string;
  startedAt: number;
  expiresAt: number;
  contactIds: string[];
}

/**
 * Live location sharing with chosen emergency contacts. It runs until the person stops it or the safety
 * limit passes. Each chosen contact is told when it starts and when it stops, inside the app only.
 * Only the latest position is stored, never a trail, and it is deleted with the rest after the retention window.
 */
export class ShareService {
  constructor(
    private readonly store: SosStore,
    private readonly inbox: InboxStore,
    private readonly shares: ShareStore,
    private readonly push: PushSender,
    private readonly o: {
      clock: () => number;
      newId: () => string;
      retentionMs: number;
      /** Safety limit so a forgotten share ends on its own. The person can extend it. */
      defaultMs?: number;
      maxMs?: number;
      log?: Logger;
    },
  ) {}
  private get log(): Logger {
    return this.o.log ?? noopLogger;
  }
  private get defaultMs() {
    return this.o.defaultMs ?? 8 * HOUR;
  }
  private get maxMs() {
    return this.o.maxMs ?? 24 * HOUR;
  }

  private async notify(kind: 'share_start' | 'share_stop', share: LocationShare, contact: Contact, rid: string): Promise<void> {
    const now = this.o.clock();
    const fromName = (await this.inbox.displayName(share.userId)) ?? undefined;
    const item = await this.inbox.upsert({
      id: this.o.newId(),
      userId: rid,
      fromUserId: share.userId,
      fromName,
      kind,
      sosId: null,
      shareId: share.id,
      locale: contact.locale,
      createdAt: now,
      updatedAt: now,
      purgeAfter: now + this.o.retentionMs,
    });
    const ok = await this.push
      .sendToUser(rid, { kind, text: alertText(kind, contact.locale, fromName), sosId: null, inboxId: item.id })
      .catch(() => false);
    if (!ok) this.log.warn({ kind }, 'share push not delivered; it is in the contact inbox');
  }

  /** Contacts of this user that can follow a share: they have the app and did not decline. */
  private async reachable(userId: string, only?: string[]): Promise<{ contact: Contact; rid: string }[]> {
    const out: { contact: Contact; rid: string }[] = [];
    for (const c of await this.store.getContacts(userId)) {
      if (only && !only.includes(c.id)) continue;
      if (c.consent === 'declined') continue;
      const rid = await this.inbox.recipientFor(c.id);
      if (rid) out.push({ contact: c, rid });
    }
    return out;
  }

  async start(userId: string, contactIds: string[], first?: ShareGeo, durationMs?: number): Promise<StartResult> {
    const ids = [...new Set(contactIds)];
    if (ids.length === 0) return { ok: false, error: 'no_contacts' };
    if (ids.length > 10) return { ok: false, error: 'too_many' };
    const mine = await this.store.getContacts(userId);
    if (!ids.every((id) => mine.some((c) => c.id === id))) return { ok: false, error: 'unknown_contact' };
    const chosen = await this.reachable(userId, ids);
    if (chosen.length === 0) return { ok: false, error: 'none_reachable' };
    const now = this.o.clock();
    const ms = Math.min(Math.max(durationMs ?? this.defaultMs, HOUR / 4), this.maxMs);
    const share: LocationShare = {
      id: this.o.newId(),
      userId,
      recipientIds: chosen.map((c) => c.rid),
      startedAt: now,
      expiresAt: now + ms,
      lastGeo: first,
      purgeAfter: now + ms + this.o.retentionMs,
    };
    await this.shares.create(share);
    for (const c of chosen) await this.notify('share_start', share, c.contact, c.rid);
    const reachedIds = new Set(chosen.map((c) => c.contact.id));
    return { ok: true, id: share.id, expiresAt: share.expiresAt, reached: chosen.length, unreachable: ids.filter((id) => !reachedIds.has(id)) };
  }

  async update(userId: string, id: string, geo: ShareGeo): Promise<boolean> {
    return this.shares.updateGeo(userId, id, geo, this.o.clock());
  }

  async extend(userId: string, id: string, addMs: number): Promise<number | null> {
    const s = await this.shares.get(id);
    const now = this.o.clock();
    if (!s || s.userId !== userId || s.endedAt !== undefined || s.expiresAt <= now) return null;
    const next = Math.min(s.expiresAt + addMs, now + this.maxMs);
    return (await this.shares.extend(userId, id, next, now)) ? next : null;
  }

  /** Stops the share and tells each contact. Safe to call twice: the second call changes nothing. */
  async stop(userId: string, id: string): Promise<boolean> {
    const s = await this.shares.end(userId, id, this.o.clock());
    if (!s) return false;
    await this.tellStopped(s);
    return true;
  }

  private async tellStopped(s: LocationShare): Promise<void> {
    for (const r of await this.reachable(s.userId)) {
      if (s.recipientIds.includes(r.rid)) await this.notify('share_stop', s, r.contact, r.rid);
    }
  }

  /** Ends shares that passed their limit. Run every minute. */
  async expireDue(): Promise<number> {
    const now = this.o.clock();
    let n = 0;
    for (const s of await this.shares.due(now)) {
      const ended = await this.shares.end(s.userId, s.id, now);
      if (ended) {
        await this.tellStopped(ended);
        n++;
      }
    }
    return n;
  }

  async active(userId: string): Promise<ShareView[]> {
    const mine = await this.store.getContacts(userId);
    const out: ShareView[] = [];
    for (const s of await this.shares.active(userId, this.o.clock())) {
      const contactIds: string[] = [];
      for (const c of mine) {
        const rid = await this.inbox.recipientFor(c.id);
        if (rid && s.recipientIds.includes(rid)) contactIds.push(c.id);
      }
      out.push({ id: s.id, startedAt: s.startedAt, expiresAt: s.expiresAt, contactIds });
    }
    return out;
  }
}
