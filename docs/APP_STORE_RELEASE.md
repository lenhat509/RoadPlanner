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
7. **Signing**: **Actions → Signing → Run workflow** creates the distribution certificate and the
   App Store profile (stored encrypted in the certificates repository). Run it again after
   turning on a capability for the App ID (as for CarPlay) and when the certificate expires
   (yearly); builds stop with a message pointing to it. See [CARPLAY.md](CARPLAY.md).
8. **App Store Connect**, besides what the Release workflow uploads:
   * **App Review Information** contact (name, phone, email): only Apple sees it, so it isn't in
     the repository. Either save it as the optional secrets `REVIEW_FIRST_NAME`,
     `REVIEW_LAST_NAME`, `REVIEW_PHONE` and `REVIEW_EMAIL` (uploaded with the version page), or
     set it in App Store Connect; missing secrets leave App Store Connect's values.
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

`fastlane/metadata/review_information/notes.txt` (uploaded with the version page) explains the
flow, Google's navigation terms before the first drive, how to try CarPlay, and why background
location is used (voice guidance during an active trip, also while shown on CarPlay). Background
modes declared: `location`, `audio`. Export compliance: `ITSAppUsesNonExemptEncryption = NO`
(HTTPS only).

## Release workflow

**Actions → Release → Run workflow**, then pick a lane: one per App Store Connect step, plus
`release_all` for all of them.

| Lane | App Store Connect step | Runs on |
|---|---|---|
| `upload_build` | Upload a build of `MARKETING_VERSION` to TestFlight | Mac |
| `create_version` | **+ Version** (Prepare for Submission), then `update_version` | Linux |
| `update_version` | The version page (App Previews and Screenshots, Promotional Text, Description, Keywords, Support URL, Marketing URL, Copyright, What's New, App Review Information, Version Release: automatically) and App Information (Name, Subtitle, Category, Age Rating, Privacy Policy URL), from the repository | Linux |
| `submit_for_review` | Choose the **Build** (the version's newest, or the one given), **Submit for Review** | Linux |
| `release_all` | `upload_build` → `create_version` if needed → `update_version` → `submit_for_review` with the new build | Mac |

Options: **run_tests** (before building; off by default), **version** (blank: `MARKETING_VERSION`,
or the version in Prepare for Submission for `submit_for_review`) and **build** (for
`submit_for_review`). An option a lane doesn't use stops the run with the reason.

The lanes stop early, with the reason, when App Store Connect wouldn't accept the step: a version
not higher than the last approved one, a different version already in progress (App Store Connect
keeps one; the lanes never rename it), or a version Waiting for Review.

**Uploaded from the repository:** `fastlane/metadata` (texts, App Review notes and demo account,
categories, copyright), `fastlane/app_rating_config.json` (Age Rating), `fastlane/app_store`
(screenshots and app previews; see its README), and the optional App Review contact secrets.
**Not possible from GitHub:** App Privacy, Pricing and Availability, Agreements, Tax and Banking,
and replies to App Review: those are done in App Store Connect.

## Each release

1. Update `CHANGELOG.md`, `MARKETING_VERSION` in `project.yml`, and
   `fastlane/metadata/en-US/release_notes.txt`, and push to `main`.
2. Wait for the **CI** workflow to pass (every test suite, including the UI tests).
3. If the Navigation SDK version changed, check its privacy manifest against
   [App Privacy](#app-privacy-nutrition-label-answers) and update the answers in App Store
   Connect (Apple's API can't).
4. **Screenshots and previews**, the first time and when the app looks different: take them on
   your iPhone with a TestFlight build, planning a real trip (real Google routes, places and
   prices), and commit them to `fastlane/app_store` (see below). Otherwise the previous version's
   carry over.
5. Either in one run, or step by step:
   * **One run:** lane `release_all`. It submits without a TestFlight test in between, so use it
     when the build was already tested (from an earlier `upload_build`) or for small changes.
   * **Step by step:** `upload_build`, then test the TestFlight build on your iPhone with a
     passenger operating the phone (planning, Google's navigation with the screen locked, arrival
     at a stop, "Continue to next stop", resume after force-quitting, rerouting, and CarPlay: see
     [CARPLAY.md](CARPLAY.md#testing)); then `create_version`, check the version page in App
     Store Connect, change files and run `update_version` as needed, and `submit_for_review`.

The version is released automatically once approved.

## Screenshots

From the real app with real data: the offline UI-test sandbox (made-up places, simplified routes)
is for checking the design, not for the store (guideline 2.3.3: screenshots show the app in use).

**The Promo workflow** (`.github/workflows/promo.yml`, run it from Actions) does it on an iPhone
Pro Max simulator with live Google data: `PromoCaptureTests` plans Denver → Salt Lake City → Las
Vegas → San Jose, adjusts its visits and starts the drive (at 8:30 AM Denver time, so the maps are
in their day look), while the simulator's screen is recorded. The screenshots, the recording and
the step times go to the `promo-captures` branch. Then:

```bash
git fetch origin promo-captures && mkdir -p /tmp/promo && git archive origin/promo-captures | tar -x -C /tmp/promo
python3 scripts/make_promo_images.py fastlane/promo/images.json /tmp/promo/screenshots fastlane/app_store/screenshots/en-US
python3 scripts/make_app_preview.py fastlane/app_previews/walkthrough.json /tmp/promo/recording-720.mp4 fastlane/app_store/previews/en-US/01-walkthrough_IPHONE_67.mp4
```

`fastlane/promo/images.json` picks a screenshot and a caption for each image (start with a verb,
plain words); `walkthrough.json` cuts the clip (recording times are the step times minus the
recorder's late start, about 27 s: match a screenshot to the video to check). Both use the app's
look (`scripts/store_theme.py`). By hand on an iPhone also works:

* Up to 10; the first 2–3 matter most. A good set: the plan form, the route choices on the map,
  a plan's timeline with its stops, a stop's details, and the drive screen.
* Press the side button and volume up together. Hide personal things first (your home address,
  notifications); a full battery and good signal look tidier.
* Commit them to `fastlane/app_store/screenshots/en-US/` as `01-….png`, `02-….png` (the order on
  the store). The size picks the slot; see `fastlane/app_store/README.md`.
* Drive-screen shots: parked, or by a passenger. Never while driving.
* Sizes: the main slot ("iPhone with Dynamic Island, medium display") takes 1179 × 2556 or
  1206 × 2622, what an iPhone 14 Pro, 15, 15 Pro, 16, 16 Pro, 17 or 17 Pro produces. Pro Max
  and Plus models produce the larger size, which goes in the 6.9-inch slot under **View All Sizes
  in Media Manager**; the store scales down from it.

## App previews (optional videos)

15–30 seconds each, up to 3, 886 × 1920 for the main iPhone slot. Record the real app on your
iPhone (Control Center → Screen Recording), then cut it with captions:

```bash
python3 scripts/make_app_preview.py fastlane/app_previews/plan-and-drive.json recording.mp4 fastlane/app_store/previews/en-US/01-plan-and-drive_IPHONE_67.mp4
```

Each JSON file lists the parts of the recording to use, their speed and caption, and how much to crop
off the top (the status bar, recording indicator and AssistiveTouch button aren't part of the app).
Leave out street-level close-ups near home: previews are public. Commit them to
`fastlane/app_store/previews/en-US/` with the slot in the name, e.g.
`01-plan-and-drive_IPHONE_67.mp4` (see `fastlane/app_store/README.md`).

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
