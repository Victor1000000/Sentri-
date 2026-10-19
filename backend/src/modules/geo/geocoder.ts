/**
 * Reverse geocoding: coordinates to street, area, LGA and state names.
 *
 * Privacy: coordinates are sensitive. Point NOMINATIM_URL at a Nominatim you host in the same
 * region as this API. Do not use the public nominatim.openstreetmap.org for real users: it rate-limits
 * and would see every user's position. A lookup is a convenience only. An SOS never waits on it.
 */
export interface Place {
  street?: string;
  area?: string;
  lga?: string;
  state?: string;
  /** One line for display, e.g. "Allen Avenue, Ikeja, Lagos". */
  label: string;
}

export interface ReverseGeocoder {
  reverse(lat: number, lon: number): Promise<Place | null>;
}

/** Used when no geocoder is configured. */
export class NullGeocoder implements ReverseGeocoder {
  async reverse(): Promise<Place | null> {
    return null;
  }
}

interface NominatimAddress {
  road?: string;
  pedestrian?: string;
  suburb?: string;
  neighbourhood?: string;
  quarter?: string;
  city_district?: string;
  county?: string;
  state_district?: string;
  city?: string;
  town?: string;
  village?: string;
  state?: string;
}

/** Turns a Nominatim "address" object into a Place. Pure, so it is easy to test. */
export function placeFromNominatim(address: NominatimAddress | undefined): Place | null {
  if (!address) return null;
  const street = address.road ?? address.pedestrian;
  const area = address.suburb ?? address.neighbourhood ?? address.quarter ?? address.city_district ?? address.town ?? address.village ?? address.city;
  // Nigerian LGAs usually arrive as county or state_district.
  const lga = address.county ?? address.state_district;
  const state = address.state?.replace(/\s+State$/i, '');
  const parts = [street, area, state].filter((p): p is string => !!p);
  if (parts.length === 0) return null;
  return { street, area, lga, state, label: parts.join(', ') };
}

export class NominatimGeocoder implements ReverseGeocoder {
  constructor(
    private readonly baseUrl: string,
    private readonly timeoutMs = 2000,
    private readonly fetchFn: typeof fetch = fetch,
  ) {}

  async reverse(lat: number, lon: number): Promise<Place | null> {
    const url = new URL('/reverse', this.baseUrl);
    url.search = new URLSearchParams({
      format: 'jsonv2',
      lat: String(lat),
      lon: String(lon),
      zoom: '18',
      addressdetails: '1',
      'accept-language': 'en',
    }).toString();
    try {
      const res = await this.fetchFn(url, { signal: AbortSignal.timeout(this.timeoutMs) });
      if (!res.ok) return null;
      const body = (await res.json()) as { address?: NominatimAddress };
      return placeFromNominatim(body.address);
    } catch {
      return null; // slow or down: callers carry on with coordinates only
    }
  }
}

/** Caches by coordinates rounded to about 11 m, so a moving user does not hit the geocoder every second. */
export class CachedGeocoder implements ReverseGeocoder {
  private cache = new Map<string, { at: number; place: Place | null }>();

  constructor(
    private readonly inner: ReverseGeocoder,
    private readonly ttlMs = 600_000,
    private readonly maxEntries = 5000,
    private readonly clock: () => number = Date.now,
  ) {}

  async reverse(lat: number, lon: number): Promise<Place | null> {
    const key = `${lat.toFixed(4)},${lon.toFixed(4)}`;
    const hit = this.cache.get(key);
    if (hit && this.clock() - hit.at < this.ttlMs) return hit.place;
    const place = await this.inner.reverse(lat, lon);
    // Do not remember failures for long: a retry soon after may succeed.
    if (place || !hit) {
      if (this.cache.size >= this.maxEntries) this.cache.delete(this.cache.keys().next().value as string);
      this.cache.set(key, { at: place ? this.clock() : this.clock() - this.ttlMs + 30_000, place });
    }
    return place;
  }
}
