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
* **Safety** — the first drive shows a safety notice; drive mode needs at most one tap per stop.
* **Maps attribution** — Google logo and legal notices are shown by the Maps SDK.
