# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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

## [1.0.0] — Unreleased

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
