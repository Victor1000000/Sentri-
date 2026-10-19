import type { ContactMessage, Logger, Notifier } from '../../domain/types.js';
import { noopLogger } from '../../domain/types.js';

export interface PushPayload {
  kind: string;
  text: string;
  sosId?: string | null;
  /** The inbox item the app should open. The app never opens a link from a notification. */
  inboxId?: string;
}

/** What the notifier needs from the inbox: store the alert for the contact and push it. */
export interface AlertDelivery {
  over?(sosId: string, reason: 'responded' | 'cancelled'): Promise<void>;
  deliver(m: { kind: ContactMessage['kind']; sosId: string | null; contact: ContactMessage['contact']; geo?: ContactMessage['geo'] }): Promise<'delivered' | 'push_failed' | 'no_app'>;
}

/** Push adapter port. */
export interface PushSender {
  /** Returns false when the contact has no push token or delivery failed. */
  sendToContact(contactId: string, p: PushPayload): Promise<boolean>;
  sendToUser(userId: string, p: PushPayload): Promise<boolean>;
}

/** Placeholder: nothing is pushed. Alerts are still stored in the contact's inbox. */
export class NoopPushSender implements PushSender {
  async sendToContact(): Promise<boolean> {
    return false;
  }
  async sendToUser(): Promise<boolean> {
    return false;
  }
}

/**
 * Alerts to emergency contacts go through the app only: an inbox entry plus a high-priority push.
 * There is no SMS and no link, on purpose. Sentri never texts a contact, so a text that claims to
 * be a Sentri alert can only be a scam. A contact without the app is simply not reachable, and the
 * owner is told that when they add the contact.
 */
export class ContactNotifier implements Notifier {
  constructor(
    private readonly inbox: AlertDelivery,
    private readonly push: PushSender,
    private readonly log: Logger = noopLogger,
  ) {}

  async sendToContact(m: ContactMessage): Promise<void> {
    const r = await this.inbox.deliver({ kind: m.kind, sosId: m.sosId, contact: m.contact, geo: m.geo });
    if (r === 'no_app') this.log.warn({ kind: m.kind, repeat: m.repeat }, 'contact has no app: not alerted');
  }

  async alertOver(sosId: string, reason: 'responded' | 'cancelled'): Promise<void> {
    await this.inbox.over?.(sosId, reason).catch(() => {});
  }

  async notifyUser(userId: string, n: { kind: 'acknowledged'; sosId: string }): Promise<void> {
    await this.push
      .sendToUser(userId, { kind: n.kind, text: 'A contact is responding to your alert.', sosId: n.sosId })
      .catch(() => false);
  }
}
