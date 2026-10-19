export interface ShareGeo {
  lat: number;
  lon: number;
  accuracyM?: number;
  at: number;
}

export interface LocationShare {
  id: string;
  userId: string;
  /** Sentri users who can follow this share. */
  recipientIds: string[];
  startedAt: number;
  expiresAt: number;
  endedAt?: number;
  lastGeo?: ShareGeo;
  purgeAfter: number;
}

/** Only the latest position is stored, never a trail. */
export interface ShareStore {
  create(s: LocationShare): Promise<void>;
  get(id: string): Promise<LocationShare | null>;
  /** The user's share that has not ended and has not passed its limit. */
  active(userId: string, now: number): Promise<LocationShare[]>;
  /** False unless the share is the user's, still running and not expired. */
  updateGeo(userId: string, id: string, geo: ShareGeo, now: number): Promise<boolean>;
  /** Marks it ended once. Returns the share, or null if it was not the user's or had already ended. */
  end(userId: string, id: string, at: number): Promise<LocationShare | null>;
  extend(userId: string, id: string, expiresAt: number, now: number): Promise<boolean>;
  /** Shares that passed their limit without being stopped. */
  due(now: number): Promise<LocationShare[]>;
  purge(now: number): Promise<number>;
}
