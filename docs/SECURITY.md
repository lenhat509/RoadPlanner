# Security

## Secrets

| Secret | Lives in | Never in |
|---|---|---|
| Google Maps API key | GitHub Actions secret → the build on GitHub's temporary Mac → inside the app (restricted to bundle ID + 3 APIs) | git, workflow artifacts |
| Gateway app token | GitHub Actions secret → inside the app; gateway `APP_TOKENS` (Secret Manager) | git, workflow artifacts |
| Expedia API key/secret, EIA key | Gateway environment via Secret Manager | the app, git |
| App Store Connect key, match password | GitHub Actions secrets | git |

The build reads the key from `Config/Secrets.xcconfig`. On GitHub the Release workflow writes that
file on its temporary build machine, which is deleted after the job; it is git-ignored, so it is
never committed, and no workflow uploads a built app.

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

Report vulnerabilities privately to security@waystage.example.com (replace before publishing).
