import type {
  AuditSink,
  Contact,
  Dispatcher,
  GeoPoint,
  Logger,
  MessageKind,
  Notifier,
  Scheduler,
  SosEvent,
  SosState,
  SosStore,
  TriggerType,
} from '../../domain/types.js';
import { noopLogger } from '../../domain/types.js';
import { evaluatePin } from '../../lib/pin.js';
import type { FixedWindowLimiter } from '../../lib/rate-limit.js';
import { hashToken, linkToken } from '../../lib/tokens.js';

export interface EngineConfig {
  cancelWindowMs: number;
  repeatMs: number;
  maxRepeats: number;
  offlineAfterMs: number;
  pinMaxAttempts: number;
  pinLockoutMs: number;
  retentionMs: number;
  baseUrl: string;
  tokenSecret: string;
  pinPepper: Buffer;
}

export interface EngineDeps {
  store: SosStore;
  scheduler: Scheduler;
  notifier: Notifier;
  dispatcher: Dispatcher;
  audit: AuditSink;
  lowBatteryLimiter: FixedWindowLimiter;
  clock: () => number;
  newId: () => string;
  cfg: EngineConfig;
  log?: Logger;
}

export interface SosView {
  sosId: string;
  state: SosState;
  cancelWindowEndsAt: number;
}

export interface PinOutcome {
  /** 'cancelled' is returned for BOTH the real cancel PIN and the duress PIN. */
  result: 'cancelled' | 'wrong' | 'locked' | 'not_found';
  /**
   * Internal flag for the app, never to be shown in the UI: true means the app must
   * keep sending location silently (duress, or the alert is still live).
   */
  keepTracking: boolean;
}

export interface AlertView {
  /** Someone has already tapped "I'm responding". */
  responding: boolean;
  startedAt: number;
  geo?: { lat: number; lon: number; at: number };
}

/**
 * A plain OpenStreetMap link for the last known position, rounded to about 110 m like the phone's own
 * fallback text. Used where there is no live alert page to open (the battery is nearly dead).
 */
export function mapLink(geo?: { lat: number; lon: number }): string {
  if (!geo) return 'unknown';
  return `https://osm.org/?mlat=${geo.lat.toFixed(3)}&mlon=${geo.lon.toFixed(3)}`;
}

export type AckStatus = 'ok' | 'already_acknowledged' | 'ended' | 'invalid';

const REPEAT_KEY = (id: string) => `repeat:${id}`;
const ACTIVATE_KEY = (id: string) => `activate:${id}`;

const view = (e: SosEvent): SosView => ({
  sosId: e.id,
  state: e.state,
  cancelWindowEndsAt: e.cancelWindowEndsAt,
});

/**
 * The SOS state machine.
 *
 *   countdown --(window elapses)--> active --(contact taps link)--> acknowledged
 *       |                              |
 *       +------ cancel PIN ------------+--> cancelled        active --(cap reached)--> expired
 *
 * Every state change is a compare-and-set on the store, so a late tick, a late ack
 * and a PIN entry can race without double-sending or resurrecting a stopped alert.
 */
export class SosEngine {
  private readonly log: Logger;

  constructor(private readonly d: EngineDeps) {
    this.log = d.log ?? noopLogger;
  }

  // ---------------------------------------------------------------- start

  async start(userId: string, trigger: TriggerType, geo?: GeoPoint): Promise<SosView> {
    const { store, clock, cfg } = this.d;
    const now = clock();
    const candidate: SosEvent = {
      id: this.d.newId(),
      userId,
      state: 'countdown',
      duress: false,
      trigger,
      startedAt: now,
      cancelWindowEndsAt: now + cfg.cancelWindowMs,
      repeatCount: 0,
      lastGeo: geo,
      lastSeenAt: now,
      offlineNotified: false,
      dispatched: false,
      pinFailures: 0,
      pinLockedUntil: 0,
      purgeAfter: now + cfg.retentionMs,
    };
    const { created, event } = await store.createEventIfNoActive(candidate);
    if (!created) return view(event); // already running: idempotent
    await this.record('system', 'sos.start', event.id);
    try {
      await this.d.scheduler.schedule(ACTIVATE_KEY(event.id), cfg.cancelWindowMs, () => this.activate(event.id));
    } catch (err) {
      // Fail toward alerting: if the job queue is down, send the alert now rather than never.
      this.log.error({ err: err instanceof Error ? err.message : 'unknown' }, 'activation scheduling failed');
      await this.activate(event.id);
    }
    return view(event);
  }

  /** Called when the cancel window ends. Alerts contacts and the control room. */
  async activate(id: string): Promise<void> {
    const { store, clock, cfg } = this.d;
    const ev = await store.transition(id, ['countdown'], { state: 'active' });
    if (!ev) return; // cancelled during the window

    const contacts = await store.getContacts(ev.userId);
    const expiresAt = clock() + cfg.retentionMs;
    for (const c of contacts) {
      const token = linkToken(cfg.tokenSecret, 'ack', id, c.id);
      await store.saveLink({ hash: hashToken(token), kind: 'ack', subject: id, contactId: c.id, expiresAt });
    }
    await this.record('system', 'sos.active', id);
    await Promise.allSettled([this.dispatchPolice(ev, false), this.tick(id)]);
  }

  // ----------------------------------------------------------------- loop

  /** One round of the repeat loop. Reschedules itself every `repeatMs` until the alert ends. */
  async tick(id: string): Promise<void> {
    const { store, clock, cfg } = this.d;
    const ev = await store.getEvent(id);
    if (!ev || ev.state !== 'active') return;

    if (ev.repeatCount >= cfg.maxRepeats) {
      await store.transition(id, ['active'], { state: 'expired', endedAt: clock() });
      await this.record('system', 'sos.expired', id);
      return;
    }

    const contacts = await store.getContacts(ev.userId);
    const kind: MessageKind = ev.duress ? 'duress' : 'sos';
    const sends: Promise<void>[] = contacts.map((c) =>
      this.safeSend({ kind, sosId: id, contact: c, ackUrl: this.url('r', 'ack', id, c.id), repeat: ev.repeatCount }),
    );

    // Phone went quiet during an active SOS: tell contacts once, with the last known place.
    if (!ev.offlineNotified && clock() - ev.lastSeenAt > cfg.offlineAfterMs) {
      const flagged = await store.transition(id, ['active'], { offlineNotified: true });
      if (flagged) {
        for (const c of contacts) {
          sends.push(
            (async () => {
              const locationUrl = await this.locationUrl(id, c.id);
              await this.safeSend({
                kind: 'offline',
                sosId: id,
                contact: c,
                ackUrl: this.url('r', 'ack', id, c.id),
                locationUrl,
                geo: ev.lastGeo,
                repeat: 0,
              });
            })(),
          );
        }
        await this.record('system', 'sos.offline_notice', id);
      }
    }

    await Promise.all(sends);

    // Bump the counter only if the alert is still active (ack/cancel may have landed meanwhile).
    const next = await store.transition(id, ['active'], { repeatCount: ev.repeatCount + 1 });
    if (!next) return;
    // If this throws, the job fails and the queue retries it (a duplicate alert beats a silent stop).
    await this.d.scheduler.schedule(REPEAT_KEY(id), cfg.repeatMs, () => this.tick(id));
  }

  // ------------------------------------------------------------------ ack

  /** True if the token is a live ack link. Does not change anything (safe for GET / link previews). */
  async peekAck(token: string): Promise<boolean> {
    const link = await this.d.store.getLink(hashToken(token));
    return !!link && link.kind === 'ack' && link.expiresAt > this.d.clock();
  }

  /**
   * What a contact's link page shows: the alert's latest position, and whether it is still running.
   * Works for both the "respond" link ('ack') and the location-only link ('loc'). Read-only.
   * It never reveals whether the alert is under duress: the page looks the same either way.
   */
  async viewAlert(token: string, kind: 'ack' | 'loc'): Promise<AlertView | 'ended' | 'invalid'> {
    const { store, clock } = this.d;
    const link = await store.getLink(hashToken(token));
    if (!link || link.kind !== kind || link.expiresAt <= clock()) return 'invalid';
    return this.alertView(link.subject);
  }

  /** The same read-only view, for a contact who is signed in to the app (no link involved). */
  async alertView(sosId: string): Promise<AlertView | 'ended' | 'invalid'> {
    const ev = await this.d.store.getEvent(sosId);
    if (!ev) return 'invalid';
    if (ev.state !== 'active' && ev.state !== 'acknowledged') return 'ended';
    return {
      responding: ev.state === 'acknowledged',
      startedAt: ev.startedAt,
      geo: ev.lastGeo ? { lat: ev.lastGeo.lat, lon: ev.lastGeo.lon, at: ev.lastGeo.at } : undefined,
    };
  }

  async acknowledge(token: string): Promise<AckStatus> {
    const { store, clock } = this.d;
    const link = await store.getLink(hashToken(token));
    if (!link || link.kind !== 'ack' || link.expiresAt <= clock()) return 'invalid';
    return this.ackEvent(link.subject, link.contactId);
  }

  /** A signed-in contact taps "I'm responding". The caller has already checked the alert was sent to them. */
  async acknowledgeInApp(sosId: string, contactId: string): Promise<AckStatus> {
    return this.ackEvent(sosId, contactId);
  }

  private async ackEvent(sosId: string, contactId: string): Promise<AckStatus> {
    const { store, clock } = this.d;
    const ev = await store.getEvent(sosId);
    if (!ev) return 'invalid';

    const updated = await store.transition(ev.id, ['active'], {
      state: 'acknowledged',
      ackedAt: clock(),
      ackedBy: contactId,
    });
    if (!updated) return ev.state === 'acknowledged' ? 'already_acknowledged' : 'ended';

    await this.d.scheduler.cancel(REPEAT_KEY(ev.id));
    await this.record('contact', 'sos.ack', ev.id);
    // Under duress the user's phone may be watched, so tell them nothing.
    if (!updated.duress) await this.d.notifier.notifyUser(ev.userId, { kind: 'acknowledged', sosId: ev.id });
    // Every contact's phone stops ringing, not only the one that responded.
    await this.d.notifier.alertOver?.(ev.id, 'responded');
    return 'ok';
  }

  // ------------------------------------------------------------------ pin

  /**
   * PIN entry for "whatever alert I currently have running". The phone uses this when it never
   * received the SOS id (a start request that timed out may still have reached the server).
   */
  async submitPinForCurrent(userId: string, pin: string): Promise<PinOutcome> {
    const ev = await this.d.store.getLiveEvent(userId);
    if (!ev) return { result: 'not_found', keepTracking: false };
    return this.submitPin(userId, ev.id, pin);
  }

  async submitPin(userId: string, sosId: string, pin: string): Promise<PinOutcome> {
    const { store, clock, cfg } = this.d;
    const ev = await store.getEvent(sosId);
    if (!ev || ev.userId !== userId) return { result: 'not_found', keepTracking: false };
    if (ev.state === 'cancelled' || ev.state === 'expired') return { result: 'cancelled', keepTracking: false };

    const now = clock();
    if (ev.pinLockedUntil > now) return { result: 'locked', keepTracking: true };

    const pins = await store.getPins(userId);
    if (!pins) return { result: 'not_found', keepTracking: false };

    const decision = await evaluatePin(pin, pins, cfg.pinPepper);

    if (decision === 'cancel') {
      const done = await store.transition(sosId, ['countdown', 'active', 'acknowledged'], {
        state: 'cancelled',
        endedAt: now,
      });
      if (done) {
        await this.d.scheduler.cancel(ACTIVATE_KEY(sosId));
        await this.d.scheduler.cancel(REPEAT_KEY(sosId));
        await this.record('user', 'sos.cancel', sosId);
        await this.d.notifier.alertOver?.(sosId, 'cancelled');
      }
      return { result: 'cancelled', keepTracking: false };
    }

    if (decision === 'duress') {
      if (!ev.duress) {
        await store.updateEvent(sosId, { duress: true, pinFailures: 0 });
        await this.record('user', 'sos.duress', sosId);
        if (ev.dispatched) {
          const fresh = await store.getEvent(sosId);
          if (fresh) await this.dispatchPolice(fresh, true);
        }
        if (ev.state === 'acknowledged') {
          // The loop already stopped; warn contacts once that this is a coerced "all clear".
          const contacts = await store.getContacts(userId);
          await Promise.all(
            contacts.map((c) =>
              this.safeSend({
                kind: 'duress',
                sosId,
                contact: c,
                ackUrl: this.url('r', 'ack', sosId, c.id),
                repeat: 0,
              }),
            ),
          );
        }
      }
      // To anyone watching the screen this looks exactly like a normal cancel.
      return { result: 'cancelled', keepTracking: true };
    }

    // wrong PIN: the alert keeps going; repeated failures lock PIN entry for a while
    const failures = ev.pinFailures + 1;
    const lock = failures >= cfg.pinMaxAttempts;
    await store.updateEvent(sosId, {
      pinFailures: lock ? 0 : failures,
      pinLockedUntil: lock ? now + cfg.pinLockoutMs : ev.pinLockedUntil,
    });
    return { result: lock ? 'locked' : 'wrong', keepTracking: true };
  }

  // ------------------------------------------------------------- location

  /**
   * Heartbeat from the phone during an SOS. Resets the "went offline" detector and tells the
   * phone the current state, which is how it learns that a contact is responding.
   * Under duress an acknowledgement is reported as 'active': a watched phone must show nothing new.
   * Returns null if the SOS is unknown, not this user's, or already ended.
   */
  async updateLocation(userId: string, sosId: string, geo: GeoPoint): Promise<{ state: SosState } | null> {
    const ev = await this.d.store.getEvent(sosId);
    if (!ev || ev.userId !== userId) return null;
    if (ev.state === 'cancelled' || ev.state === 'expired') return null;
    await this.d.store.updateEvent(sosId, { lastGeo: geo, lastSeenAt: this.d.clock(), offlineNotified: false });
    return { state: ev.duress && ev.state === 'acknowledged' ? 'active' : ev.state };
  }

  /** ~5% battery: one-shot "last known location" to contacts. Never claims live tracking. */
  async lowBattery(userId: string, geo?: GeoPoint): Promise<{ sent: boolean }> {
    const { store } = this.d;
    if (!this.d.lowBatteryLimiter.allow(`lowbat:${userId}`)) return { sent: false };

    const contacts = await store.getContacts(userId);
    if (contacts.length === 0) return { sent: false };

    await Promise.all(
      contacts.map(async (c) => {
        await this.safeSend({
          kind: 'low_battery',
          sosId: null,
          contact: c,
          locationUrl: mapLink(geo),
          geo,
          repeat: 0,
        });
      }),
    );
    await this.record('system', 'battery.low_alert', userId);
    return { sent: true };
  }

  // -------------------------------------------------------------- helpers

  /** Audit must never be able to stop an alert: failures are logged, not thrown. */
  private async record(actor: string, action: string, target?: string): Promise<void> {
    try {
      await this.d.audit.append(actor, action, target);
    } catch (err) {
      this.log.error({ action, err: err instanceof Error ? err.message : 'unknown' }, 'audit append failed');
    }
  }

  private url(path: 'r' | 'l', kind: 'ack' | 'loc', subject: string, contactId: string): string {
    const { baseUrl, tokenSecret } = this.d.cfg;
    return `${baseUrl}/${path}/${linkToken(tokenSecret, kind, subject, contactId)}`;
  }

  private async locationUrl(sosId: string, contactId: string): Promise<string> {
    const { store, clock, cfg } = this.d;
    const token = linkToken(cfg.tokenSecret, 'loc', sosId, contactId);
    await store.saveLink({
      hash: hashToken(token),
      kind: 'loc',
      subject: sosId,
      contactId,
      expiresAt: clock() + cfg.retentionMs,
    });
    return `${cfg.baseUrl}/l/${token}`;
  }

  private async safeSend(m: Parameters<Notifier['sendToContact']>[0]): Promise<void> {
    try {
      await this.d.notifier.sendToContact(m);
    } catch (err) {
      // One failing contact must never stop the others.
      this.log.error({ kind: m.kind, err: err instanceof Error ? err.message : 'unknown' }, 'notify failed');
    }
  }

  private async dispatchPolice(ev: SosEvent, update: boolean): Promise<void> {
    try {
      const user = await this.d.store.getUser(ev.userId);
      await this.d.dispatcher.dispatch({
        sosId: ev.id,
        geo: ev.lastGeo,
        duress: ev.duress,
        update,
        userPhone: user?.phone,
        at: this.d.clock(),
      });
      if (!update) await this.d.store.updateEvent(ev.id, { dispatched: true });
    } catch (err) {
      this.log.error({ err: err instanceof Error ? err.message : 'unknown' }, 'dispatch failed');
    }
  }
}

export type { Contact };
