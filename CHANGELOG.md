# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

Version 1.2.0: flexible trips. It includes 1.1.1 (below), which is on TestFlight (build 11) but
wasn't released on its own.

### Added
- **Stops on the way.** The plan form takes places to visit on the way, like a park or a friend's
  town, each with how long to stay (5 minutes to 12 hours): with the shortest drive (the default)
  or in the order listed, chosen at the top of the stops; as listed, drag a stop's handle to
  reorder. Each stop has a delete icon. The plan stops there for
  that long and plans the breaks, fuel and nights around them; it can't skip them. A trip with
  stops on the way has one route through them (Google offers no alternative routes through
  stops), plus its toll-free version.
- **Adjust the rest.** Stopped at a stop (or before Start), drive mode says when tonight's hotel
  would be reached well after the end of the driving day, or the destination after the deadline.
  **Adjust the rest** keeps the plan: your stops and the hotels still ahead stay, re-timed from
  now; Waystage picks its breaks and fuel stops again for the new timing. The sheet says what
  changes, and a message says why when the rest can't be adjusted. If tonight's hotel is now too
  far, **Stop earlier tonight** finds a hotel near where today's driving ends. Also in the drive
  menu; never offered while guiding.
- **Adjust visits.** From the plan screen (next to Start driving, after the day-by-day plan) or
  the trip on Home (next to Resume): your visits, in the order they'll be visited, with their
  addresses and arrival times. Changes are listed first and planned together: a place added shows
  **To be added** (green, with a button to take it off the list), tapping a visit marks it **To be
  removed** (red; tap again to keep it), and **Reorder** lets you drag visits into another order.
  Visits are planned **in the order listed** or with the **shortest drive**: then Google Maps
  chooses the order along with the route (its waypoint optimization, in the same request), and the
  list shows its order once planned. Only the visits are kept: the nights, fuel and breaks are
  chosen again for the new route (a hotel kept from the old route pulled it back there). **Update plan** plans once with all of them, and **Use this
  plan** shows the new plan (Undo goes back) or, from Home, makes it the trip. Before the trip
  starts the whole plan is made again; once it has, the rest of the trip from where you are.
- **The trip in progress, at a glance.** Tapping the trip on Home opens its whole plan like a plan
  just made: the map, the summary, the day-by-day stops and their details, with **Adjust visits**
  (the rest of the trip from where you are, saved as the trip) and **Resume**.
- **One whole-route map.** The plan screen, the trip in progress and Adjust visits show the same
  map: about a third of the screen, with full screen, zoom and whole-route buttons, the visits
  numbered (in Adjust visits, in the list's order: green to be added, red to be removed) and the
  route labeled with its driving time. For a trip in progress, the label is the time from where
  you are to the destination.
- **Up to 10 places to visit.** The limit counts only places you add; kept stops and hotels don't
  count toward it (a trip can keep up to 25 stops, the most one route can go through).
- **Your own stop is the break.** To reach a stop you chose (or the destination), driving may run
  up to 30 minutes past the break interval instead of stopping just before it.

### Fixed
- Plans could pile up stops: breaks minutes apart and several hotels close together, where a route
  passes the same area twice (TestFlight build 12). A place is now placed only near the stretch
  where it was found (and on each pass of such a route), breaks Waystage adds are at least
  45 minutes apart, and once real directions are known, stops that aren't where the plan put them
  are replaced and breaks crowded within 30 minutes of another stop are dropped.
- Plans shown from drive mode follow the phone's light or dark setting, like the rest of the app
  (only drive mode's map and panels follow Google's day and night look).

### Changed
- **A plainer look.** Boxes and buttons are nearly rectangular (6–8 point corners instead of
  pills and 22–28 point cards), with thin borders instead of soft shadows; the system font
  replaces the rounded one; the background is neutral grey (not warm paper) and actions use one
  solid highway-sign green (not teal). Home opens on a plain heading and a Plan a road trip
  button instead of a coloured banner. Map pins, the route and stop colours are unchanged.
  Settings, a stop's details, Adjust visits, Add a visit and Adjust the rest use the same boxes
  (the system's grouped list look, whose large rounded sections can't be restyled, is gone).
  Similar elements now look the same everywhere (docs/DESIGN.md): two corner radii (8 pt boxes,
  6 pt controls), one icon-button look (map controls, menus, swap, exit), green borders for every
  selected choice (routes too), the same choice and number inputs in Settings as on the plan form,
  the same switch colour, Add a stop and Add a visit as the same outlined button, warnings in a
  box like other notes, one section-title style and one note size.
  Stop markers use deeper, higher-contrast colours (teal rest, amber fuel, purple night, blue
  visit, red destination), and their white ring is gone except on maps (thinner there): the dots
  in a trip's timeline (saved trips, the trip on Home, plans) are bigger and all colour.
- **The plan screen ends with its buttons**, on one line after the day-by-day plan (Undo, Adjust
  visits, Start driving); a stop's details no longer change the plan (no keep, remove, other
  hotels or add-a-stop actions, and no touch-and-hold menu): visits are changed in Adjust visits.
  Choosing another hotel is gone everywhere (it made a whole new plan around that hotel).
- **Two plans: Fastest and Cheapest.** Balanced is gone (and with it the "your time is worth"
  setting); trips and settings saved with it open as Fastest, now the default.
- **No gradients.** Buttons, the Home header, the drive banner, the launch animation and the app
  icon use flat colours.
- Planning again in the same session (an edited plan, an adjusted trip) reuses that session's
  place searches for road already searched: no extra Google fees for them. They're kept in memory
  only, for 30 minutes.
- **Release workflow: one lane per App Store Connect step.** `upload_build` (TestFlight),
  `create_version` (+ Version), `update_version` (the version page and App Information, now with
  screenshots and app previews from `fastlane/app_store`), `submit_for_review` (choose the build,
  Submit for Review), and `release_all` for all of them in one run. Lanes stop early with the
  reason when App Store Connect wouldn't accept the step. Creating or renewing the signing
  certificate and profile moved to a separate **Signing** workflow; the only checkbox left is
  **run_tests**. The App Review contact can come from optional secrets.

## [1.1.1] — not released (build 11 on TestFlight)

### Changed
- **Planning costs less in Google fees.** Road that several routes share (a toll-free version of
  a route, the first and last hours) is searched once, and its results used for each route,
  instead of once per route. Each search asks Google only for what it uses, which sets its price:
  rest areas at Text Search Pro ($32 per 1,000 after 5,000 free a month), hotels at Enterprise
  ($35 after 1,000 free), gas stations at Enterprise + Atmosphere ($40 after 1,000 free, for
  fuel prices). Before, every search was billed at $40 and they shared one allowance of 1,000 a
  month. Rest-area and hotel detours are now estimated from their distance off the route; the
  final directions still re-time the plan.
- Builds, tests and App Store uploads use **Xcode 27** (iOS 27 SDK): from April 2027 the App Store
  only accepts apps built with it. 1.1.0 (build 10) was built with Xcode 26.2 (iOS 26.2 SDK),
  which App Store Connect flagged (ITMS-90725).
- Google's Maps SDK is pinned to the Navigation SDK's version (11.3.0): Google's 11.4.0 Maps SDK
  doesn't build with the 11.3.0 Navigation SDK. CI also builds the app for iPhones as Release
  does.

## [1.1.0] — 2026-11-18

### Added
- **CarPlay** (navigation app): Google's map on the car's screen, a list of the trip in progress
  and saved plans, each leg previewed with **Start** (**Continue** at a stop), Google's maneuvers,
  lane images and estimates, voice through the car, and **End**. Guidance stops at once when
  CarPlay or the car's own navigation ends it. The iPhone and CarPlay share one drive. See
  `docs/CARPLAY.md`.
- Saved plans older than 30 days are planned again with fresh data (**Saved over 30 days ago ·
  tap to plan again**).

### Changed
- **Turn-by-turn directions come from Google's Navigation SDK** (11.3.0): routes from the phone,
  Google's turn header, lane guidance, speed, voice, rerouting and arrival. Google's terms don't
  allow rebuilding navigation from the Routes API and the Maps SDK, or speaking Google content
  with a speech synthesizer, which the app did before. Its own guidance engine now only runs the
  offline demo and tests, on made-up data.
- While guiding, the bottom panel is the bottom of the screen (full width, no margins, in the
  map's light or dark theme) and the map ends exactly where it starts, so the panel never covers
  the car, the route, or Google's logo and buttons, and there's no empty area around it. In the preview and at stops, routes and the car are framed above
  the panel's measured height.
- Day and night: Google's map and turn banner switch to their night look after sunset where the
  car is (Google's own day and night styles), and drive mode's panels follow them, light by day
  and dark at night, whatever the phone's appearance. On CarPlay the car's day and night setting
  (the scene's content style) switches the map and the panels together. Before, Google's map stayed in its daytime look while the panels
  followed the phone, so they could be dark over a daytime map.
- Google's navigation terms are shown after the first-launch agreement and before a drive until
  accepted. The Terms of Use (version 2) add a section on directions: use your own judgment;
  tolls and HOV-lane fees are the driver's. Everyone is asked to agree again.
- Saved trips keep only what Google allows on the phone: place IDs, and coordinates and route
  lines for 30 days. Place names and addresses are fetched again by place ID when a trip is
  opened; turn instructions and station prices aren't saved (a saved plan shows the fuel price
  estimate). Directions loaded during a drive are no longer saved with the trip.
- Privacy policy: what Google's Navigation SDK collects (location, device ID, diagnostics).
- Release: **refresh_profile** makes a new provisioning profile (once, after turning on CarPlay
  for the App ID), and `beta` checks the profile includes CarPlay.

### Fixed
- **Start driving** and **Resume** open the same way, without camera jumps: the map opens
  already on the leg to the next stop (resuming mid-leg, on what's left of it from the car), and
  **Start** goes down to the car with Google's navigation camera. Before, the camera headed for
  the whole trip, then turned toward the leg when directions arrived, and on Resume could start
  at your position, zoom out, then zoom back in (Google's navigation being attached to a map
  already on screen moved it). Maps also place their first camera only once they have their
  real size.
- A leg's preview shows its time and distance right away (the plan's, for what's left of the
  leg), replaced by Google's live ones when its route arrives, instead of an empty "()" while
  it loads. When the plan doesn't describe the drive (driving to a far-away trip start, or the
  car away from the planned leg), it says "Finding the route…" until Google's route from the car
  arrives.
- The fuel grade on the plan form stays in place when you scroll: it's a plain field that opens
  the list of grades at the bottom of the screen. The drop-down it replaces lifted and followed
  the finger when a scroll started on it.
- Route time tags on the plan's map no longer cover stops: each stands above its route as a
  callout pointing at it, at a point clear of that route's stops and of the other routes.

### Changed
- Drive mode's camera sequence (leg, then car) is one shared function
  (`MapCameraDirector.driveCamera`) used by every way into drive mode.

## [1.0.1] — 2026-11-15

### Changed
- Version number only. 1.0.0 is approved for the App Store, and TestFlight accepts builds for
  external testers (public link) only under a newer version.

## [1.0.0] — 2026-11-15

First App Store release: everything below.

### Changed
- Release builds take the Google key and gateway settings from their own GitHub secrets
  (`GOOGLE_MAPS_API_KEY`, `WAYSTAGE_GATEWAY_URL`, `WAYSTAGE_GATEWAY_TOKEN`) and the bundle and
  team IDs from repository variables, instead of one `SECRETS_XCCONFIG` secret holding a file.
  The setup docs now say keys go in GitHub, never in a file in the repository.

### Removed
- The browser-preview workflow. TestFlight replaces it, and it published the built app (with the
  Google Maps key inside) as a downloadable file on each run; those runs and files are deleted.

### Added
- **"Before you start"** on first launch: plans come from Google Maps data and can be wrong;
  nothing is booked for you; check hotels on their website or by phone; costs are estimates;
  you're the driver; made for cars. Agree once (again when the terms change), with links to the
  full Terms of Use (also in Settings and `docs/TERMS_OF_USE.md`), Google Maps' terms and the
  privacy policies. Reminders where they matter: estimated costs on results, "not booked" on
  every hotel stop, check fuel stops' hours, stop only where legal and safe at roadside breaks,
  and Google Maps attribution on stop details.
- **Fuel grades with their ethanol level.** Choose any gasoline (the default: any gas station
  works) or a specific grade: Regular 87 · E10, Midgrade 89 · E10, Premium 91+ · E10, Flex fuel ·
  E85 or Diesel. Plans only refuel at stations that sell it (a station that lists its grades
  without it is skipped; diesel needs a listing or a truck stop; E85 needs a listing), priced at
  that grade, so a cheapest plan uses the cheapest stations that sell it. E85 accounts for about
  25% fewer miles per gallon; where it's too scarce, the plan uses regular and says so. Fuel stops
  say what to buy ("Fill about 10.5 gal of Premium 91+ · E10"). E15 and ethanol-free (E0) aren't
  offered, because station data doesn't show which stations sell them.
- A two-second opening when the app launches: the icon's scene comes to life (the sun rises,
  the road draws to the horizon, the stops appear along it, then the name), then it fades to
  Home. Tap to skip; with Reduce Motion it simply fades.
- **Route choices.** A search now looks for up to three noticeably different, reasonable routes
  (e.g. San Jose → Denver through Salt Lake City or through Las Vegas, but not through Idaho),
  each with its own breaks, fuel stops and nights. The map shows them all, the chosen one in
  blue and the others lighter, each tagged with its travel time; tap a tag or a route in the
  list to choose it. When there's no reasonable alternative, the single best route is shown.
  Only the route and plan you choose is saved.

### Changed
- The app is now called **Waystage**, with a new icon: the road running to the horizon at dusk,
  with your rest, fuel and overnight stops along it. Settings in `Secrets.xcconfig` now use the
  `WAYSTAGE_` prefix (older files keep working). Trips saved by earlier test builds aren't carried
  over.
- A plan's start and your current location are now kept apart. The plan screen shows where you
  are (blue dot) and says when the trip starts far away ("Starts in San Francisco · 348 mi from
  you"). Starting such a trip first previews the way to its start ("Directions to start");
  reaching the start begins the trip. You can also choose "Start the trip from here".
- "Start driving" now works like resuming: drive mode shows the whole trip, zooms into the first
  leg and waits for **Start**. The trip only counts as started then (backing out leaves it "Not
  started").
- Map moves keep what matters on screen: zooming from the whole trip into a leg keeps the leg in
  view (north up), and **Start** zooms down to the car keeping the car in view while the map turns
  to your direction and tilts; bigger zooms take a little longer. No more sweeping over unrelated
  places. Zoom buttons zoom from the view on screen; the camera and the car move continuously
  between GPS fixes; the follow camera looks ahead so the car sits low on the screen. Framing no
  longer uses map padding, so the map never jumps when panels change.
- Drive mode follows the layout of familiar navigation apps: the next turn at the very top (with a
  "Then" turn when two come close together), mute and "show route" buttons on the right,
  "Re-center" after panning, and a bottom sheet with the time left, distance, arrival time, the next
  stop and a red exit button (which leaves navigation; the trip stays saved).
- Starting or resuming a trip, or continuing from a stop, first shows a preview: the route from
  where you are to the next stop, filling most of the screen, with the rest of the trip in light
  blue. **Start** begins turn-by-turn guidance.
- Directions start where the car is: when you are away from the planned route (e.g. starting
  from home), Waystage fetches directions from your position.
- Refreshed design: warm canvas, soft cards, teal brand gradient, rounded type; a "route rail"
  joining start and destination, trip ribbons (every stop as a dot along the trip) on plans,
  saved trips and drive mode, goal tiles, a fuel gauge for the minimum fuel level and a break
  rhythm strip.
- The route preview map no longer scrolls with the page (pinch/pan work), and has zoom in/out,
  "whole route" and expand buttons.
- The plan form suggests a departure in daytime at the start location (the next quarter hour,
  or 8 AM the next morning when it is late) until you pick a time yourself.
- The map legend wraps instead of scrolling; bottom action bars are opaque with a soft fade.

### Fixed
- "Use current location" on the plan form always failed on a real phone ("Your location isn't
  available yet"): Waystage never asked the device for a position. It now asks for one (and for
  permission if needed), shows progress, and explains what to do if no position is found. The plan
  screen and drive mode also find your position themselves now.
- In drive mode the route line now starts at the car (it began at the planned start, so it
  could be missing near the car); the part already driven is no longer drawn.
- Choosing an autocomplete suggestion needed two taps: a search still in flight re-opened the list.
- In the demo, drive mode's camera trailed the (fast) simulated car and lost it off screen.
- "Fastest" could arrive later than "Cheapest" (e.g. Current Location on a phone set to a different
  time zone): day windows now use the location's time zone, overnight check-ins are never planned
  before 2 PM, and each option is cross-checked against the others after real directions.
- The route preview showed a blank map without a Google key; Apple Maps is used in that case.
- Trip cost now includes all gas burned, also when no fuel stop is needed.

### Added
- Minimum fuel level ("Refuel before X% left", 5–50 %) on the plan form and in Settings; the planner
  never lets the tank drop below it on the way to the next station.
- Tank size moved to the main plan form, with a full-tank range summary.
- Stops are plain colored dots (color-blind-safe palette) with a legend below the map.
- Fuel stops show the tank level on arrival; the cost breakdown shows gallons used.

### From the first build

### Added
- Trip planning from start, destination, departure time, MPG, optional arrive-by time and
  optional rest interval; breaks every 2–3 hours by default.
- Feasibility-first optimizer for fastest, cheapest and balanced plans with rest, fuel and
  overnight stops; relaxation ladder with clear warnings; independent schedule validator.
- Google Routes API, Places API (New) (search along route, live fuel prices), Expedia Rapid
  (via gateway) and EIA (via gateway) integrations with graceful fallbacks.
- Plan comparison, day-by-day timeline, stop details with Google Maps / Expedia links.
- Turn-by-turn drive mode with voice guidance, rerouting, arrival detection, "Continue to next
  stop", auto-departure, and automatic progress saving / resume.
- Settings for car, breaks, driving day, planning goal and voice guidance.
- Backend gateway (TypeScript/Fastify) with auth, rate limiting and caching.
- Test suites (unit, property, integration, UI), test-run logging, pre-push hook, CI, fastlane
  release lanes and App Store metadata.
