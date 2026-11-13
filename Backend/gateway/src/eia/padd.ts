/** EIA duoarea codes used for weekly retail gasoline/diesel prices. */
export interface PriceRegion {
  code: "NUS" | "R10" | "R20" | "R30" | "R40" | "R50" | "SCA";
  name: string;
}

export const REGIONS = {
  NUS: { code: "NUS", name: "U.S. average" },
  R10: { code: "R10", name: "East Coast (PADD 1)" },
  R20: { code: "R20", name: "Midwest (PADD 2)" },
  R30: { code: "R30", name: "Gulf Coast (PADD 3)" },
  R40: { code: "R40", name: "Rocky Mountain (PADD 4)" },
  R50: { code: "R50", name: "West Coast (PADD 5)" },
  SCA: { code: "SCA", name: "California" },
} as const satisfies Record<string, PriceRegion>;

type Box = [minLat: number, maxLat: number, minLng: number, maxLng: number];

function inside([minLat, maxLat, minLng, maxLng]: Box, lat: number, lng: number): boolean {
  return lat >= minLat && lat <= maxLat && lng >= minLng && lng <= maxLng;
}

/** California's eastern border: lng −120 north of 39°N, then a diagonal to the Colorado River. */
function inCalifornia(lat: number, lng: number): boolean {
  if (lat < 32.5 || lat > 42 || lng < -124.5) return false;
  if (lat >= 39) return lng <= -120;
  if (lat >= 35) return lng <= -120 + ((39 - lat) / 4) * 5.4; // (39, −120) → (35, −114.6)
  return lng <= -114.6;
}

/**
 * Approximate state → PADD mapping using state bounding boxes. Good enough for a fallback
 * price when a station has no live price; borders are only approximate.
 */
export function regionFor(lat: number, lng: number): PriceRegion {
  // Alaska and Hawaii are PADD 5.
  if (lat > 51 && lng < -129) return REGIONS.R50;
  if (inside([18, 23, -161, -154], lat, lng)) return REGIONS.R50;
  // Outside the contiguous U.S.
  if (!inside([24.3, 49.5, -125, -66.8], lat, lng)) return REGIONS.NUS;

  if (inCalifornia(lat, lng)) return REGIONS.SCA;
  // West Coast: WA, OR, NV, AZ.
  if (lat >= 42 && lng <= -116.9) return REGIONS.R50;
  if (inside([35, 42, -120, -114.04], lat, lng)) return REGIONS.R50;
  if (inside([31.3, 37, -114.8, -109.05], lat, lng)) return REGIONS.R50;
  // Rocky Mountain: ID, MT, WY, UT, CO.
  if (inside([42, 49, -117.3, -104.05], lat, lng)) return REGIONS.R40;
  if (inside([41, 45, -111.05, -104.05], lat, lng)) return REGIONS.R40;
  if (inside([37, 42, -114.05, -102.04], lat, lng)) return REGIONS.R40;
  // Gulf Coast: NM, TX, LA, MS, AL, AR.
  if (inside([31.3, 37, -109.05, -103], lat, lng)) return REGIONS.R30;
  if (inside([25.8, 36.5, -106.7, -100], lat, lng)) return REGIONS.R30; // TX west incl. panhandle
  if (inside([25.8, 33.8, -100, -93.5], lat, lng)) return REGIONS.R30; // TX east of 100°W (south of the Red River)
  if (inside([28.9, 33.02, -94.05, -88.8], lat, lng)) return REGIONS.R30; // LA
  if (inside([33, 36.5, -94.6, -89.65], lat, lng)) return REGIONS.R30; // AR
  if (inside([30.2, 35, -91.65, -84.9], lat, lng)) return REGIONS.R30; // MS, AL
  // East Coast: everything east of Ohio/Kentucky/Tennessee, plus the Southeast.
  if (lng >= -80.5) return REGIONS.R10;
  if (lat < 35 && lng > -84.9) return REGIONS.R10;
  if (lat >= 36.5 && lat < 40.6 && lng > -82.6) return REGIONS.R10; // WV, VA
  return REGIONS.R20;
}
