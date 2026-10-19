import type { Locale, MessageKind } from '../../domain/types.js';

export type InboxKind = MessageKind;

/** One alert as it appears in a contact's in-app inbox. The text is rendered on read, in the contact's language. */
export interface InboxItem {
  id: string;
  /** The person who received it (the emergency contact, as a Sentri user). */
  userId: string;
  /** The person who needs help. */
  fromUserId: string;
  fromName?: string;
  kind: InboxKind;
  /** null for kinds that are not part of a live SOS (low battery, test, shares). */
  sosId: string | null;
  /** Set for location-sharing items. */
  shareId?: string | null;
  locale: Locale;
  /** A fixed position, only for kinds that have no live SOS to read it from. */
  geo?: { lat: number; lon: number; at: number };
  createdAt: number;
  updatedAt: number;
  readAt?: number;
  purgeAfter: number;
}

/** Someone added you as an emergency contact and you have not answered yet. */
export interface Invite {
  contactId: string;
  fromUserId: string;
  fromName?: string;
}

/**
 * Storage the inbox needs. One interface so memory and Postgres can each implement it in one place.
 * "Recipient" always means a Sentri user whose phone number matches a contact entry.
 */
export interface InboxStore {
  /** The user id of the person behind this contact entry, if they have signed up. */
  recipientFor(contactId: string): Promise<string | null>;
  /** The contact entry in `fromUserId`'s list that is this recipient. Used to record who responded. */
  contactIdFor(fromUserId: string, recipientUserId: string): Promise<string | null>;
  displayName(userId: string): Promise<string | null>;
  /** Phone number of a user, for the "call them" button. */
  phoneOf(userId: string): Promise<string | null>;
  /** Same (user, sosId or shareId, kind) refreshes the existing row instead of adding another. */
  upsert(i: InboxItem): Promise<InboxItem>;
  list(userId: string, limit: number): Promise<InboxItem[]>;
  get(userId: string, id: string): Promise<InboxItem | null>;
  markRead(userId: string, id: string, at: number): Promise<boolean>;
  /** Every contact's inbox item for one alert, so their phones can be told to stop ringing. */
  forSos(sosId: string): Promise<{ userId: string; itemId: string }[]>;
  invitesFor(userId: string): Promise<Invite[]>;
  /** Only works if the contact entry really is this user's number. Returns false otherwise. */
  decideInvite(userId: string, contactId: string, status: 'accepted' | 'declined'): Promise<boolean>;
  purge(now: number): Promise<number>;
}
