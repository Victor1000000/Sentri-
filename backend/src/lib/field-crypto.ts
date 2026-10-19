import { createCipheriv, createDecipheriv, createHmac, randomBytes } from 'node:crypto';

/**
 * Field-level protection for phone numbers and push tokens at rest.
 *
 * - encrypt/decrypt: AES-256-GCM, random 96-bit nonce, a leading version byte so keys can rotate.
 * - blindIndex: keyed HMAC so we can look a phone number up without storing it in the clear.
 *
 * Both keys are 32 bytes, supplied as 64 hex characters from a secret manager (never the database).
 */
export class FieldCrypto {
  private readonly key: Buffer;
  private readonly indexKey: Buffer;

  constructor(dataKeyHex: string, indexKeyHex: string) {
    this.key = FieldCrypto.parseKey(dataKeyHex, 'DATA_KEY');
    this.indexKey = FieldCrypto.parseKey(indexKeyHex, 'PHONE_HMAC_KEY');
  }

  private static parseKey(hex: string, name: string): Buffer {
    if (!/^[0-9a-fA-F]{64}$/.test(hex)) throw new Error(`${name} must be 64 hex characters (32 bytes)`);
    return Buffer.from(hex, 'hex');
  }

  encrypt(plain: string): Buffer {
    const iv = randomBytes(12);
    const c = createCipheriv('aes-256-gcm', this.key, iv);
    const ct = Buffer.concat([c.update(plain, 'utf8'), c.final()]);
    return Buffer.concat([Buffer.from([1]), iv, c.getAuthTag(), ct]);
  }

  decrypt(buf: Buffer): string {
    if (buf.length < 30 || buf[0] !== 1) throw new Error('unsupported ciphertext');
    const d = createDecipheriv('aes-256-gcm', this.key, buf.subarray(1, 13));
    d.setAuthTag(buf.subarray(13, 29));
    return Buffer.concat([d.update(buf.subarray(29)), d.final()]).toString('utf8');
  }

  blindIndex(value: string): Buffer {
    return createHmac('sha256', this.indexKey).update(value).digest();
  }
}
