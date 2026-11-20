# App Store release

How Waystage gets from this repository to the App Store, for reference. Everything builds on
GitHub's Mac machines, so no Mac is needed. They use Xcode 27 (GitHub's `xcode-27` machines):
from April 2027 Apple only accepts uploads built with the iOS 27 SDK or later (App Store Connect
warns with ITMS-90725 about builds made with an older one). When GitHub ships a newer Xcode on
another machine, change `runs-on` in `ci.yml`, `release.yml` and `screenshots.yml` together.

## One-time setup

1. **Apple Developer Program** membership.
2. **App ID** (Certificates, IDs & Profiles → Identifiers) for the bundle ID, with the
   **CarPlay Navigation** capability turned on once Apple has granted it. Background location and
   audio need no capability: they're declared in `Info.plist`.
3. **App in App Store Connect** with that bundle ID. The name must match
   `fastlane/metadata/en-US/name.txt` ("Waystage: Road Trip Planner"), or the first upload renames
   it; the name under the icon is "Waystage" either way. fastlane uploads the categories
   (Navigation, then Travel).
4. **Website** (privacy policy, support, terms) at https://lenhat509.github.io/RoadPlanner/. The
   **Website** workflow republishes it whenever [PRIVACY_POLICY.md](PRIVACY_POLICY.md),
   [SUPPORT.md](SUPPORT.md), [TERMS_OF_USE.md](TERMS_OF_USE.md) or `site/site.json` change.
5. **Google Cloud project** with billing, the four APIs enabled (Maps SDK for iOS, Navigation SDK,
   Routes API, Places API (New)), and a key restricted to the bundle ID and those four APIs, with
   quotas and a budget alert. See [API_KEYS.md](API_KEYS.md).
6. **GitHub secrets and variables** for the Release workflow
   ([TRY_ON_IPHONE.md](TRY_ON_IPHONE.md#github-secrets-and-variables)), including the optional
   `WAYSTAGE_COMPANY_NAME` variable: the legal name on the Google Maps Platform account, shown in
   Google's navigation terms dialog (default "Waystage").
7. **Signing**: the first **Actions → Release** run, lane `beta`, with **create_certificates**
   ticked creates the certificate and profile (stored encrypted in the certificates repository).
   After turning on a capability for the App ID (CarPlay), run it once with **refresh_profile**
   ticked for a new profile; `beta` stops with an explanation if the profile lacks CarPlay. See
   [CARPLAY.md](CARPLAY.md).
8. **App Store Connect**, besides what fastlane uploads:
   * **App Review Information** on the version page: your name, phone and email. Only Apple sees
     it, so it isn't kept in this public repository; fastlane uploads the review notes and leaves
     the contact as you set it.
   * **App Privacy**: as in [the next section](#app-privacy-nutrition-label-answers).
   * **Pricing and Availability**: Free. Prices, fuel grades and units are for the US, so the
     United States.
9. **Optional, any time: the gateway** (`Backend/gateway/README.md`): live hotel rates (Expedia
   Rapid, which needs partner approval) and regional fuel averages (EIA). Without it the app shows
   clearly marked estimates; nothing in the release steps requires it.
10. **Legal review** of the points under [Legal and disclaimers](#legal-and-disclaimers) and the
    open questions in [COMPLIANCE.md](COMPLIANCE.md#open-questions-for-a-lawyer-or-google-maps-platform-sales).

## App Privacy ("nutrition label") answers

Waystage's own data (`App/Resources/PrivacyInfo.xcprivacy`) plus what Google's Navigation SDK
declares in its privacy manifest (`GoogleNavigation.bundle/PrivacyInfo.xcprivacy`, 11.3.0). App
Store Connect asks about everything the app *and its SDKs* collect, so answer:

| Data | Collected | Linked to user | Tracking | Purposes |
|---|---|---|---|---|
| Precise location | Yes (Google: routing, places, navigation) | Yes (the Navigation SDK links it) | No | App functionality, Analytics |
| Search history (place queries) | Yes (Google Places) | No | No | App functionality |
| Device ID | Yes (Navigation SDK) | Yes | No | App functionality, Analytics |
| Crash data | Yes (Navigation SDK) | No | No | App functionality, Analytics |
| Performance data | Yes (Navigation SDK) | No | No | Analytics |
| Product interaction | Yes (Navigation SDK) | No | No | Analytics |
| Other data types | Yes (Navigation SDK) | Yes | No | Analytics |
| Everything else | No | — | — | — |

Check the manifest again when the SDK is updated. Waystage adds no accounts, analytics,
advertising or tracking SDKs of its own; the privacy policy explains what the Navigation SDK
sends to Google.

In App Store Connect: the app → **App Privacy** → **Get Started** (or **Edit** next to the data
types) → "Yes, we collect data from this app" → tick the data types above → **Save**. Then
**Set Up** each one: its purposes, whether it's linked to the user, whether it's used for
tracking (as in the table). Finish with **Publish**. The answers cover the whole app, not a
version, and appear on the store page as soon as they're published.

## Review notes

`fastlane/metadata/review_information/notes.txt` (uploaded by the `release` lane) explains the
flow, Google's navigation terms before the first drive, how to try CarPlay, and why background
location is used (voice guidance during an active trip, also while shown on CarPlay). Background
modes declared: `location`, `audio`. Export compliance: `ITSAppUsesNonExemptEncryption = NO`
(HTTPS only).

## Each release

1. Update `CHANGELOG.md`, `MARKETING_VERSION` in `project.yml`, and
   `fastlane/metadata/en-US/release_notes.txt`, and push to `main`.
2. Wait for the **CI** workflow to pass (every test suite, including the UI tests).
3. **Actions → Release**, lane `beta`. Test the TestFlight build on your iPhone with a passenger
   operating the phone: planning, Google's navigation with the screen locked, arrival at a stop,
   "Continue to next stop", resume after force-quitting, rerouting; and CarPlay (see
   [CARPLAY.md](CARPLAY.md#testing)), which no automated test covers.
4. If the Navigation SDK version changed, check its privacy manifest against
   [App Privacy](#app-privacy-nutrition-label-answers) and update the answers in App Store
   Connect (Apple's API can't).
5. **Screenshots**, the first time and when the app looks different: take them on your iPhone with
   the TestFlight build, planning a real trip (real Google routes, places and prices), and upload
   them in App Store Connect → the version → **Previews and Screenshots** (see below). Otherwise
   the previous version's carry over.
6. **Actions → Release**, lane `release`, with **submit_for_review** ticked. It creates the
   version in App Store Connect if needed, uploads the listing, What's New, review notes and age
   rating, waits until Apple has processed the version's newest build, selects it and submits it
   for review. The version is released automatically once approved. Without
   **submit_for_review** it stops after the upload, and you submit in App Store Connect (select
   the build, **Submit for Review**).

## Screenshots

Taken by hand on a real iPhone, with real data: the offline UI-test sandbox (made-up places,
simplified routes) is for checking the design, not for the store (guideline 2.3.3: screenshots
show the app in use).

* Up to 10; the first 2–3 matter most. A good set: the plan form, the route choices on the map,
  a plan's timeline with its stops, a stop's details, and the drive screen.
* Press the side button and volume up together. Hide personal things first (your home address,
  notifications); a full battery and good signal look tidier.
* Drive-screen shots: parked, or by a passenger. Never while driving.
* Sizes: the main slot ("iPhone with Dynamic Island, medium display") takes 1179 × 2556 or
  1206 × 2622, what an iPhone 14 Pro, 15, 15 Pro, 16, 16 Pro, 17 or 17 Pro produces. Pro Max
  and Plus models produce the larger size, which goes in the 6.9-inch slot under **View All Sizes
  in Media Manager**; the store scales down from it.

## App previews (optional videos)

15–30 seconds each, up to 3, 886 × 1920 for the main iPhone slot. Record the real app on your
iPhone (Control Center → Screen Recording), then cut it with captions:

```bash
python3 scripts/make_app_preview.py fastlane/app_previews/plan-and-drive.json recording.mp4 preview-1.mp4
```

Each JSON file lists the parts of the recording to use, their speed and caption, and how much to crop
off the top (the status bar, recording indicator and AssistiveTouch button aren't part of the app).
Leave out street-level close-ups near home: previews are public. Upload in App Store Connect → the
version → **Previews and Screenshots**.

## Guideline notes

* **2.5.4 background modes** — location is used only during active navigation, as the review
  notes state; the blue location indicator is shown.
* **5.1.1 data collection** — location permission is requested in context (current location /
  drive start), with purpose strings in `Info.plist`.
* **1.4 physical harm / safety** — first launch asks people to agree to "Before you start" (plans
  come from Google Maps data and can be wrong, nothing is booked, costs are estimates, you're the
  driver, directions can differ from the road, made for cars), then shows Google's navigation
  terms; the first drive shows a safety notice; drive mode needs at most one tap per stop.
* **CarPlay** — a navigation app under the CarPlay App Programming Guide: map-only base view,
  turn-by-turn with upcoming maneuvers, a pan button, guidance stops at once when CarPlay cancels
  it, no flow needs the iPhone, nothing asks the driver to pick it up (see [CARPLAY.md](CARPLAY.md)).
* **Maps attribution** — Google logo and legal notices are shown by the Maps SDK; stop details,
  which show Places data without a map, say "Place information from Google Maps".

## Legal and disclaimers

What the app does (see `Disclosures` in `TripFeatures`, the single source of all wording):

* **First launch: "Before you start".** Seven points, a link to the full Terms of Use, Google Maps'
  terms and both privacy policies, and *Agree and continue*. Acceptance is stored with the terms
  version (`Disclosures.termsVersion`); bump it whenever the terms change and everyone is asked
  again.
* **Terms of Use** in the app (Settings › Terms of Use) and in
  [`TERMS_OF_USE.md`](TERMS_OF_USE.md) for the website; a test keeps the two identical. Publish the
  page and link it in App Store Connect (the standard Apple EULA still applies unless you upload a
  custom one).
* **Where it matters:** results ("estimated … can differ; hotels in this plan aren't booked"),
  every hotel stop ("not booked", check availability and the total price on the hotel's site or
  by phone), fuel stops (reported prices/grades may have changed; check opening hours), roadside
  breaks (stop only where legal and safe), and the drive safety notice.

Before release, have a lawyer review the following, which the app can't settle on its own:

1. **The Terms of Use**: governing law, the legal entity named as provider, contact details, and
   whether a custom EULA should replace Apple's.
2. **Google Maps Platform terms**: end users must be bound by terms consistent with Google's,
   including the [Google Maps/Google Earth Additional Terms of Service](https://maps.google.com/help/terms_maps/)
   (done in the agreement). Navigation, storage and the Navigation SDK's conditions are handled as
   described in [COMPLIANCE.md](COMPLIANCE.md); its open questions (commercial use, CarPlay,
   the company name in Google's dialog, derived plan data) are for the lawyer.
3. **Hotel prices**: if Expedia Rapid is used under its launch requirements, its rules for showing
   rates (taxes and fees lines) apply. The FTC's rule on unfair or deceptive fees (in force since
   May 2025) covers how short-term lodging prices are displayed in the US; the app labels rates as
   estimates and says taxes and fees can apply, but check this with counsel.
4. **Affiliate links**: if booking links earn a commission, disclose that next to them.
