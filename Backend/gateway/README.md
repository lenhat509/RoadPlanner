# Cadence Gateway

A small, stateless HTTPS service that keeps third-party secrets off the phone.

| Endpoint | Purpose | Upstream |
|---|---|---|
| `GET /healthz` | Liveness probe (no auth) | — |
| `GET /v1/lodging/rates?lat&lng&radiusKm&checkin&checkout&adults` | Live nightly hotel rates near a point | Expedia Rapid API v3 (geography → availability → content) |
| `GET /v1/fuel/average?lat&lng&fuelType` | Regional average retail fuel price | U.S. EIA API v2 (weekly retail prices by PADD / California) |

The iOS app calls Google Maps Platform directly with a bundle-restricted key; only partner
APIs whose credentials must never ship in an app binary go through this gateway.

## Security

* Every request (except `/healthz`) must send `X-Cadence-App-Token` matching one of
  `APP_TOKENS` (constant-time comparison; several tokens allow rotation).
* Per-client rate limiting (`RATE_LIMIT_PER_MINUTE`).
* Errors use the `{"error": {"status", "message"}}` envelope and never leak upstream details.
* For stronger client attestation, put the service behind Firebase App Check / Apple App Attest
  (see `docs/SECURITY.md`).

## Run locally

```bash
npm ci
cp .env.example .env   # fill in values
npm run build && node --env-file=.env dist/index.js
```

## Test

```bash
npm test               # unit + HTTP integration tests (vitest, offline)
npm run lint && npm run typecheck
```

## Deploy (Google Cloud Run)

```bash
gcloud run deploy cadence-gateway --source . --region us-central1 \
  --set-secrets APP_TOKENS=cadence-app-tokens:latest,EXPEDIA_API_KEY=expedia-key:latest,EXPEDIA_SHARED_SECRET=expedia-secret:latest,EIA_API_KEY=eia-key:latest \
  --set-env-vars EXPEDIA_BASE_URL=https://api.ean.com --allow-unauthenticated
```

Store secrets in Secret Manager; never in the image or environment files in git.

## Behaviour without credentials

Each provider is optional. Without Expedia credentials `/v1/lodging/rates` answers `503` and
the app falls back to Google Places price levels (shown as estimates). Without an EIA key
`/v1/fuel/average` answers `503` and the app uses its national default price (also flagged).
