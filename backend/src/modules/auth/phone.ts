import { z } from 'zod';
import type { Locale } from '../../domain/types.js';

/**
 * Normalises a phone number to E.164. Nigerian local format (0803 123 4567) becomes +234803...
 * Returns null for anything that isn't plausibly a phone number.
 */
export function normalizePhone(input: string, defaultCountryCode = '234'): string | null {
  const s = input.replace(/[\s\-().]/g, '');
  let e164: string;
  if (/^\+\d+$/.test(s)) e164 = s;
  else if (/^00\d+$/.test(s)) e164 = `+${s.slice(2)}`;
  else if (/^0\d+$/.test(s)) e164 = `+${defaultCountryCode}${s.slice(1)}`;
  else if (new RegExp(`^${defaultCountryCode}\\d+$`).test(s)) e164 = `+${s}`;
  else return null;
  if (!/^\+[1-9]\d{7,14}$/.test(e164)) return null;
  // Nigeria: +234 followed by a 10-digit national number.
  if (e164.startsWith('+234') && e164.length !== 14) return null;
  return e164;
}

export const LocaleSchema = z.enum(['en', 'ha', 'yo', 'ig', 'pcm']);

export const MIN_CONTACTS = 3;
export const MAX_CONTACTS = 5;

export class ContactError extends Error {}

/** Contacts cannot change while an alert is live: their response links would be deleted mid-emergency. */
export class LiveSosError extends Error {
  constructor() {
    super('An alert is active. Contacts can be changed once it has ended.');
  }
}

/** Validates the onboarding contact list: 3-5 distinct, valid numbers, none of them the user's own. */
export function validateContacts(
  input: { phone: string; locale?: Locale }[],
  ownPhone: string,
  defaultCountryCode = '234',
): { phone: string; locale: Locale }[] {
  if (input.length < MIN_CONTACTS || input.length > MAX_CONTACTS) {
    throw new ContactError(`Add ${MIN_CONTACTS} to ${MAX_CONTACTS} emergency contacts`);
  }
  const seen = new Set<string>();
  return input.map((c) => {
    const phone = normalizePhone(c.phone, defaultCountryCode);
    if (!phone) throw new ContactError('One of the contact numbers is not valid');
    if (phone === ownPhone) throw new ContactError('You cannot add your own number as a contact');
    if (seen.has(phone)) throw new ContactError('Each contact must have a different number');
    seen.add(phone);
    return { phone, locale: c.locale ?? 'en' };
  });
}
