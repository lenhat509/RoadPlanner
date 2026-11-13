import type { FastifyInstance } from "fastify";
import { afterEach, describe, expect, it } from "vitest";

import type { AppConfig } from "../src/config.js";
import { loadConfig } from "../src/config.js";
import { EiaClient, FuelPriceService } from "../src/eia/client.js";
import { ExpediaRapidClient } from "../src/expedia/client.js";
import { LodgingService } from "../src/expedia/lodging.js";
import { UpstreamError } from "../src/http.js";
import { buildServer } from "../src/server.js";
import { fakeFetch, json, TEST_TOKEN } from "./helpers.js";

const config: AppConfig = { port: 0, host: "127.0.0.1", logLevel: "silent", appTokens: [TEST_TOKEN], rateLimitPerMinute: 1_000 };
const auth = { "x-cadence-app-token": TEST_TOKEN };
let app: FastifyInstance | undefined;

afterEach(async () => {
  await app?.close();
  app = undefined;
});

function lodgingService(failing = false): LodgingService {
  const fetch = fakeFetch((url) => {
    if (failing) return new Response("boom", { status: 500 });
    if (url.pathname.endsWith("/geography")) return json({ "7": {} });
    if (url.pathname.endsWith("/availability")) {
      return json([{ property_id: "7", status: "available", rooms: [{ rates: [{ occupancy_pricing: { "2": { totals: { inclusive: { request_currency: { value: "129.00", currency: "USD" } } } } } }] }] }]);
    }
    return json({ "7": { name: "Hampton Inn", location: { coordinates: { latitude: 39.5, longitude: -119.8 } } } });
  });
  return new LodgingService(new ExpediaRapidClient({ apiKey: "k", sharedSecret: "s", baseUrl: "https://test.ean.com" }, fetch));
}

function fuelService(): FuelPriceService {
  return new FuelPriceService(new EiaClient("k", fakeFetch(() => json({ response: { data: [{ period: "2026-11-09", value: 3.879 }] } }))));
}

describe("gateway HTTP API", () => {
  it("serves an unauthenticated health check", async () => {
    app = await buildServer({ config });
    const response = await app.inject({ method: "GET", url: "/healthz" });
    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({ status: "ok" });
  });

  it("rejects requests without a valid app token", async () => {
    app = await buildServer({ config, fuel: fuelService() });
    const missing = await app.inject({ method: "GET", url: "/v1/fuel/average?lat=1&lng=1" });
    expect(missing.statusCode).toBe(401);
    expect(missing.json().error.status).toBe("UNAUTHENTICATED");
    const wrong = await app.inject({ method: "GET", url: "/v1/fuel/average?lat=1&lng=1", headers: { "x-cadence-app-token": "nope" } });
    expect(wrong.statusCode).toBe(401);
  });

  it("returns lodging offers in the app's wire format", async () => {
    app = await buildServer({ config, lodging: lodgingService() });
    const response = await app.inject({
      method: "GET",
      url: "/v1/lodging/rates?lat=39.53&lng=-119.81&radiusKm=25.0&checkin=2027-05-03&checkout=2027-05-04&adults=2",
      headers: auth,
    });
    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({
      offers: [{
        propertyId: "7", name: "Hampton Inn", latitude: 39.5, longitude: -119.8, nightlyRate: 129, currency: "USD",
        provider: "Expedia", bookingUrl: "https://www.expedia.com/h7.Hotel-Information",
      }],
    });
  });

  it.each([
    ["missing coordinates", "/v1/lodging/rates?checkin=2027-05-03&checkout=2027-05-04"],
    ["checkout before checkin", "/v1/lodging/rates?lat=1&lng=1&checkin=2027-05-04&checkout=2027-05-03"],
    ["bad date format", "/v1/lodging/rates?lat=1&lng=1&checkin=05/03/2027&checkout=2027-05-04"],
    ["radius too large", "/v1/lodging/rates?lat=1&lng=1&radiusKm=500&checkin=2027-05-03&checkout=2027-05-04"],
    ["unknown fuel type", "/v1/fuel/average?lat=1&lng=1&fuelType=rocket"],
  ])("validates input: %s", async (_name, url) => {
    app = await buildServer({ config, lodging: lodgingService(), fuel: fuelService() });
    const response = await app.inject({ method: "GET", url, headers: auth });
    expect(response.statusCode).toBe(400);
    expect(response.json().error.status).toBe("INVALID_ARGUMENT");
  });

  it("returns regional fuel averages", async () => {
    app = await buildServer({ config, fuel: fuelService() });
    const response = await app.inject({ method: "GET", url: "/v1/fuel/average?lat=37.7&lng=-122.4&fuelType=diesel", headers: auth });
    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({ pricePerGallon: 3.879, region: "California", period: "2026-11-09", source: "EIA" });
  });

  it("answers 503 when a provider is not configured, 502 when it fails", async () => {
    app = await buildServer({ config, lodging: lodgingService(true) });
    const unconfigured = await app.inject({ method: "GET", url: "/v1/fuel/average?lat=1&lng=1", headers: auth });
    expect(unconfigured.statusCode).toBe(503);
    const failing = await app.inject({
      method: "GET", url: "/v1/lodging/rates?lat=1&lng=1&checkin=2027-05-03&checkout=2027-05-04", headers: auth,
    });
    expect(failing.statusCode).toBe(502);
    expect(failing.json().error.message).toBe("Expedia is unavailable");
    expect(new UpstreamError("Expedia", 500, "x").message).toContain("500");
  });

  it("rate-limits per client", async () => {
    app = await buildServer({ config: { ...config, rateLimitPerMinute: 2 }, fuel: fuelService() });
    const statuses: number[] = [];
    for (let index = 0; index < 3; index += 1) {
      statuses.push((await app.inject({ method: "GET", url: "/v1/fuel/average?lat=1&lng=1", headers: auth })).statusCode);
    }
    expect(statuses).toEqual([200, 200, 429]);
  });
});

describe("configuration", () => {
  it("parses tokens and optional providers", () => {
    const parsed = loadConfig({ APP_TOKENS: `${TEST_TOKEN}, second-token-abcdefghij`, EIA_API_KEY: "eia", PORT: "9000" });
    expect(parsed.appTokens).toEqual([TEST_TOKEN, "second-token-abcdefghij"]);
    expect(parsed.port).toBe(9000);
    expect(parsed.eiaApiKey).toBe("eia");
    expect(parsed.expedia).toBeUndefined();
  });

  it("requires both Expedia credentials", () => {
    expect(loadConfig({ APP_TOKENS: TEST_TOKEN, EXPEDIA_API_KEY: "k" }).expedia).toBeUndefined();
    expect(loadConfig({ APP_TOKENS: TEST_TOKEN, EXPEDIA_API_KEY: "k", EXPEDIA_SHARED_SECRET: "s" }).expedia?.baseUrl).toBe("https://test.ean.com");
  });

  it("rejects missing or weak tokens", () => {
    expect(() => loadConfig({})).toThrow(/APP_TOKENS/);
    expect(() => loadConfig({ APP_TOKENS: "short" })).toThrow(/at least 16/);
  });
});
