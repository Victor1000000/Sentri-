import type { Pool } from 'pg';
import type { FieldCrypto } from '../../lib/field-crypto.js';
import type { PushTokenStore } from './fcm.js';

export class PgPushTokens implements PushTokenStore {
  constructor(
    private readonly pool: Pool,
    private readonly fc: FieldCrypto,
  ) {}

  private decrypt(rows: { id: string; push_token_enc: Buffer }[]) {
    return rows.flatMap((r) => {
      try {
        return [{ deviceId: r.id, token: this.fc.decrypt(r.push_token_enc) }];
      } catch {
        return []; // unreadable token (key changed): skip it rather than fail the alert
      }
    });
  }

  async tokensForUser(userId: string) {
    const r = await this.pool.query(
      'SELECT id, push_token_enc FROM devices WHERE user_id = $1 AND revoked_at IS NULL AND push_token_enc IS NOT NULL',
      [userId],
    );
    return this.decrypt(r.rows);
  }

  async tokensForContact(contactId: string) {
    // The contact's phone blind index equals a user's blind index when that person also has the app.
    const r = await this.pool.query(
      `SELECT d.id, d.push_token_enc
         FROM contacts c
         JOIN users u ON u.phone_hmac = c.phone_hmac AND u.deleted_at IS NULL
         JOIN devices d ON d.user_id = u.id AND d.revoked_at IS NULL AND d.push_token_enc IS NOT NULL
        WHERE c.id = $1`,
      [contactId],
    );
    return this.decrypt(r.rows);
  }

  async forgetToken(deviceId: string): Promise<void> {
    await this.pool.query('UPDATE devices SET push_token_enc = NULL WHERE id = $1', [deviceId]);
  }
}
