# Compliance: Google Maps Platform and Apple CarPlay

What the rules say, where they come from, what Waystage did, and what it does now. Quotes are
verbatim from the sources below, read on November 17, 2026. This is engineering research, not
legal advice: the open questions at the end are for a lawyer.

## Sources

| Document | Version |
|---|---|
| [Google Maps Platform Terms of Service](https://cloud.google.com/maps-platform/terms) (non-EEA) | Last modified August 26, 2026 |
| [Google Maps Platform Service Specific Terms](https://cloud.google.com/maps-platform/terms/maps-service-terms) (non-EEA) | Last modified October 28, 2026 |
| [Safety Requirements for real-time driving and navigation](https://cloud.google.com/terms/maps-platform/eea-safety-requirements) | Last modified June 4, 2025 |
| [Navigation SDK for iOS: policies and attributions](https://developers.google.com/maps/documentation/navigation/ios-sdk/policies) | Read November 17, 2026 |
| [Navigation SDK for iOS: CarPlay](https://developers.google.com/maps/documentation/navigation/ios-sdk/carplay), [navigate a route](https://developers.google.com/maps/documentation/navigation/ios-sdk/route), [billing](https://developers.google.com/maps/documentation/navigation/ios-sdk/usage-and-billing) | Read November 17, 2026 |
| [Places API policies](https://developers.google.com/maps/documentation/places/web-service/policies), [Routes API policies](https://developers.google.com/maps/documentation/routes/policies) | Read November 17, 2026 |
| [Google Maps Platform pricing](https://developers.google.com/maps/billing-and-pricing/pricing) | Read November 17, 2026 |
| Navigation SDK for iOS 11.3.0 headers (`GMSNavigator.h`, `GMSNavigationServices.h`, ...) | Version 11.3.0 |
| [Apple CarPlay App Programming Guide](https://developer.apple.com/carplay/documentation/CarPlay-App-Programming-Guide.pdf) | October 13, 2026 |

## Google Maps Platform: what applies to Waystage

### 1. Turn-by-turn navigation must not be rebuilt from the other services

> **3.2.3(d) No Re-Creating Google Products or Features.** Customer will not use the Services to
> create a product or service with features that are substantially similar to or that re-create
> the features of another Google product or service. [...] For example, Customer will not: [...]
> (iv) combine data from the Directions API, Geolocation API, and Maps SDK for Android to create
> real-time navigation functionality substantially similar to the functionality provided by the
> Google Maps for Android mobile app.

Google's product for in-app turn-by-turn is the Navigation SDK:

> You can use the Navigation SDK for iOS to provide drivers with real-time turn-by-turn navigation
> in a mobile application. *(Navigation SDK policies, "Acceptable use")*

**Waystage before:** its own guidance engine (`TripNavigation/GuidanceEngine`) followed GPS
along Routes API polylines and drew the route on the Maps SDK, the pattern 3.2.3(d)(iv)
describes. **Now:** in the App Store build, routes to each stop, turn instructions, voice,
rerouting and arrival come from the Navigation SDK (`GMSNavigator`). The old engine is only used
by the offline sandbox (demo mode without a key, UI tests), which uses made-up data, never
Google content.

### 2. No text-to-speech of Google content

> **3.2.3(a) No Scraping.** [...] Customer will not: [...] (iv) use Google Maps Content with
> text-to-speech services.

> **3.2.3(c)** [...] Customer will not: [...] (vi) convert text-based driving times into
> synthesized speech results.

**Before:** the app spoke Routes API instructions and place names with `AVSpeechSynthesizer`.
**Now:** the App Store build has no speech synthesizer. Voice guidance is the Navigation SDK's
own (`GMSNavigator.voiceGuidance`; Waystage's mute button sets it to silent).

### 3. Storing Google content on the phone

> **3.2.3(a)** [...] Customer will not: (i) pre-fetch, index, store, reshare, or rehost Google
> Maps Content outside the services; [...] (iii) copy and save business names, addresses, or
> user reviews [...]
>
> **3.2.3(b) No Caching.** Customer will not cache Google Maps Content except as expressly
> permitted under the Maps Service Specific Terms.

Permitted (Service Specific Terms A.3, 12.3, 14.3, 19.3): place IDs indefinitely; latitude and
longitude from the Places API, Routes API and Navigation SDK "for up to 30 consecutive calendar
days, after which Customer must delete the cached latitude and longitude values." Google's advice:
"Store exempt identifiers such as the place ID to fetch fresh details when a user interacts with
a place." *(Places API policies)*

The Navigation SDK adds: "If you capture or persist the road name or speed limit for use in any
other context outside of the user session, this action constitutes scraping."

**Before:** saved trips and the trip in progress were stored indefinitely with place names,
addresses, turn instructions, route lines, route names and fuel prices. **Now:** see
[What is stored](#what-is-stored). Implemented by `GoogleContentRetention` and
`RetainingTripRepository` (App Store build), with tests in `GoogleContentRetentionTests`.

### 4. Google content only on Google maps

> **3.2.3(e) No Use With Non-Google Maps.** [...] Customer will not use the Google Maps Core
> Services with or near a non-Google Map in a Customer Application.

**Status:** complies. The App Store build draws every map with Google (Maps SDK, Navigation SDK).
Apple Maps is used only in the offline sandbox, which shows made-up data. The CarPlay screen
draws a Google map (`GMSMapView` on the CarPlay screen).

### 5. In-vehicle use and CarPlay

> **3.2.3(f) No Use in Embedded Vehicle Systems.** Customer will not use the Google Maps Core
> Services in connection with any Customer Application or device embedded in a vehicle. For
> example, Customer will not create a Customer Application that (i) is embedded in an
> in-dashboard automotive infotainment system [...]

CarPlay runs on the iPhone and is shown on the car's screen; it is not an app embedded in the
car. Google documents CarPlay for the Navigation SDK ("Drivers can use your app directly on their
car's display by connecting their phone to the unit"), but marks it **Preview (pre-GA)**:

> This product or feature is in Preview (pre-GA). [...] Pre-GA Offerings are covered by the
> Google Maps Platform Service Specific Terms.

Pre-GA terms (Service Specific Terms A.5): provided "as is", "may be changed, suspended, or
discontinued at any time without prior notice", no SLA. Google also notes: "Alternate routes
cannot be selected on the CarPlay screen. They must be selected from the phone before CarPlay
starts."

### 6. Navigation SDK conditions

From the Navigation SDK policies:

- **Commercial use:** "You can use the Navigation SDK for iOS only for commercial applications."
  (see open questions)
- **Vehicles:** heavy or large vehicles (buses, trucks, vehicles with road restrictions) need
  Google's large-vehicle routing. Waystage plans for cars only and says so (Terms, section 10).
- **Shown at first use:** "The Navigation SDK terms of use", that users "should always exercise
  independent judgment [...] because information from the Navigation SDK service might differ
  from actual real-time conditions", and that "Users are solely responsible for costs incurred
  when following the directions [...] such as for toll fees or high-occupancy vehicle lanes."
  Waystage shows Google's terms dialog (`GMSNavigationServices.showTermsAndConditionsDialogIfNeeded`)
  right after its own first-launch agreement, and again before a drive while it hasn't been
  accepted. The other two points are in the first-launch agreement ("Directions can differ from
  the road") and the Terms (section 9).
- **UI changes must not inhibit safe use:** no distracting animations during active navigation,
  no overlays without explicit driver action, nothing covering the car's position, "upcoming
  turns, lane guidance, compass orientation, and all standard UI elements". During guidance
  Waystage shows Google's navigation header, recenter button and speed display, and its own
  panel sits *below* the map, not over it.
- **In-product terms:** "You can't modify the Navigation SDK in-product terms."

### 7. Safety Requirements (real-time driving)

Glanceable information while moving, input locked out or simplified while moving, a visible
indicator when GPS accuracy degrades, no stale data presented as real-time, and the active route
clearly distinct from alternatives. The Navigation SDK provides guidance, accuracy handling and
route styling; Waystage's own screens during a drive are limited to the next stop and a few large
buttons, and planning (text entry) isn't available in drive mode or on CarPlay.

### 8. End-user terms and attribution

> **3.2.2(a)(i)** The Customer Application's terms of service will (A) notify users that the
> Customer Application includes Google Maps features and content; and (B) state that use of
> Google Maps features and content is subject to the then-current versions of the: (1) Google
> Maps End User Additional Terms of Service [...]; and (2) Google Privacy Policy.

**Status:** complies (Terms of Use, section 4; "Before you start"). Attribution: the Maps SDK and
Navigation SDK draw Google's logo on every map; lists of places shown without a map carry
"Google Maps" text attribution.

### 9. Costs (pay-as-you-go, November 2026)

| SKU | Free each month | Then, per 1,000 |
|---|---|---|
| Navigation Request (one per destination set; guidance and reroutes free) | 1,000 | $25.00, falling with volume |
| Routes: Compute Routes Pro | 5,000 | $10.00 |
| Places API Text Search Enterprise | 1,000 | $35.00 |
| Places API Place Details Pro (display names) | 5,000 | $17.00 |
| Places API Place Details Essentials (IDs only) | unlimited | free |

Waystage sets one destination per leg (the next stop), so a trip costs one Navigation Request per
stop driven to, plus one when a leg is reloaded (resuming, skipping a stop).

## Apple CarPlay: what applies

From the CarPlay App Programming Guide (October 13, 2026):

- Entitlement `com.apple.developer.carplay-maps`, assigned by Apple, enabled on the App ID, and
  included in a new provisioning profile.
- "Your CarPlay app must be designed primarily to provide the specified feature", "Never instruct
  people to pick up their iPhone", "All CarPlay flows must be possible without interacting with
  iPhone", "All CarPlay flows must be meaningful to use while driving."
- Navigation apps: "must provide turn-by-turn directions with upcoming maneuvers"; "The base view
  must be used exclusively to draw a map"; "Provide a way to enter panning mode" with a map
  button; "Immediately terminate route guidance when requested"; voice prompts must work with
  the car's audio; "Ensure that your map is appropriate in each supported country."

Waystage on CarPlay: a Google map as the base view; map buttons for panning, zoom and recenter;
the trip in progress, or a saved trip, can be started from a list; each leg is previewed and
started from the trip preview panel; maneuvers and estimates come from the Navigation SDK's
turn-by-turn feed; arrival offers "Next stop"; when CarPlay cancels navigation, guidance stops at
once.

## What is stored

| Data | Allowed | Waystage stores |
|---|---|---|
| Place IDs | Indefinitely | Yes, for every Google place |
| Coordinates and route lines (Places, Routes) | Up to 30 days | Yes, for 30 days after planning. Then the plan becomes an outline (place IDs, dates, vehicle, preferences) that is planned again with fresh data |
| Place names, addresses, time-zone offsets | No | No: fetched by place ID (Place Details) when a trip is opened, kept in memory for the session |
| Turn instructions, route descriptions | No | No |
| Navigation SDK routes, road names, speed limits | No | No: in memory during the drive only |
| Station fuel prices | No | No: a saved plan shows the national estimate instead (marked as an estimate) |
| Your own data (dates, times, plan structure, progress, vehicle) | Yours | Yes |

## Privacy: what the Navigation SDK collects

Google's Navigation SDK 11.3.0 declares in its privacy manifest that it collects precise location
and a device ID (linked to the user), crash, performance and product-interaction data, and other
data, for app functionality and analytics (not tracking). The privacy policy says so, and the App
Store privacy answers include it ([APP_STORE_RELEASE.md](APP_STORE_RELEASE.md#app-privacy-nutrition-label-answers)).

## Open questions for a lawyer (or Google Maps Platform sales)

1. **"Only for commercial applications."** Waystage is a free consumer app published on the App
   Store. Does Google consider it a commercial application?
2. **CarPlay and 3.2.3(f).** Google documents CarPlay for the Navigation SDK, as a pre-GA feature.
   Confirm that showing it on CarPlay is not "use in an embedded vehicle system".
3. **Company name in Google's terms dialog.** The dialog names "the company releasing the app and
   in the agreement with Google to share location data". Waystage passes `WAYSTAGE_COMPANY_NAME`
   (default "Waystage"); set it to the legal name on the Google Maps Platform account.
4. **Derived planning data.** Waystage stores its own schedule (stop order, times), leg distances
   and durations and cost totals computed from Google data. Confirm this is Waystage's content
   and not "content based on Google Maps Content" (3.2.3(c)); if not, saved plans would keep only
   place IDs and the driver's choices.
