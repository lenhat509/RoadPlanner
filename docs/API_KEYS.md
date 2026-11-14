# API keys and services

All secrets go in `Config/Secrets.xcconfig` (git-ignored) for the app and in Secret Manager for
the gateway. Nothing secret is committed.

## 1. Google Maps Platform (required)

1. Create a Google Cloud project and enable billing.
2. Enable **Maps SDK for iOS**, **Routes API** and **Places API (New)**.
3. Create an API key and restrict it:
   * *Application restriction:* iOS apps → your bundle ID (e.g. `com.yourcompany.waystage`).
     The app sends `X-Ios-Bundle-Identifier` on web-service calls so the restriction applies.
   * *API restriction:* only the three APIs above.
4. Set quotas and a budget alert (Billing → Budgets). Typical cost per planned cross-country
   trip: one Routes request with alternatives, ~25–45 Places Text Search (Enterprise SKU because
   of `fuelOptions`) requests and one Routes request for final directions. Lodging is only
   searched where a night is likely to keep costs down.
5. Put the key in `Config/Secrets.xcconfig`:
   ```
   GOOGLE_MAPS_API_KEY = AIza...
   ```

Attribution: the Maps SDK shows the Google logo; Places data is always displayed on a Google map
or with "Google" attribution in the stop details, as required by the Places policies.

## 2. Waystage gateway (recommended)

Deploy `Backend/gateway` (see its README) to Cloud Run, then:

```
WAYSTAGE_GATEWAY_URL = https:/$()/waystage-gateway-xxxx.a.run.app
WAYSTAGE_GATEWAY_TOKEN = <one of APP_TOKENS>
```

(`$()` stops xcconfig treating `//` as a comment.)

### Expedia Rapid (optional, for live hotel rates)

Expedia Rapid requires an Expedia Group partner agreement:
https://developers.expediagroup.com/rapid. You'll receive an API key and shared secret; use
`https://test.ean.com` until certified, then `https://api.ean.com`. Configure them only on the
gateway (`EXPEDIA_API_KEY`, `EXPEDIA_SHARED_SECRET`, `EXPEDIA_BASE_URL`).

Without Expedia, Waystage still plans overnight stays using Google Places hotels with price-level
estimates (clearly marked) and offers "Compare rates on Expedia" and "Hotels nearby on Google"
links for booking.

### U.S. EIA (optional, for regional fuel averages)

Register for a free key at https://www.eia.gov/opendata/register.php and set `EIA_API_KEY` on the
gateway. Used only when a gas station has no live price in Google Places.

## 3. Apple

* Apple Developer Program membership, an App ID for your bundle ID.
* `WAYSTAGE_BUNDLE_ID` and `WAYSTAGE_TEAM_ID` in `Config/Secrets.xcconfig`.
* An App Store Connect API key (Users and Access → Integrations) for fastlane: `ASC_KEY_ID`,
  `ASC_ISSUER_ID`, `ASC_KEY_CONTENT` (base64 of the .p8).
* A private git repo for `fastlane match` certificates: `MATCH_GIT_URL`, `MATCH_PASSWORD`.
