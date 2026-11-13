import { describe, expect, it } from "vitest";

import { cheapestNightlyRate, ExpediaRapidClient, nightsBetween } from "../src/expedia/client.js";
import { bookingUrl, circleRing, LodgingService } from "../src/expedia/lodging.js";
import { UpstreamError } from "../src/http.js";
import { fakeFetch, json } from "./helpers.js";

const credentials = { apiKey: "key", sharedSecret: "secret", baseUrl: "https://test.ean.com" };

function availability(id: string, totals: number[], status = "available") {
  return {
    property_id: id,
    status,
    rooms: [
      {
        rates: totals.map((total) => ({
          available_rooms: 2,
          occupancy_pricing: { "2": { totals: { inclusive: { request_currency: { value: total.toFixed(2), currency: "USD" } } } } },
        })),
      },
    ],
  };
}

function rapidBackend() {
  return fakeFetch((url) => {
    if (url.pathname === "/v3/properties/geography") return json({ "100": {}, "200": {}, "300": {} });
    if (url.pathname === "/v3/properties/availability") {
      return json([availability("100", [260, 240]), availability("200", [180]), availability("300", [99], "unavailable")]);
    }
    if (url.pathname === "/v3/properties/content") {
      return json({
        "100": { name: "Hampton Inn Reno", location: { coordinates: { latitude: 39.53, longitude: -119.81 } } },
        "200": { name: "Motel Budget", location: { coordinates: { latitude: 39.5, longitude: -119.8 } } },
      });
    }
    return new Response("not found", { status: 404 });
  });
}

describe("ExpediaRapidClient", () => {
  it("signs every request and searches a GeoJSON polygon", async () => {
    const fetch = rapidBackend();
    const client = new ExpediaRapidClient(credentials, fetch, () => 1_700_000_000_000);
    const ids = await client.propertyIdsWithin(circleRing(39.5, -119.8, 10));
    expect(ids).toEqual(["100", "200", "300"]);
    const call = fetch.calls[0]!;
    expect(call.url.searchParams.get("include")).toBe("property_ids");
    expect(call.init?.method).toBe("POST");
    const headers = call.init?.headers as Record<string, string>;
    expect(headers.Authorization).toMatch(/^EAN APIKey=key,Signature=[0-9a-f]{128},timestamp=1700000000$/);
    const body = JSON.parse(String(call.init?.body));
    expect(body.type).toBe("Polygon");
    expect(body.coordinates[0][0]).toEqual(body.coordinates[0].at(-1)); // closed ring
  });

  it("requests availability with occupancy, dates and repeated property IDs", async () => {
    const fetch = rapidBackend();
    const rates = await new ExpediaRapidClient(credentials, fetch).availability({
      propertyIds: ["100", "200", "300"], checkin: "2027-05-03", checkout: "2027-05-05", adults: 2, customerIp: "203.0.113.9",
    });
    const url = fetch.calls[0]!.url;
    expect(url.searchParams.getAll("property_id")).toEqual(["100", "200", "300"]);
    expect(url.searchParams.get("occupancy")).toBe("2");
    expect(url.searchParams.get("sales_channel")).toBe("mobile_app");
    expect((fetch.calls[0]!.init?.headers as Record<string, string>)["Customer-Ip"]).toBe("203.0.113.9");
    // Two nights: cheapest total ÷ 2.
    expect(rates).toEqual([
      { propertyId: "100", nightlyRate: 120, currency: "USD" },
      { propertyId: "200", nightlyRate: 90, currency: "USD" },
    ]);
  });

  it("treats 404 as 'nothing available' and other failures as upstream errors", async () => {
    const empty = new ExpediaRapidClient(credentials, fakeFetch(() => new Response("", { status: 404 })));
    expect(await empty.availability({ propertyIds: ["1"], checkin: "2027-01-01", checkout: "2027-01-02", adults: 1, customerIp: "::1" })).toEqual([]);
    const broken = new ExpediaRapidClient(credentials, fakeFetch(() => new Response("bad", { status: 500 })));
    await expect(broken.content(["1"])).rejects.toBeInstanceOf(UpstreamError);
  });

  it("splits large property lists into batches of 250", async () => {
    const fetch = fakeFetch(() => json({}));
    await new ExpediaRapidClient(credentials, fetch).content(Array.from({ length: 600 }, (_, index) => String(index)));
    expect(fetch.calls.map((call) => call.url.searchParams.getAll("property_id").length)).toEqual([250, 250, 100]);
  });

  it("parses the cheapest available rate", () => {
    expect(cheapestNightlyRate(availability("9", [300, 150]), "2", 1)).toEqual({ propertyId: "9", nightlyRate: 150, currency: "USD" });
    expect(cheapestNightlyRate(availability("9", [100]), "3", 1)).toBeNull(); // different occupancy
    expect(cheapestNightlyRate({}, "2", 1)).toBeNull();
    expect(nightsBetween("2027-05-03", "2027-05-06")).toBe(3);
  });
});

describe("LodgingService", () => {
  it("joins rates with content, sorts by price and builds booking links", async () => {
    const fetch = rapidBackend();
    const service = new LodgingService(new ExpediaRapidClient(credentials, fetch));
    const offers = await service.ratesNear({
      lat: 39.53, lng: -119.81, radiusKm: 20, checkin: "2027-05-03", checkout: "2027-05-04", adults: 2, customerIp: "::1",
    });
    expect(offers.map((offer) => [offer.name, offer.nightlyRate])).toEqual([
      ["Motel Budget", 180],
      ["Hampton Inn Reno", 240],
    ]);
    expect(offers[0]!.provider).toBe("Expedia");
    expect(offers[0]!.bookingUrl).toBe("https://www.expedia.com/h200.Hotel-Information");
  });

  it("caches offers and property content", async () => {
    const fetch = rapidBackend();
    const service = new LodgingService(new ExpediaRapidClient(credentials, fetch));
    const query = { lat: 39.53, lng: -119.81, radiusKm: 20, checkin: "2027-05-03", checkout: "2027-05-04", adults: 2, customerIp: "::1" };
    await service.ratesNear(query);
    await service.ratesNear(query);
    expect(fetch.calls).toHaveLength(3); // geography + availability + content, once
  });

  it("builds a closed circle polygon of the requested radius", () => {
    const ring = circleRing(40, -100, 25, 8);
    expect(ring).toHaveLength(9);
    expect(ring[0]).toEqual(ring[8]);
    const [lng, lat] = ring[2]!; // 90° → due north
    expect(lng).toBeCloseTo(-100, 5);
    expect((lat - 40) * 111.32).toBeCloseTo(25, 1);
    expect(bookingUrl("12 3")).toBe("https://www.expedia.com/h12%203.Hotel-Information");
  });
});
