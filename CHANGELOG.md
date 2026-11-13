# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

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
