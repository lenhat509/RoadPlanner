# App Store release checklist

## One-time setup

- [ ] Choose the final app name and check availability in App Store Connect (current:
      "Waystage: Road Trip Planner"; edit `fastlane/metadata/en-US/name.txt` and
      `CFBundleDisplayName` in `App/Resources/Info.plist`).
- [ ] Register the bundle ID; create the app record in App Store Connect
      (category: Navigation, secondary: Travel).
- [ ] Configure keys — [API_KEYS.md](API_KEYS.md). Release builds refuse to proceed if the Google
      key or gateway are missing (`verify_release_configuration` lane), so production never ships
      in demo mode.
- [ ] Deploy the gateway (`Backend/gateway/README.md`).
- [ ] Host the privacy policy ([PRIVACY_POLICY.md](PRIVACY_POLICY.md)) and support page
      ([SUPPORT.md](SUPPORT.md)); update the URLs in `fastlane/metadata/en-US/*_url.txt` and
      `AppLinks` in `App/Sources/Features/Settings/SettingsScreen.swift`.
- [ ] Replace placeholder review contact details in `fastlane/metadata/review_information/`.
- [ ] `fastlane match appstore` once to create certificates and profiles.
- [ ] Add repository secrets for `.github/workflows/release.yml`: `SECRETS_XCCONFIG`,
      `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_CONTENT`, `MATCH_GIT_URL`, `MATCH_PASSWORD`,
      `MATCH_GIT_BASIC_AUTHORIZATION`; variables `WAYSTAGE_BUNDLE_ID`, `WAYSTAGE_TEAM_ID`.

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

`fastlane/metadata/review_information/notes.txt` explains the flow and why background location is
used (voice guidance during an active trip). Background modes declared: `location`, `audio`.
Export compliance: `ITSAppUsesNonExemptEncryption = NO` (HTTPS only).

## Each release

1. Update `CHANGELOG.md`, `MARKETING_VERSION` in `project.yml`, and
   `fastlane/metadata/en-US/release_notes.txt`.
2. `make test` on a Mac — all suites green and logged.
3. `make screenshots` (6.9-inch iPhone; review the PNGs in `fastlane/screenshots/en-US`).
4. `make beta` → test the TestFlight build on a real device and in a real car (passenger
   operating the phone): planning, voice guidance with the screen locked, arrival detection,
   "Continue to next stop", resume after force-quit, reroute.
5. `make release` (uploads metadata and screenshots; select the build and submit in App Store
   Connect, or `bundle exec fastlane release submit:true`).

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
