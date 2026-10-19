import { createHmac, randomBytes, scrypt, timingSafeEqual } from 'node:crypto';
import type { PinRecord, UserPins } from '../domain/types.js';

/**
 * PIN handling for the cancel PIN and the duress PIN.
 *
 * - PINs are 4-8 digits, so the keyspace is small. The pepper (a server secret,
 *   kept outside the database) plus scrypt and attempt lockout are what make
 *   offline guessing impractical. If the pepper AND the database leak, short PINs
 *   can be brute-forced. That is why the app should also keep its own verifier in
 *   the phone's secure hardware for the offline cancel window.
 * - evaluatePin always checks BOTH PINs so timing does not reveal which one matched.
 */

export class PinError extends Error {}

export type PinDecision = 'cancel' | 'duress' | 'wrong';

const PIN_FORMAT = /^\d{4,8}$/;

function derive(pin: string, salt: Buffer, pepper: Buffer): Promise<Buffer> {
  const pre = createHmac('sha256', pepper).update(pin, 'utf8').digest();
  return new Promise((resolve, reject) =>
    scrypt(pre, salt, 32, { N: 16384, r: 8, p: 1 }, (err, key) => (err ? reject(err) : resolve(key))),
  );
}

export function validatePinFormat(pin: string): void {
  if (!PIN_FORMAT.test(pin)) throw new PinError('PIN must be 4 to 8 digits');
}

export async function hashPin(pin: string, pepper: Buffer): Promise<PinRecord> {
  validatePinFormat(pin);
  const salt = randomBytes(16);
  const hash = await derive(pin, salt, pepper);
  return { salt: salt.toString('base64'), hash: hash.toString('base64') };
}

export async function verifyPin(pin: string, rec: PinRecord, pepper: Buffer): Promise<boolean> {
  if (!PIN_FORMAT.test(pin)) {
    // Still burn the same work so malformed input is not a timing side channel.
    await derive('0000', Buffer.from(rec.salt, 'base64'), pepper);
    return false;
  }
  const expected = Buffer.from(rec.hash, 'base64');
  const actual = await derive(pin, Buffer.from(rec.salt, 'base64'), pepper);
  return expected.length === actual.length && timingSafeEqual(expected, actual);
}

/** Creates the pair stored for a user. The two PINs must differ. */
export async function createPinPair(
  cancelPin: string,
  duressPin: string,
  pepper: Buffer,
): Promise<UserPins> {
  validatePinFormat(cancelPin);
  validatePinFormat(duressPin);
  if (cancelPin === duressPin) throw new PinError('Cancel PIN and duress PIN must be different');
  const [cancel, duress] = await Promise.all([hashPin(cancelPin, pepper), hashPin(duressPin, pepper)]);
  return { cancel, duress };
}

export async function evaluatePin(
  input: string,
  pins: UserPins,
  pepper: Buffer,
): Promise<PinDecision> {
  const [isCancel, isDuress] = await Promise.all([
    verifyPin(input, pins.cancel, pepper),
    verifyPin(input, pins.duress, pepper),
  ]);
  if (isCancel) return 'cancel';
  if (isDuress) return 'duress';
  return 'wrong';
}
