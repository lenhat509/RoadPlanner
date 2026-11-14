# API keys and services

**Where keys go:** in GitHub, under **Settings → Secrets and variables → Actions**. Never in a
file in this repository, an issue or a chat. The Release workflow hands them to the build on
GitHub's temporary Mac, and the build machine is deleted afterwards.

| Kind | Name | What | Needed for |
|---|---|---|---|
| Secret | `GOOGLE_MAPS_API_KEY` | Google Maps key ([section 1](#1-google-maps-platform-required)) | Real trips (without it the app runs in demo mode) |
| Variable | `WAYSTAGE_BUNDLE_ID` | Your bundle ID, e.g. `com.waystage.waystage` | Every build |
| Variable | `WAYSTAGE_TEAM_ID` | Your Apple Team ID | Every build |
| Secret | `WAYSTAGE_GATEWAY_URL` | Gateway address, e.g. `https://waystage-gateway-xxxx.a.run.app` ([section 2](#2-waystage-gateway-optional)) | Optional |
| Secret | `WAYSTAGE_GATEWAY_TOKEN` | One of the gateway's `APP_TOKENS` | Optional |
| Secrets | `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_CONTENT`, `MATCH_*` | Apple upload and signing ([section 3](#3-apple)) | TestFlight and App Store |

Secrets can't be read back once saved, not even by you; to change one, save a new value.

## 1. Google Maps Platform (required)

1. Create a Google Cloud project and enable billing.
2. Enable **Maps SDK for iOS**, **Routes API** and **Places API (New)**.
3. Create an API key and restrict it:
   * *Application restriction:* iOS apps → your bundle ID (e.g. `com.waystage.waystage`).
     The app sends `X-Ios-Bundle-Identifier` on web-service calls so the restriction applies.
   * *API restriction:* only the three APIs above.
4. Set daily quotas and a budget alert (Billing → Budgets).
5. Save the key as the `GOOGLE_MAPS_API_KEY` secret.

**Why restrictions matter:** an app that uses Google Maps has to carry the key inside it, so
anyone with the app could dig it out; that's true of every app using Google Maps. The
restrictions and quotas are what make a found key useless or cheap. Never publish builds made
with your real key anywhere (no workflow here does: Release sends the build straight to
TestFlight).

Typical cost per planned cross-country trip: one Routes request with alternatives, ~25–45 Places
Text Search (Enterprise SKU because of `fuelOptions`) requests and one Routes request for final
directions. Lodging is only searched where a night is likely, to keep costs down.

Attribution: the Maps SDK shows the Google logo; Places data is always displayed on a Google map
or with "Google" attribution in the stop details, as required by the Places policies.

## 2. Waystage gateway (optional)

A small server (`Backend/gateway`, see its README) for partner services whose keys must never be
inside the app: live hotel rates (Expedia Rapid) and regional fuel price averages (EIA). Without
it, hotel prices and missing fuel prices are estimates, clearly marked. Deploy it to Cloud Run,
then save `WAYSTAGE_GATEWAY_URL` and `WAYSTAGE_GATEWAY_TOKEN` as secrets. The `release` lane
currently requires them; TestFlight builds don't.

### Expedia Rapid (for live hotel rates)

Expedia Rapid requires an Expedia Group partner agreement:
https://developers.expediagroup.com/rapid. You'll receive an API key and shared secret; use
`https://test.ean.com` until certified, then `https://api.ean.com`. Configure them only on the
gateway (`EXPEDIA_API_KEY`, `EXPEDIA_SHARED_SECRET`, `EXPEDIA_BASE_URL`).

Without Expedia, Waystage still plans overnight stays using Google Places hotels with price-level
estimates (clearly marked) and offers "Compare rates on Expedia" and "Hotels nearby on Google"
links for booking.

### U.S. EIA (for regional fuel averages)

Register for a free key at https://www.eia.gov/opendata/register.php and set `EIA_API_KEY` on the
gateway. Used only when a gas station has no live price in Google Places.

## 3. Apple

Step by step in [TRY_ON_IPHONE.md](TRY_ON_IPHONE.md#testflight-on-your-iphone):

* Apple Developer Program membership and an App ID for your bundle ID (no capabilities needed).
* Variables `WAYSTAGE_BUNDLE_ID` and `WAYSTAGE_TEAM_ID`.
* An App Store Connect API key (Users and Access → Integrations), saved as the secrets
  `ASC_KEY_ID`, `ASC_ISSUER_ID` and `ASC_KEY_CONTENT` (base64 of the .p8 file).
* A private git repository where fastlane keeps the signing certificate, encrypted: secrets
  `MATCH_GIT_URL`, `MATCH_PASSWORD`, `MATCH_GIT_BASIC_AUTHORIZATION`.

## Building on your own Mac (optional)

Only if you ever build in Xcode yourself: `make secrets` creates `Config/Secrets.xcconfig` from
`Config/Secrets.example.xcconfig` for the same values. That file is git-ignored, so it stays on
your Mac and is never committed. Builds on GitHub don't use it.
