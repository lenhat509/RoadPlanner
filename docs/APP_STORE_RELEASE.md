# App Store release checklist

## One-time setup

Status as of November 14, 2026. Everything runs on GitHub's Mac machines, so no Mac is needed.

Done:

- [x] Join the Apple Developer Program.
- [x] Register the bundle ID (no capabilities needed: background location and audio are declared
      in `Info.plist`) and create the app in App Store Connect. The categories (Navigation, then
      Travel) are uploaded by fastlane.
- [x] Publish the website (privacy policy, support, terms) at
      https://lenhat509.github.io/RoadPlanner/. The **Website** workflow rebuilds it whenever
      [PRIVACY_POLICY.md](PRIVACY_POLICY.md), [SUPPORT.md](SUPPORT.md),
      [TERMS_OF_USE.md](TERMS_OF_USE.md) or `site/site.json` change.

To do:

- [ ] Check that the app name in App Store Connect matches `fastlane/metadata/en-US/name.txt`
      ("Waystage: Road Trip Planner"); otherwise the first upload renames it. The name under the
      icon is "Waystage" either way.
- [ ] Create a new Google Maps key, restricted to the bundle ID and the three APIs, with quotas
      and a budget alert; save it as the `GOOGLE_MAPS_API_KEY` secret; then delete the old key
      in Google Cloud (copies of it were downloadable from the former preview builds) and the
      old `SECRETS_XCCONFIG` secret on GitHub. See [API_KEYS.md](API_KEYS.md).
- [ ] Add the other GitHub secrets and variables for the Release workflow
      ([TRY_ON_IPHONE.md](TRY_ON_IPHONE.md#github-secrets-and-variables)).
- [ ] First TestFlight build: **Actions → Release**, lane `beta`, with **create_certificates**
      ticked (first run only; it creates the signing certificate and profile).
- [ ] In App Store Connect:
  - [ ] **App Review Information** on the version page: your name, phone and email. Only Apple
        sees it, so it isn't kept in this public repository; fastlane uploads the review notes
        and leaves the contact as you set it.
  - [ ] **App Privacy**: answer as in the table below.
  - [ ] **Pricing and Availability**: Free. Prices, fuel grades and units are for the US, so start
        with the United States.
- [ ] Decide on the gateway (`Backend/gateway/README.md`), now or after launch: live hotel rates
      (Expedia Rapid, which needs partner approval) and regional fuel averages (EIA). Without it
      the app shows clearly marked estimates; nothing in the release steps requires it.
- [ ] Have a lawyer review the points under [Legal and disclaimers](#legal-and-disclaimers).

## App Privacy ("nutrition label") answers

Matches `App/Resources/PrivacyInfo.xcprivacy`:

| Data | Collected | Linked to user | Tracking | Purpose |
|---|---|---|---|---|
| Precise location | Yes (sent to Google for routing, place search and navigation) | No | No | App functionality |
| Search history (place queries) | Yes (sent to Google Places) | No | No | App functionality |
| Everything else | No | — | — | — |

No accounts, analytics, advertising or tracking SDKs are included. Google Maps SDK ships its own
privacy manifest.

## Review notes

`fastlane/metadata/review_information/notes.txt` (uploaded by the `release` lane) explains the
flow and why background location is used (voice guidance during an active trip). Background modes declared: `location`, `audio`.
Export compliance: `ITSAppUsesNonExemptEncryption = NO` (HTTPS only).

## Each release

1. Update `CHANGELOG.md`, `MARKETING_VERSION` in `project.yml`, and
   `fastlane/metadata/en-US/release_notes.txt`, and push to `main`.
2. Wait for the **CI** workflow to pass (every test suite, including the UI tests).
3. **Actions → Release**, lane `beta`. Test the TestFlight build on your iPhone in a real car,
   with a passenger operating the phone: planning, voice guidance with the screen locked,
   arrival at a stop, "Continue to next stop", resume after force-quitting, rerouting.
4. **Actions → Release**, lane `release`. It captures the 6.9-inch screenshots and uploads them
   with the listing and review notes. Then, in App Store Connect, select the build and submit it
   for review.

## Guideline notes

* **2.5.4 background modes** — location is used only during active navigation, as the review
  notes state; the blue location indicator is shown.
* **5.1.1 data collection** — location permission is requested in context (current location /
  drive start), with purpose strings in `Info.plist`.
* **1.4 physical harm / safety** — first launch asks people to agree to "Before you start" (plans
  come from Google Maps data and can be wrong, nothing is booked, costs are estimates, you're the
  driver, made for cars); the first drive shows a safety notice; drive mode needs at most one tap
  per stop.
* **Maps attribution** — Google logo and legal notices are shown by the Maps SDK; stop details,
  which show Places data without a map, say "Place information from Google Maps".

## Legal and disclaimers

What the app does (see `Disclosures` in `TripFeatures`, the single source of all wording):

* **First launch: "Before you start".** Six points, a link to the full Terms of Use, Google Maps'
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
   (done in the agreement). Google limits how long Places content may be stored (latitude/longitude
   up to 30 days in the Service Specific Terms); saved plans and the active trip keep place names
   and coordinates longer, so decide whether to expire or refresh them.
3. **Hotel prices**: if Expedia Rapid is used under its launch requirements, its rules for showing
   rates (taxes and fees lines) apply. The FTC's rule on unfair or deceptive fees (in force since
   May 2025) covers how short-term lodging prices are displayed in the US; the app labels rates as
   estimates and says taxes and fees can apply, but check this with counsel.
4. **Affiliate links**: if booking links earn a commission, disclose that next to them.
