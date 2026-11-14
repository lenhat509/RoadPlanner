import type { FetchLike } from "../http.js";
import { UpstreamError } from "../http.js";
import { eanAuthorizationHeader } from "./signature.js";

export interface ExpediaCredentials {
  apiKey: string;
  sharedSecret: string;
  baseUrl: string;
}

export interface PropertySummary {
  propertyId: string;
  name: string;
  latitude: number;
  longitude: number;
}

export interface PropertyRate {
  propertyId: string;
  /** Average price per night including taxes and fees. */
  nightlyRate: number;
  currency: string;
}

export interface AvailabilityRequest {
  propertyIds: string[];
  checkin: string;
  checkout: string;
  adults: number;
  customerIp: string;
  currency?: string;
}

/** Longitude/latitude ring (GeoJSON order). */
export type Ring = [number, number][];

const MAX_IDS_PER_REQUEST = 250;

/**
 * Expedia Rapid API v3 client (geography search, availability, content).
 * Docs: https://developers.expediagroup.com/rapid
 */
export class ExpediaRapidClient {
  constructor(
    private readonly credentials: ExpediaCredentials,
    private readonly fetchImpl: FetchLike = fetch,
    private readonly now: () => number = Date.now,
  ) {}

  /** Property IDs inside a polygon (`POST /v3/properties/geography`). */
  async propertyIdsWithin(ring: Ring): Promise<string[]> {
    const body = JSON.stringify({ type: "Polygon", coordinates: [ring] });
    const json = await this.request("/v3/properties/geography?include=property_ids&supply_source=expedia", {
      method: "POST",
      body,
      headers: { "Content-Type": "application/json" },
    });
    return json && typeof json === "object" ? Object.keys(json as Record<string, unknown>) : [];
  }

  /** Cheapest available rate per property (`GET /v3/properties/availability`). */
  async availability(request: AvailabilityRequest): Promise<PropertyRate[]> {
    const nights = nightsBetween(request.checkin, request.checkout);
    const rates: PropertyRate[] = [];
    for (const ids of chunk(request.propertyIds, MAX_IDS_PER_REQUEST)) {
      const params = new URLSearchParams({
        checkin: request.checkin,
        checkout: request.checkout,
        currency: request.currency ?? "USD",
        country_code: "US",
        language: "en-US",
        occupancy: String(request.adults),
        rate_plan_count: "1",
        sales_channel: "mobile_app",
        sales_environment: "hotel_only",
      });
      for (const id of ids) params.append("property_id", id);
      const json = await this.request(`/v3/properties/availability?${params}`, {
        method: "GET",
        headers: { "Customer-Ip": request.customerIp },
      });
      for (const property of Array.isArray(json) ? json : []) {
        const rate = cheapestNightlyRate(property, String(request.adults), nights);
        if (rate) rates.push(rate);
      }
    }
    return rates;
  }

  /** Names and coordinates (`GET /v3/properties/content`). */
  async content(propertyIds: string[]): Promise<PropertySummary[]> {
    const summaries: PropertySummary[] = [];
    for (const ids of chunk(propertyIds, MAX_IDS_PER_REQUEST)) {
      const params = new URLSearchParams({ language: "en-US", supply_source: "expedia" });
      for (const id of ids) params.append("property_id", id);
      const json = (await this.request(`/v3/properties/content?${params}`, { method: "GET" })) as Record<string, RawContent> | null;
      for (const [id, property] of Object.entries(json ?? {})) {
        const coordinates = property?.location?.coordinates;
        if (!property?.name || typeof coordinates?.latitude !== "number" || typeof coordinates?.longitude !== "number") continue;
        summaries.push({ propertyId: id, name: property.name, latitude: coordinates.latitude, longitude: coordinates.longitude });
      }
    }
    return summaries;
  }

  private async request(path: string, init: RequestInit): Promise<unknown> {
    const response = await this.fetchImpl(new URL(path, this.credentials.baseUrl), {
      ...init,
      headers: {
        Accept: "application/json",
        "Accept-Encoding": "gzip",
        "User-Agent": "WaystageGateway/1.0",
        Authorization: eanAuthorizationHeader(this.credentials.apiKey, this.credentials.sharedSecret, this.now()),
        ...(init.headers as Record<string, string> | undefined),
      },
    });
    // Rapid answers 404 when nothing is available for the request.
    if (response.status === 404) return null;
    if (!response.ok) {
      const text = await response.text().catch(() => "");
      throw new UpstreamError("Expedia", response.status, text.slice(0, 200));
    }
    return response.json();
  }
}

interface RawContent {
  name?: string;
  location?: { coordinates?: { latitude?: number; longitude?: number } };
}

interface RawAvailability {
  property_id?: string;
  status?: string;
  rooms?: {
    rates?: {
      available_rooms?: number;
      occupancy_pricing?: Record<string, { totals?: { inclusive?: { request_currency?: { value?: string; currency?: string } } } }>;
    }[];
  }[];
}

export function cheapestNightlyRate(raw: unknown, occupancy: string, nights: number): PropertyRate | null {
  const property = raw as RawAvailability;
  if (!property?.property_id || (property.status && property.status !== "available")) return null;
  let best: { total: number; currency: string } | null = null;
  for (const room of property.rooms ?? []) {
    for (const rate of room.rates ?? []) {
      if (rate.available_rooms !== undefined && rate.available_rooms < 1) continue;
      const total = rate.occupancy_pricing?.[occupancy]?.totals?.inclusive?.request_currency;
      const value = Number(total?.value);
      if (!Number.isFinite(value) || value <= 0) continue;
      if (!best || value < best.total) best = { total: value, currency: total?.currency ?? "USD" };
    }
  }
  if (!best) return null;
  return {
    propertyId: property.property_id,
    nightlyRate: Math.round((best.total / Math.max(1, nights)) * 100) / 100,
    currency: best.currency,
  };
}

export function nightsBetween(checkin: string, checkout: string): number {
  const ms = Date.parse(`${checkout}T00:00:00Z`) - Date.parse(`${checkin}T00:00:00Z`);
  return Math.max(1, Math.round(ms / 86_400_000));
}

function chunk<T>(items: T[], size: number): T[][] {
  const result: T[][] = [];
  for (let index = 0; index < items.length; index += size) result.push(items.slice(index, index + size));
  return result;
}
