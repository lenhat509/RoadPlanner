import { TtlCache } from "../cache.js";
import type { ExpediaRapidClient, PropertySummary, Ring } from "./client.js";

export interface LodgingQuery {
  lat: number;
  lng: number;
  radiusKm: number;
  checkin: string;
  checkout: string;
  adults: number;
  customerIp: string;
}

/** Wire format consumed by the iOS app (`WaystageGatewayClient`). */
export interface LodgingOffer {
  propertyId: string;
  name: string;
  latitude: number;
  longitude: number;
  nightlyRate: number;
  currency: string;
  provider: "Expedia";
  bookingUrl: string;
}

/** Live lodging rates near a point: geography search → availability → content, cached. */
export class LodgingService {
  constructor(
    private readonly client: ExpediaRapidClient,
    private readonly offersCache = new TtlCache<LodgingOffer[]>(15 * 60_000, 500),
    private readonly contentCache = new TtlCache<PropertySummary>(24 * 60 * 60_000, 20_000),
    private readonly maxProperties = 60,
  ) {}

  async ratesNear(query: LodgingQuery): Promise<LodgingOffer[]> {
    const key = [query.lat.toFixed(2), query.lng.toFixed(2), query.radiusKm, query.checkin, query.checkout, query.adults].join("|");
    return this.offersCache.getOrLoad(key, () => this.load(query));
  }

  private async load(query: LodgingQuery): Promise<LodgingOffer[]> {
    const ids = (await this.client.propertyIdsWithin(circleRing(query.lat, query.lng, query.radiusKm))).slice(0, this.maxProperties);
    if (ids.length === 0) return [];
    const rates = await this.client.availability({
      propertyIds: ids,
      checkin: query.checkin,
      checkout: query.checkout,
      adults: query.adults,
      customerIp: query.customerIp,
    });
    if (rates.length === 0) return [];

    const missing = rates.map((rate) => rate.propertyId).filter((id) => !this.contentCache.get(id));
    if (missing.length > 0) {
      for (const summary of await this.client.content(missing)) this.contentCache.set(summary.propertyId, summary);
    }

    const offers: LodgingOffer[] = [];
    for (const rate of rates) {
      const summary = this.contentCache.get(rate.propertyId);
      if (!summary) continue;
      offers.push({
        propertyId: rate.propertyId,
        name: summary.name,
        latitude: summary.latitude,
        longitude: summary.longitude,
        nightlyRate: rate.nightlyRate,
        currency: rate.currency,
        provider: "Expedia",
        bookingUrl: bookingUrl(rate.propertyId),
      });
    }
    return offers.sort((a, b) => a.nightlyRate - b.nightlyRate);
  }
}

/** Closed polygon approximating a circle, in GeoJSON (lng, lat) order. */
export function circleRing(lat: number, lng: number, radiusKm: number, points = 16): Ring {
  const ring: Ring = [];
  const latDelta = radiusKm / 111.32;
  const lngDelta = radiusKm / (111.32 * Math.max(0.01, Math.cos((lat * Math.PI) / 180)));
  for (let index = 0; index < points; index += 1) {
    const angle = (2 * Math.PI * index) / points;
    ring.push([round6(lng + lngDelta * Math.cos(angle)), round6(lat + latDelta * Math.sin(angle))]);
  }
  const first = ring[0];
  if (first) ring.push([first[0], first[1]]);
  return ring;
}

/** Public Expedia hotel page for a Rapid property ID. */
export function bookingUrl(propertyId: string): string {
  return `https://www.expedia.com/h${encodeURIComponent(propertyId)}.Hotel-Information`;
}

function round6(value: number): number {
  return Math.round(value * 1e6) / 1e6;
}
