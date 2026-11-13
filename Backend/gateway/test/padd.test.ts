import { describe, expect, it } from "vitest";

import { regionFor } from "../src/eia/padd.js";

describe("EIA price region mapping", () => {
  it.each([
    ["Los Angeles", 34.05, -118.24, "SCA"],
    ["San Francisco", 37.77, -122.42, "SCA"],
    ["Lake Tahoe (CA side)", 38.94, -119.98, "SCA"],
    ["Las Vegas", 36.17, -115.14, "R50"],
    ["Reno", 39.53, -119.81, "R50"],
    ["Seattle", 47.61, -122.33, "R50"],
    ["Portland", 45.52, -122.68, "R50"],
    ["Phoenix", 33.45, -112.07, "R50"],
    ["Anchorage", 61.22, -149.9, "R50"],
    ["Honolulu", 21.31, -157.86, "R50"],
    ["Boise", 43.62, -116.2, "R40"],
    ["Salt Lake City", 40.76, -111.89, "R40"],
    ["Denver", 39.74, -104.99, "R40"],
    ["Cheyenne", 41.14, -104.82, "R40"],
    ["Albuquerque", 35.08, -106.65, "R30"],
    ["Dallas", 32.78, -96.8, "R30"],
    ["Amarillo", 35.22, -101.83, "R30"],
    ["New Orleans", 29.95, -90.07, "R30"],
    ["Little Rock", 34.75, -92.29, "R30"],
    ["Birmingham", 33.52, -86.8, "R30"],
    ["Oklahoma City", 35.47, -97.52, "R20"],
    ["Kansas City", 39.1, -94.58, "R20"],
    ["Chicago", 41.88, -87.63, "R20"],
    ["Columbus OH", 39.96, -83.0, "R20"],
    ["Nashville", 36.16, -86.78, "R20"],
    ["Minneapolis", 44.98, -93.27, "R20"],
    ["New York", 40.71, -74.01, "R10"],
    ["Atlanta", 33.75, -84.39, "R10"],
    ["Miami", 25.76, -80.19, "R10"],
    ["Richmond VA", 37.54, -77.44, "R10"],
    ["Charleston WV", 38.35, -81.63, "R10"],
    ["Mexico City", 19.43, -99.13, "NUS"],
    ["Toronto", 43.65, -79.38, "R10"],
  ])("%s → %s", (_name, lat, lng, expected) => {
    expect(regionFor(lat, lng).code).toBe(expected);
  });
});
