# Waystage — Road Trip Planner for iOS

Waystage plans long car trips the way an experienced road-tripper would, then guides the
driver there stop by stop with Google's turn-by-turn navigation, on the iPhone and on CarPlay.

**Input:** start, destination, departure time, the car's MPG, tank size and fuel grade (any
gasoline by default, or a specific grade with its ethanol level: Regular 87 · E10, Midgrade 89 ·
E10, Premium 91+ · E10, Flex fuel · E85, Diesel), and optionally an arrive-by time and a custom
"drive before resting" interval. Fuel stops are always stations that sell the chosen grade.
**Output:** a feasible, optimized itinerary — where to rest, refuel and sleep, with the driving
directions between every stop — for three objectives: **fastest**, **cheapest** and **balanced**.

| | |
|---|---|
| Safety first | A break at least every 2–3 h of non-stop driving by default (or the user's interval). Never relaxed. |
| Feasibility before optimality | Deadlines and daily limits are satisfied first; preferences are relaxed step by step (and reported) only when needed. |
| Route choices | Up to three noticeably different, reasonable routes (the provider's alternatives plus routes through highway hubs off them), each fully planned and tagged with its travel time on the map; only the one chosen is saved. |
| Optimal stops | Resource-constrained label-setting search over real gas stations (live prices), rest areas and hotels (live Expedia rates). |
| Drive mode | Each leg (starting, resuming, continuing from a stop) opens as a preview with a Start button; Google's Navigation SDK then guides it (turn header, lanes, voice, rerouting, arrival) while Waystage keeps the trip: the next stop, time left, "Continue to next stop", skipping a stop. |
| CarPlay | The same drive on the car's screen: trips list, leg previews, Google's maneuvers and voice, Continue at stops. |
| Google's rules | Only place IDs are kept long-term (coordinates for 30 days); names are fetched again when a trip is opened. See [docs/COMPLIANCE.md](docs/COMPLIANCE.md). |
| Auto-saved | Progress persists after every change; trips resume after relaunch or reboot. |

## Repository layout

```
App/                    SwiftUI app shell (views, Google maps and navigation, CarPlay, CoreLocation)
AppTests/               App-layer unit tests (Swift Testing)
AppUITests/             XCUITest end-to-end and screenshot tests
Packages/WaystageKit/    Platform-independent core (builds and tests on macOS, iOS and Linux)
  Sources/TripModels      Domain model, geometry, polyline codec
  Sources/TripPlanner     Route profile, candidate stops, optimizer, feasibility ladder, planning service, ports
  Sources/TripServices    Google Routes API v2, Places API (New), Waystage gateway adapters
  Sources/TripNavigation  Trip progress state machine; guidance engine for the offline simulation
  Sources/TripPersistence Auto-saved trips and preferences
  Sources/TripFeatures    Observable view models (all screen logic)
  Sources/TripSandbox     Offline simulated Google backend, GPS, fixtures (tests, previews, UI tests)
Backend/gateway/        TypeScript service holding Expedia Rapid and EIA credentials
fastlane/               TestFlight / App Store automation and store metadata
scripts/                Test runner with logging, icon generator, git hooks
test-logs/              History of every test run
docs/                   Architecture, algorithm, testing, release, keys, CarPlay, compliance, privacy, security
```

## Quick start (macOS, Xcode 27)

```bash
make bootstrap        # tools, git hooks, Config/Secrets.xcconfig, Xcode project
open Waystage.xcodeproj
```

Xcode 26 still builds and runs it, but from April 2027 the App Store only accepts apps built with
Xcode 27 or later (iOS 27 SDK); releases are built on GitHub with Xcode 27.

Without an API key the app runs in **demo mode** on offline data, so it builds and runs out
of the box. For real trips, see [docs/API_KEYS.md](docs/API_KEYS.md): keys are saved as GitHub
Actions secrets (builds on GitHub need no Mac), or, on your own Mac, in the git-ignored
`Config/Secrets.xcconfig`.

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

See [docs/APP_STORE_RELEASE.md](docs/APP_STORE_RELEASE.md). The manual *Release* GitHub workflow has
one lane per App Store Connect step (`upload_build`, `create_version`, `update_version`,
`submit_for_review`) and `release_all` for all of them; *Signing* creates or renews the signing
certificate and profile. On a Mac, `make` runs the same lanes (`make help`).

## Third-party services

| Service | Used for | Where |
|---|---|---|
| Google Maps SDK for iOS | Maps, on the iPhone and CarPlay (Apple Maps is used when no Google key is configured) | App |
| Google Navigation SDK for iOS | Turn-by-turn navigation: routes from the phone, guidance, voice, rerouting, arrival; CarPlay's maneuvers | App → Google |
| Google Routes API (v2) | Planning: routes, alternatives, tolls, directions through the chosen stops | App → Google |
| Google Places API (New) | Autocomplete, search along the route, live fuel prices, names of saved trips' places by place ID | App → Google |
| Expedia Rapid API | Live hotel rates near each night's stop | App → Gateway → Expedia |
| U.S. EIA Open Data | Regional average fuel price fallback | App → Gateway → EIA |
| Google Maps / Expedia / Google hotel links | Hand-off for booking and navigation | Deep links |

## Documentation

* [Try it on your iPhone (TestFlight)](docs/TRY_ON_IPHONE.md)
* [Architecture & decisions](docs/ARCHITECTURE.md)
* [Planning algorithm](docs/PLANNING_ALGORITHM.md)
* [Testing strategy](docs/TESTING.md)
* [API keys & services setup](docs/API_KEYS.md)
* [App Store release](docs/APP_STORE_RELEASE.md) · [CarPlay](docs/CARPLAY.md) · [Google and Apple rules (compliance)](docs/COMPLIANCE.md)
* [Security](docs/SECURITY.md) · [Privacy policy](docs/PRIVACY_POLICY.md) · [Terms of Use](docs/TERMS_OF_USE.md) · [Support](docs/SUPPORT.md)
* [Contributing](CONTRIBUTING.md) · [Changelog](CHANGELOG.md)
