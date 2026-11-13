# Testing

Cadence is developed test-first: a behaviour gets a failing test, then the code that makes it
pass. Tests run on every push (git hook) and every pull request (CI), and **every run is logged**
in [`test-logs/TEST_LOG.md`](../test-logs/TEST_LOG.md).

## Test pyramid

| Level | Where | Framework | What it covers | Runs on |
|---|---|---|---|---|
| Unit — core | `Packages/CadenceKit/Tests/*` | Swift Testing | geometry, polyline codec, models, route profile, candidate builder, optimizer, feasibility ladder, validator, retimer, lodging windows, guidance engine, trip state machine, persistence, formatters, deep links | Linux, macOS, iOS simulator |
| Unit — API adapters | `TripServicesTests` | Swift Testing + JSON fixtures | request encoding (headers, field masks, bodies), response decoding, error mapping, retries for Routes API, Places API (New), gateway | same |
| Unit — view models (UI features) | `TripFeaturesTests` | Swift Testing | every screen's logic: planning form, autocomplete, validation, plan comparison, timeline, drive mode (route preview, route line from the car, directions from the car, arrival, next stop, skip, reroute, mute, auto-departure, completion, auto-save, resume), settings | same |
| Property | `PlannerPropertyTests` | Swift Testing | 24 random scenarios: every plan satisfies all safety rules | same |
| Integration | `IntegrationTests` | Swift Testing | full planning through the **production** Google/gateway adapters against the in-process `SimulatedGoogleBackend` (cross-country, short trip, custom breaks, impossible deadline, degraded services, failures) | same |
| Unit — app shell | `AppTests` | Swift Testing | configuration, composition root modes, CoreLocation mapping, design tokens, marker icons, component rendering (`ImageRenderer`) | iOS simulator |
| UI (sandbox) | `AppUITests` | XCUITest | plan flow, validation, plan comparison, drive → arrive → continue → route preview → start, exit and resume, resume after relaunch, end trip, settings persistence, App Store screenshots | iOS simulator |
| Gateway | `Backend/gateway/test` | Vitest | Expedia signature (independent vector), Rapid client, lodging service, EIA client, PADD mapping, cache, HTTP API (auth, validation, errors, rate limit), config | Node 22 |

Current counts: **203** core tests (33 suites, more with parameterized cases), **66** gateway
tests, **21** app unit tests, **8** UI tests + 2 screenshot tests (light and dark).

## Running tests

```bash
make test            # everything available on this machine
make test-quick      # core + gateway (pre-push hook)
make test-core       # swift test (Linux or macOS)
make test-gateway    # npm lint, typecheck, vitest
make test-ios        # xcodebuild: package tests on iOS, app unit tests, UI tests (macOS)
```

All targets call `scripts/test-all.sh`, which:

1. runs the requested suites,
2. appends one row per suite to `test-logs/TEST_LOG.md` (time, commit, result, test count,
   duration),
3. writes `test-logs/runs/<timestamp>.md` with the failing tests' names and messages,
4. keeps full console output, JUnit XML and `.xcresult` bundles in `test-logs/raw/` (git-ignored,
   uploaded as CI artifacts),
5. exits non-zero if anything failed.

## Running tests automatically

* **Pre-push hook** (`scripts/install-git-hooks.sh`, run by `make bootstrap`): the quick suites
  must pass before anything is pushed.
* **CI** (`.github/workflows/ci.yml`): Linux core tests, gateway tests, and on macOS SwiftLint,
  iOS package tests, app tests and UI tests — on every push and pull request.
* **Release** workflow runs the iOS suite again before uploading a build.

## Sandbox mode (UI tests, previews, demo)

Launch argument `-UITestSandbox` builds the app on `TripSandbox`:

* `SimulatedGoogleBackend` — an `HTTPTransport` that speaks the Routes API, Places API (New) and
  gateway wire formats, so the **production adapters** run unchanged;
* `SimulatedLocationProvider` — drives each planned leg at high speed;
* isolated on-disk storage, reset with `-ResetState`; `-SkipSafetyNotice` for screenshots.

Everything is deterministic (seeded generators), so UI tests are stable and need no network.

## Writing tests

* Prefer testing behaviour through public APIs; use `@testable` only for internal helpers.
* New planner features need a unit test **and** must keep the property tests green.
* New API fields need a fixture under `Tests/TripServicesTests/Fixtures`.
* New screens get view-model tests first; add a UI test for the critical path.
* Use accessibility identifiers from `App/Sources/Support/AccessibilityID.swift` (shared with
  the UI-test target).
