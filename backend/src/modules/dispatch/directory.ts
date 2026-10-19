import type { GeoPoint } from '../../domain/types.js';

export type ControlRoomKind = 'state_command' | 'area_command' | 'control_room' | 'emergency_line';

/** An OFFICIAL control room or emergency line. Never an individual officer. */
export interface ControlRoom {
  id: string;
  name: string;
  kind: ControlRoomKind;
  officialPhone?: string;
  officialSms?: string;
}

export interface Directory {
  resolve(geo?: GeoPoint): Promise<ControlRoom | null>;
}

export interface DirectoryEntry {
  room: ControlRoom;
  /** [minLat, minLon, maxLat, maxLon]. The PostGIS version (step 1b) uses real boundaries. */
  bbox: [number, number, number, number];
  /** 1 = state, 2 = LGA. Higher level = more specific. */
  level: number;
}

const KIND_RANK: Record<ControlRoomKind, number> = {
  control_room: 0,
  area_command: 1,
  state_command: 2,
  emergency_line: 3,
};

export class InMemoryDirectory implements Directory {
  constructor(
    private readonly entries: DirectoryEntry[],
    private readonly fallback: ControlRoom | null = null,
  ) {}

  async resolve(geo?: GeoPoint): Promise<ControlRoom | null> {
    if (!geo) return this.fallback;
    const hits = this.entries
      .filter(({ bbox: [a, b, c, d] }) => geo.lat >= a && geo.lat <= c && geo.lon >= b && geo.lon <= d)
      .sort((x, y) => y.level - x.level || KIND_RANK[x.room.kind] - KIND_RANK[y.room.kind]);
    return hits[0]?.room ?? this.fallback;
  }
}
