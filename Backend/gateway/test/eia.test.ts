import { describe, expect, it } from "vitest";

import { EiaClient, FuelPriceService } from "../src/eia/client.js";
import { UpstreamError } from "../src/http.js";
import { fakeFetch, json } from "./helpers.js";

const row = (value: number | string | null, period = "2026-11-09") => ({ response: { data: [{ period, value }] } });

describe("EiaClient", () => {
  it("requests the latest weekly value for a region and product", async () => {
    const fetch = fakeFetch(() => json(row(3.456)));
    const price = await new EiaClient("eia-key", fetch).latestRetailPrice("R50", "EPMR");
    expect(price).toEqual({ price: 3.456, period: "2026-11-09" });
    const url = fetch.calls[0]!.url;
    expect(url.pathname).toBe("/v2/petroleum/pri/gnd/data/");
    expect(url.searchParams.get("api_key")).toBe("eia-key");
    expect(url.searchParams.get("frequency")).toBe("weekly");
    expect(url.searchParams.get("facets[duoarea][]")).toBe("R50");
    expect(url.searchParams.get("facets[product][]")).toBe("EPMR");
    expect(url.searchParams.get("sort[0][direction]")).toBe("desc");
    expect(url.searchParams.get("length")).toBe("1");
  });

  it("accepts numeric strings and rejects empty data", async () => {
    expect(await new EiaClient("k", fakeFetch(() => json(row("4.10")))).latestRetailPrice("NUS", "EPD2D")).toEqual({
      price: 4.1,
      period: "2026-11-09",
    });
    expect(await new EiaClient("k", fakeFetch(() => json(row(null)))).latestRetailPrice("NUS", "EPMR")).toBeNull();
    expect(await new EiaClient("k", fakeFetch(() => json({ response: { data: [] } }))).latestRetailPrice("NUS", "EPMR")).toBeNull();
  });

  it("raises an upstream error for failed requests", async () => {
    const client = new EiaClient("k", fakeFetch(() => new Response("forbidden", { status: 403 })));
    await expect(client.latestRetailPrice("NUS", "EPMR")).rejects.toBeInstanceOf(UpstreamError);
  });
});

describe("FuelPriceService", () => {
  it("returns the regional price for the coordinate", async () => {
    const fetch = fakeFetch(() => json(row(4.89)));
    const result = await new FuelPriceService(new EiaClient("k", fetch)).averageNear(34.05, -118.24, "regular");
    expect(result).toEqual({ pricePerGallon: 4.89, region: "California", period: "2026-11-09", source: "EIA" });
  });

  it("falls back to the national average when the region has no data", async () => {
    const fetch = fakeFetch((url) => json(url.searchParams.get("facets[duoarea][]") === "NUS" ? row(3.2) : { response: { data: [] } }));
    const result = await new FuelPriceService(new EiaClient("k", fetch)).averageNear(39.74, -104.99, "diesel");
    expect(result.pricePerGallon).toBe(3.2);
    expect(result.region).toBe("U.S. average");
    expect(fetch.calls.map((call) => call.url.searchParams.get("facets[product][]"))).toEqual(["EPD2D", "EPD2D"]);
  });

  it("caches prices per region and product", async () => {
    const fetch = fakeFetch(() => json(row(3.5)));
    const service = new FuelPriceService(new EiaClient("k", fetch));
    await service.averageNear(41.88, -87.63, "regular");
    await service.averageNear(41.5, -88.0, "regular");
    expect(fetch.calls).toHaveLength(1);
  });
});
