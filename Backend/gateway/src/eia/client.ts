import { TtlCache } from "../cache.js";
import type { FetchLike } from "../http.js";
import { UpstreamError } from "../http.js";
import { REGIONS, regionFor } from "./padd.js";

export type FuelType = "regular" | "midgrade" | "premium" | "diesel";

/** EIA product codes for weekly retail prices. */
export const EIA_PRODUCTS: Record<FuelType, string> = {
  regular: "EPMR",
  midgrade: "EPMM",
  premium: "EPMP",
  diesel: "EPD2D",
};

export interface RetailPrice {
  price: number;
  period: string;
}

/**
 * U.S. Energy Information Administration API v2 — weekly retail gasoline and diesel prices.
 * Docs: https://www.eia.gov/opendata/documentation.php
 */
export class EiaClient {
  constructor(
    private readonly apiKey: string,
    private readonly fetchImpl: FetchLike = fetch,
    private readonly baseUrl = "https://api.eia.gov",
  ) {}

  async latestRetailPrice(duoarea: string, product: string): Promise<RetailPrice | null> {
    const params = new URLSearchParams({
      api_key: this.apiKey,
      frequency: "weekly",
      "data[0]": "value",
      "facets[duoarea][]": duoarea,
      "facets[product][]": product,
      "sort[0][column]": "period",
      "sort[0][direction]": "desc",
      offset: "0",
      length: "1",
    });
    const response = await this.fetchImpl(new URL(`/v2/petroleum/pri/gnd/data/?${params}`, this.baseUrl));
    if (!response.ok) throw new UpstreamError("EIA", response.status, (await response.text().catch(() => "")).slice(0, 200));
    const json = (await response.json()) as { response?: { data?: { period?: string; value?: number | string | null }[] } };
    const row = json.response?.data?.[0];
    const price = Number(row?.value);
    if (!row?.period || !Number.isFinite(price) || price <= 0) return null;
    return { price, period: row.period };
  }
}

export interface FuelAverage {
  pricePerGallon: number | null;
  region: string | null;
  period: string | null;
  source: "EIA";
}

/** Regional average for a coordinate, falling back to the national average. Cached for 6 h. */
export class FuelPriceService {
  constructor(
    private readonly client: EiaClient,
    private readonly cache = new TtlCache<RetailPrice | null>(6 * 60 * 60_000, 200),
  ) {}

  async averageNear(lat: number, lng: number, fuelType: FuelType): Promise<FuelAverage> {
    const product = EIA_PRODUCTS[fuelType];
    for (const region of [regionFor(lat, lng), REGIONS.NUS]) {
      const price = await this.cache.getOrLoad(`${region.code}|${product}`, () => this.client.latestRetailPrice(region.code, product));
      if (price) return { pricePerGallon: price.price, region: region.name, period: price.period, source: "EIA" };
    }
    return { pricePerGallon: null, region: null, period: null, source: "EIA" };
  }
}
