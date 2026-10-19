import { createSign } from 'node:crypto';
import type { Logger } from '../../domain/types.js';
import { noopLogger } from '../../domain/types.js';
import type { PushPayload, PushSender } from './contact-notifier.js';

/** Where device push tokens live. Postgres implementation: pg-push-tokens.ts. */
export interface PushTokenStore {
  tokensForUser(userId: string): Promise<{ deviceId: string; token: string }[]>;
  /** A contact who also has the app: their own devices, found through their phone number. */
  tokensForContact(contactId: string): Promise<{ deviceId: string; token: string }[]>;
  /** Called when FCM says a token is no longer valid. */
  forgetToken(deviceId: string): Promise<void>;
}

export interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
}

const b64 = (o: unknown) => Buffer.from(JSON.stringify(o)).toString('base64url');

/**
 * Firebase Cloud Messaging (HTTP v1) sender. No SDK: a signed JWT is exchanged for a short-lived
 * access token, which is cached until shortly before it expires.
 *
 * Messages are data-only. The app builds the notification itself, so alert text is not shaped by
 * the push provider, and only what the app needs to act on leaves our servers.
 */
export class FcmPushSender implements PushSender {
  private access: { token: string; expiresAt: number } | undefined;
  /** One token exchange at a time: several devices sending at once share it. */
  private fetching: Promise<string> | undefined;

  constructor(
    private readonly tokens: PushTokenStore,
    private readonly account: ServiceAccount,
    private readonly fetchFn: typeof fetch = fetch,
    private readonly clock: () => number = Date.now,
    private readonly log: Logger = noopLogger,
  ) {}

  private accessToken(): Promise<string> {
    const now = this.clock();
    if (this.access && this.access.expiresAt - 60_000 > now) return Promise.resolve(this.access.token);
    this.fetching ??= this.exchange().finally(() => {
      this.fetching = undefined;
    });
    return this.fetching;
  }

  private async exchange(): Promise<string> {
    const now = this.clock();
    const iat = Math.floor(now / 1000);
    const claim = {
      iss: this.account.client_email,
      scope: 'https://www.googleapis.com/auth/firebase.messaging',
      aud: 'https://oauth2.googleapis.com/token',
      iat,
      exp: iat + 3600,
    };
    const unsigned = `${b64({ alg: 'RS256', typ: 'JWT' })}.${b64(claim)}`;
    const sig = createSign('RSA-SHA256').update(unsigned).sign(this.account.private_key).toString('base64url');
    const res = await this.fetchFn('https://oauth2.googleapis.com/token', {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: `${unsigned}.${sig}` }),
      signal: AbortSignal.timeout(5000),
    });
    if (!res.ok) throw new Error(`fcm auth ${res.status}`);
    const j = (await res.json()) as { access_token: string; expires_in: number };
    this.access = { token: j.access_token, expiresAt: now + j.expires_in * 1000 };
    return j.access_token;
  }

  private async sendOne(deviceId: string, token: string, p: PushPayload): Promise<boolean> {
    const bearer = await this.accessToken();
    // A phone that is offline when an alert is sent still gets it for ten minutes after it reconnects. If the alert
    // ends first, the "clear" message (same collapse key) replaces it, so the phone never rings for a finished alert.
    const ttl = p.kind === 'sos' || p.kind === 'duress' || p.kind === 'offline' || p.kind === 'clear' ? 1800 : 60;
    const data: Record<string, string> = { kind: p.kind, text: p.text };
    if (p.sosId) data.sosId = p.sosId;
    if (p.inboxId) data.inboxId = p.inboxId;
    const res = await this.fetchFn(`https://fcm.googleapis.com/v1/projects/${this.account.project_id}/messages:send`, {
      method: 'POST',
      headers: { authorization: `Bearer ${bearer}`, 'content-type': 'application/json' },
      body: JSON.stringify({
        message: {
          token,
          data,
          // Alerts must wake the phone now, not at the next battery-friendly moment.
          android: { priority: 'HIGH', ttl: `${ttl}s`, ...(p.sosId ? { collapse_key: p.sosId } : {}) },
          apns: { headers: { 'apns-priority': '10', 'apns-expiration': String(Math.floor(this.clock() / 1000) + ttl), ...(p.sosId ? { 'apns-collapse-id': p.sosId.slice(0, 64) } : {}) }, payload: { aps: { 'content-available': 1 } } },
        },
      }),
      signal: AbortSignal.timeout(5000),
    });
    if (res.ok) return true;
    if (res.status === 404 || res.status === 400) {
      // UNREGISTERED / INVALID_ARGUMENT: the app was removed or the token is stale.
      const body = (await res.json().catch(() => ({}))) as { error?: { status?: string } };
      if (body.error?.status === 'NOT_FOUND' || body.error?.status === 'UNREGISTERED' || body.error?.status === 'INVALID_ARGUMENT') {
        await this.tokens.forgetToken(deviceId).catch(() => {});
      }
    }
    if (res.status === 401) this.access = undefined; // token revoked: fetch a new one next time
    return false;
  }

  private async sendAll(list: { deviceId: string; token: string }[], p: PushPayload): Promise<boolean> {
    if (list.length === 0) return false;
    const results = await Promise.all(
      list.map((t) =>
        this.sendOne(t.deviceId, t.token, p).catch((err) => {
          this.log.error({ err: err instanceof Error ? err.message : 'unknown' }, 'push failed');
          return false;
        }),
      ),
    );
    return results.some(Boolean);
  }

  async sendToContact(contactId: string, p: PushPayload): Promise<boolean> {
    return this.sendAll(await this.tokens.tokensForContact(contactId), p);
  }

  async sendToUser(userId: string, p: PushPayload): Promise<boolean> {
    return this.sendAll(await this.tokens.tokensForUser(userId), p);
  }
}
