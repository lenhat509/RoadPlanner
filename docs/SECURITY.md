# Security

## Secrets

| Secret | Lives in | Never in |
|---|---|---|
| Google Maps API key | `Config/Secrets.xcconfig` → Info.plist (restricted to bundle ID + 3 APIs) | git |
| Gateway app token | `Config/Secrets.xcconfig`; gateway `APP_TOKENS` (Secret Manager) | git |
| Expedia API key/secret, EIA key | Gateway environment via Secret Manager | the app, git |
| App Store Connect key, match password | CI secrets | git |

The Google key is inherently extractable from any client app; its risk is limited by the iOS
bundle restriction, API restriction, quotas and budget alerts. Rotate it in Google Cloud if abused.

## Gateway hardening

* App token checked with constant-time comparison; multiple tokens enable rotation.
* Per-client rate limit; input validation with zod; generic error messages (no upstream details).
* Runs as non-root in a distroless image; no state besides short-lived caches.
* **Recommended next step:** require Firebase App Check (App Attest provider) tokens so only
  genuine app instances can call the gateway, and move the app token to remote config.

## Device data

Trips and preferences are stored in the app's Application Support directory (iOS Data
Protection applies). No personal data leaves the device except what is needed for routing and
pricing (see the privacy policy).

## Reporting

Report vulnerabilities privately to security@cadence.example.com (replace before publishing).
