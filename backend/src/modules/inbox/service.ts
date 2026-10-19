import type { Contact, GeoPoint, Logger, Locale, SosStore } from '../../domain/types.js';
import { noopLogger } from '../../domain/types.js';
import type { FixedWindowLimiter } from '../../lib/rate-limit.js';
import type { SosEngine } from '../sos/engine.js';
import type { PushSender } from '../notify/contact-notifier.js';
import { alertText } from './texts.js';
import type { ShareStore } from '../share/types.js';
import type { InboxItem, InboxKind, InboxStore, Invite } from './types.js';

export type DeliverResult = 'delivered' | 'push_failed' | 'no_app';

export interface InboxEntry {
  id: string;
  kind: InboxKind;
  from: string | null;
  text: string;
  at: number;
  read: boolean;
  /** The alert is still running and can be answered. */
  live: boolean;
  /** active: nobody has answered; responding: a contact has; ended: over. */
  state: 'active' | 'responding' | 'ended';
}

export interface InboxDetail extends InboxEntry {
  state: 'active' | 'responding' | 'ended';
  geo: { lat: number; lon: number; at: number } | null;
  /** Not offered for a duress alert: the person may be under watch, and a call could put them at risk. */
  callPhone: string | null;
  canRespond: boolean;
}

export type RespondResult = 'ok' | 'already_responding' | 'ended' | 'not_found' | 'not_allowed';

/**
 * Alerts reach emergency contacts only inside the app: a stored inbox item plus a high-priority push.
 * Sentri never texts a contact an alert or a link, so a text that claims to be a Sentri alert is fake.
 * A contact who has not installed the app cannot be alerted, and the sender is told so (see `reachable`).
 */
export class InboxService {
  constructor(
    private readonly store: SosStore,
    private readonly inbox: InboxStore,
    private readonly push: PushSender,
    private readonly engine: SosEngine,
    private readonly o: {
      retentionMs: number;
      clock: () => number;
      newId: () => string;
      testLimiter?: FixedWindowLimiter;
      shares?: ShareStore;
      log?: Logger;
    },
  ) {}
  private get log(): Logger {
    return this.o.log ?? noopLogger;
  }

  // ------------------------------------------------------------ sending

  /** Stores the alert for the contact and pushes it to their devices. Never throws on a missing app. */
  async deliver(m: { kind: InboxKind; sosId: string | null; contact: Contact; geo?: GeoPoint }): Promise<DeliverResult> {
    const rid = await this.inbox.recipientFor(m.contact.id);
    if (!rid) return 'no_app';
    const now = this.o.clock();
    const fromName = (await this.inbox.displayName(m.contact.userId)) ?? undefined;
    const item = await this.inbox.upsert({
      id: this.o.newId(),
      userId: rid,
      fromUserId: m.contact.userId,
      fromName,
      kind: m.kind,
      sosId: m.sosId,
      locale: m.contact.locale,
      geo: m.geo ? { lat: m.geo.lat, lon: m.geo.lon, at: m.geo.at } : undefined,
      createdAt: now,
      updatedAt: now,
      purgeAfter: now + this.o.retentionMs,
    });
    const text = alertText(m.kind, m.contact.locale, fromName);
    const ok = await this.push.sendToUser(rid, { kind: m.kind, text, sosId: m.sosId, inboxId: item.id }).catch(() => false);
    if (!ok) this.log.warn({ kind: m.kind }, 'push not delivered; the alert is in the contact inbox');
    return ok ? 'delivered' : 'push_failed';
  }

  /**
   * Tells every contact's phone to stop ringing: someone responded, or the person cancelled.
   * Uses the same collapse key as the alert, so a phone that was offline gets only this and never rings at all.
   */
  async alertOver(sosId: string, reason: 'responded' | 'cancelled'): Promise<void> {
    for (const r of await this.inbox.forSos(sosId)) {
      await this.push.sendToUser(r.userId, { kind: 'clear', text: reason, sosId, inboxId: r.itemId }).catch(() => false);
    }
  }

  /** "Send a test alert": lets contacts see what a real one looks like and check their phone rings. */
  async sendTest(userId: string): Promise<{ sent: number; reachable: number; total: number } | 'rate_limited'> {
    if (this.o.testLimiter && !this.o.testLimiter.allow(`test:${userId}`)) return 'rate_limited';
    const contacts = await this.store.getContacts(userId);
    let sent = 0;
    let reachable = 0;
    for (const c of contacts) {
      const r = await this.deliver({ kind: 'test', sosId: null, contact: c });
      if (r !== 'no_app') reachable++;
      if (r === 'delivered') sent++;
    }
    return { sent, reachable, total: contacts.length };
  }

  // ------------------------------------------------------------ reading

  private async live(i: InboxItem): Promise<'active' | 'responding' | 'ended'> {
    if (i.kind === 'share_start' && i.shareId && this.o.shares) {
      const sh = await this.o.shares.get(i.shareId);
      return sh && sh.endedAt === undefined && sh.expiresAt > this.o.clock() ? 'active' : 'ended';
    }
    if (!i.sosId) return 'ended';
    const v = await this.engine.alertView(i.sosId);
    if (v === 'invalid' || v === 'ended') return 'ended';
    return v.responding ? 'responding' : 'active';
  }

  private entry(i: InboxItem, state: 'active' | 'responding' | 'ended'): InboxEntry {
    return {
      id: i.id,
      kind: i.kind,
      from: i.fromName ?? null,
      text: alertText(i.kind, i.locale, i.fromName),
      at: i.updatedAt,
      read: i.readAt !== undefined,
      live: state !== 'ended',
      state,
    };
  }

  async list(userId: string): Promise<{ unread: number; items: InboxEntry[]; invites: Invite[] }> {
    const rows = await this.inbox.list(userId, 40);
    const items: InboxEntry[] = [];
    for (const r of rows) items.push(this.entry(r, await this.live(r)));
    return { unread: items.filter((i) => !i.read).length, items, invites: await this.inbox.invitesFor(userId) };
  }

  async open(userId: string, id: string): Promise<InboxDetail | null> {
    const i = await this.inbox.get(userId, id);
    if (!i) return null;
    await this.inbox.markRead(userId, id, this.o.clock());
    const state = await this.live(i);
    let geo = i.geo ?? null;
    if (i.sosId && state !== 'ended') {
      const v = await this.engine.alertView(i.sosId);
      if (v !== 'invalid' && v !== 'ended' && v.geo) geo = v.geo;
    }
    if (i.kind === 'share_start' && i.shareId && state !== 'ended' && this.o.shares) {
      const g = (await this.o.shares.get(i.shareId))?.lastGeo;
      if (g) geo = { lat: g.lat, lon: g.lon, at: g.at };
    }
    const callPhone = i.kind === 'share_stop' ? null : i.kind === 'duress' ? null : await this.inbox.phoneOf(i.fromUserId);
    return {
      ...this.entry({ ...i, readAt: i.readAt ?? this.o.clock() }, state),
      state,
      geo,
      callPhone,
      canRespond: state === 'active' && (i.kind === 'sos' || i.kind === 'duress' || i.kind === 'offline'),
    };
  }

  // ----------------------------------------------------------- answering

  async respond(userId: string, id: string): Promise<RespondResult> {
    const i = await this.inbox.get(userId, id);
    if (!i) return 'not_found';
    if (i.kind === 'low_battery' || i.kind === 'test' || i.kind === 'share_start' || i.kind === 'share_stop' || !i.sosId) return 'not_allowed';
    const contactId = await this.inbox.contactIdFor(i.fromUserId, userId);
    if (!contactId) return 'not_allowed';
    const r = await this.engine.acknowledgeInApp(i.sosId, contactId);
    if (r === 'ok') return 'ok';
    if (r === 'already_acknowledged') return 'already_responding';
    return r === 'ended' ? 'ended' : 'not_found';
  }

  async markRead(userId: string, id: string): Promise<boolean> {
    return this.inbox.markRead(userId, id, this.o.clock());
  }

  // ---------------------------------------------------------- invitations

  async decideInvite(userId: string, contactId: string, decision: 'accept' | 'decline'): Promise<boolean> {
    return this.inbox.decideInvite(userId, contactId, decision === 'accept' ? 'accepted' : 'declined');
  }
}

export type { Locale };
