# Cadence — Road Trip Planner for iOS

Cadence plans long car trips the way an experienced road-tripper would, then guides the
driver there with turn-by-turn directions on Google Maps.

**Input:** start, destination, departure time, the car's MPG, and optionally an arrive-by time
and a custom "drive before resting" interval.
**Output:** a feasible, optimized itinerary — where to rest, refuel and sleep, with the driving
directions between every stop — for three objectives: **fastest**, **cheapest** and **balanced**.

| | |
|---|---|
| Safety first | A break at least every 2–3 h of non-stop driving by default (or the user's interval). Never relaxed. |
| Feasibility before optimality | Deadlines and daily limits are satisfied first; preferences are relaxed step by step (and reported) only when needed. |
| Optimal stops | Resource-constrained label-setting search over real gas stations (live prices), rest areas and hotels (live Expedia rates). |
| Drive mode | Voice-guided turn-by-turn, off-route rerouting, arrival detection, one-tap "Continue to next stop". |
| Auto-saved | Progress persists after every change; trips resume after relaunch or reboot. |

## Repository layout

```
App/                    SwiftUI app shell (views, Google Maps view, CoreLocation, speech)
AppTests/               App-layer unit tests (Swift Testing)
AppUITests/             XCUITest end-to-end and screenshot tests
Packages/CadenceKit/    Platform-independent core (builds and tests on macOS, iOS and Linux)
  Sources/TripModels      Domain model, geometry, polyline codec
  Sources/TripPlanner     Route profile, candidate stops, optimizer, feasibility ladder, planning service, ports
  Sources/TripServices    Google Routes API v2, Places API (New), Cadence gateway adapters
  Sources/TripNavigation  Turn-by-turn guidance engine, trip progress state machine
  Sources/TripPersistence Auto-saved trips and preferences
  Sources/TripFeatures    Observable view models (all screen logic)
  Sources/TripSandbox     Offline simulated Google backend, GPS, fixtures (tests, previews, UI tests)
Backend/gateway/        TypeScript service holding Expedia Rapid and EIA credentials
fastlane/               TestFlight / App Store automation and store metadata
scripts/                Test runner with logging, icon generator, git hooks
test-logs/              History of every test run
docs/                   Architecture, algorithm, testing, release, keys, privacy, security
```

## Quick start (macOS, Xcode 26+)

```bash
make bootstrap        # tools, git hooks, Config/Secrets.xcconfig, Xcode project
open Cadence.xcodeproj
```

Without an API key the app runs in **demo mode** on offline data, so it builds and runs out
of the box. For real trips add the keys described in [docs/API_KEYS.md](docs/API_KEYS.md) to
`Config/Secrets.xcconfig` (git-ignored).

## Testing

```bash
make test             # every suite available on this machine → test-logs/
make test-quick       # Swift core + gateway (runs automatically before each git push)
```

Unit tests cover every model, algorithm, API adapter and view model. Integration tests run the
production Google/gateway adapters end-to-end against an in-process simulated backend.
XCUITests drive the real app in an offline sandbox. Every run is recorded in
[`test-logs/TEST_LOG.md`](test-logs/TEST_LOG.md). See [docs/TESTING.md](docs/TESTING.md).

## Shipping

See [docs/APP_STORE_RELEASE.md](docs/APP_STORE_RELEASE.md): `make screenshots`, `make beta`
(TestFlight), `make release` (App Store submission), or the manual *Release* GitHub workflow.

## Third-party services

| Service | Used for | Where |
|---|---|---|
| Google Maps SDK for iOS | Map rendering (Apple Maps is used when no Google key is configured) | App |
| Google Routes API (v2) | Routes, alternatives, tolls, turn-by-turn steps, rerouting | App → Google |
| Google Places API (New) | Autocomplete, place details, search along route, live fuel prices | App → Google |
| Expedia Rapid API | Live hotel rates near each night's stop | App → Gateway → Expedia |
| U.S. EIA Open Data | Regional average fuel price fallback | App → Gateway → EIA |
| Google Maps / Expedia / Google hotel links | Hand-off for booking and navigation | Deep links |

## Documentation

* [Try it on your iPhone (Appetize / TestFlight)](docs/TRY_ON_IPHONE.md)
* [Architecture & decisions](docs/ARCHITECTURE.md)
* [Planning algorithm](docs/PLANNING_ALGORITHM.md)
* [Testing strategy](docs/TESTING.md)
* [API keys & services setup](docs/API_KEYS.md)
* [App Store release checklist](docs/APP_STORE_RELEASE.md)
* [Security](docs/SECURITY.md) · [Privacy policy](docs/PRIVACY_POLICY.md) · [Support](docs/SUPPORT.md)
* [Contributing](CONTRIBUTING.md) · [Changelog](CHANGELOG.md)
