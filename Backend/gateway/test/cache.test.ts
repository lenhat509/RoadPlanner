import { describe, expect, it } from "vitest";

import { TtlCache } from "../src/cache.js";

describe("TtlCache", () => {
  it("expires entries after the TTL", () => {
    let now = 0;
    const cache = new TtlCache<number>(1_000, 10, () => now);
    cache.set("a", 1);
    expect(cache.get("a")).toBe(1);
    now = 1_000;
    expect(cache.get("a")).toBeUndefined();
  });

  it("evicts the least recently used entry when full", () => {
    const cache = new TtlCache<number>(60_000, 2);
    cache.set("a", 1);
    cache.set("b", 2);
    cache.get("a"); // a is now most recent
    cache.set("c", 3);
    expect(cache.get("b")).toBeUndefined();
    expect(cache.get("a")).toBe(1);
    expect(cache.size).toBe(2);
  });

  it("loads once and serves from cache afterwards", async () => {
    const cache = new TtlCache<string>(60_000);
    let loads = 0;
    const load = async () => {
      loads += 1;
      return "value";
    };
    expect(await cache.getOrLoad("k", load)).toBe("value");
    expect(await cache.getOrLoad("k", load)).toBe("value");
    expect(loads).toBe(1);
  });
});
