# Planning algorithm

## Problem

Given a route from origin to destination, find which stops to make and what to do at each
(rest, refuel, sleep) so that all **hard constraints** hold and the **objective** is optimal.

### Hard constraints (never violated)

| Constraint | Default | Source |
|---|---|---|
| Non-stop driving ≤ `maxContinuousDriving` | 3 h (a break every 2–3 h) | user's "drive before resting" |
| Every stop includes a break ≥ `restStopDuration` / `fuelStopDuration` | 15 min | settings |
| Fuel never below the driver's **minimum fuel level** (`fuelReserveFraction`) — every leg must reach the next station (or the destination) above it | 15 % (5–50 %) | plan form / settings; never relaxed |
| Daily driving ≤ `maxDailyDriving` | 10 h | settings |
| Arrival at overnight stops / destination ≤ local `dayEnd` | 21:00 | settings |
| Departure from overnight stops ≥ local `dayStart` and ≥ `minimumOvernightRest` | 08:00, 9 h | settings |
| Overnight check-in at 14:00 local or later (or after midnight, before `dayStart`) | 14:00 | optimizer setting |
| Arrival ≤ `arriveBy` | — | user (optional) |

Local times use each stop's own UTC offset, so cross-country time zones are handled. "Current
Location" uses the phone's time zone only when it is within 2 h of the location's longitude-based
estimate (a phone still set to another zone would otherwise distort the day windows).

### Objective

`score = cost + elapsed hours × valueOfTime + comfort penalties`

`cost` = fuel + lodging + tolls, where **fuel is all gas the trip burns**: purchases, plus fuel that
was already in the tank, minus fuel left at the end, valued at the median station price along the
route. A trip with no fuel stop therefore still shows its gas cost.

| Goal | Value of time | Meaning |
|---|---|---|
| Fastest | $10,000/h | minimize arrival time (money breaks ties) |
| Cheapest | $2/h | minimize fuel + lodging + tolls (time breaks ties, avoids silly detours) |

(1.2.0 removed the Balanced plan; trips saved with it open as Fastest.)

Comfort penalties (small) prefer real rest areas over roadside pull-offs, and real hotels over
"lodging search areas".

## Candidates

`CandidateBuilder` turns Places results into candidates with position along the route
(projection onto the polyline using a spatial grid index), time along the route, detour time and
distance (gas stations: from Places routing summaries; rest areas and hotels: estimated from the
distance off the route, since Google bills routing summaries at its most expensive tier), and
prices:

* fuel, **only at stations that sell the car's grade** (`FuelOffer`): a station that lists its
  grades (Places `fuelOptions`) sells exactly those, at its listed price; one that lists none is
  assumed to sell the gasoline grades (practically every US station does), priced at the EIA
  regional average → national default; diesel is assumed only at truck stops and E85 never (it
  must be listed). "Any gasoline" uses a station's cheapest gasoline. A station without the
  grade is still a candidate for a break. E85 uses 75 % of the car's gasoline MPG; if E85 is too
  scarce for a plan without emergency fuel, the plan is redone with regular (a flex-fuel car takes
  both) and says so (`fuelGradeUnavailable`). Since the optimizer minimizes cost over these
  candidates, a cheapest plan fills up at the cheapest stations that sell the grade,
* lodging: live Expedia nightly rate → Google price-level estimate → default.

Clusters are thinned per 15-minute bucket (cheapest and closest kept). **Roadside pull-offs** are
added every 15 minutes where no facility exists, and **lodging search areas** every 30 minutes;
these guarantee feasibility and are only used when needed.

## Optimizer — resource-constrained shortest path

Stops are nodes ordered along the route (a DAG). A **label** at a node is a partial plan:
departure time, cost + penalties, fuel in tank, driving time today, the day's cutoff, day index.

```
for node in route order:
  for label in Pareto-front(node):
    for next node within maxContinuousDriving (and fuel, daily limit):
      check: non-stop drive ≤ limit, fuel ≥ reserve, day cutoff, deadline lower bound
      destination → candidate solution
      otherwise create labels for each possible action:
        rest            (+break)
        refuel to full  (+fuel stop, cost; only if ≥ 25 % of tank)
        refuel to reach destination with reserve (avoids paying for leftover fuel)
        sleep           (+nightly rate; depart next morning; reset daily counters)
      insert if not dominated
```

**Dominance:** label A dominates B at the same node when A has ≤ money (cost + penalties),
≤ departure time, ≥ fuel, ≤ driving today and ≥ day cutoff. Money and time are compared
separately — an overnight stop erases time advantages, so a blended score would be unsound
(this was caught by the goal-ordering test). Fronts are capped (40 labels) keeping the best
scores plus the fullest tanks and earliest departures.

**Deadline pruning:** a label is dropped when even an optimistic completion (remaining drive time
plus the minimum number of breaks) misses `arriveBy`.

Complexity is roughly `nodes × labels × reachable nodes`. Measured (release build, 4-core x86-64):
a 2,615-mile San Francisco → New York trip with 353 candidate stops is optimized for all three
goals in 0.23 s (~76 ms per goal); the whole pipeline excluding network latency takes 0.42 s.
In the app, network round-trips to Google dominate planning time.

## Required stops (1.2.0)

A request can list stops the plan must include, in route order: places to visit with a stay, and
stops kept from an earlier plan (a break, a fuel stop, tonight's hotel). They are one building
block for stops on the way, editing a plan and planning the rest of a trip again.

* **Routing:** the trip is routed through them as intermediate waypoints. Google's Routes API
  returns no alternative routes for such requests, so the trip has one corridor (plus its
  toll-free version), and no via hubs (which would be ordered after the stops).
* **Candidates:** each required stop sits at the end of its leg (cumulative leg distance, scaled
  to the route's geometry; time from the route profile), with no detour. A search result for the
  same place gives it its live details (price, rate). Removed places (`avoidedPlaceIDs`) are
  dropped from the candidates.
* **Optimizer:** no driving segment passes the next required node, and only its own action is
  planned there: the visit's stay, the kept break, a refuel, or an overnight (a kept hotel needs
  no usual check-in time). The optimistic arrival bound adds the stays still to come. Fuel,
  driving-day and overnight state carry across required stops like any stop, so the schedule
  around them stays optimal, e.g. whether to spend the night before or after a visit.
* **Planning again during a drive:** `startState.drivenToday` starts the first day with the
  driving already done (keeping an hour to reach tonight's stop); the validator counts it too.
* **Lodging searches** follow the stays: a long visit ends a driving day earlier along the route.
* The straight-through fallback keeps the required stops.
* **Your own stop is the break:** the drive to a required stop or to the destination may run
  `DrivingPolicy.stretchToOwnStop` (30 min) past the break interval, instead of a break just
  before it (the validator allows the same).

## Stops never pile up

* **One pass at a time:** a place is projected only near the stretch of route where it was found
  (±20 km of the search's section). A place found on two passes of a route (out to a stop and
  back) is a candidate on each pass (`CandidateBuilder.mergeDuplicates`).
* **Spacing:** a break the optimizer adds comes at least `minimumBreakSpacing` (45 min, or half the
  break interval if shorter) after the previous stop; fuel and overnight stops may come sooner when
  they're needed.
* **After real directions** (`TripPlanningService.finalize`): a stop whose real drive there and on
  both differ from the plan's distances by more than 25 km and a third isn't where the plan put it;
  the plan is made once more without it (`misplacedStops`). A break less than 30 min from the stop
  before or after it is dropped and its legs joined (`droppingCrowdedBreaks`).

## Feasibility first — the relaxation ladder

`FeasibilityPlanner` tries increasingly relaxed settings and returns the first feasible plan, so
a plan that respects the user's preferences always beats a "more optimal" one that doesn't:

| Level | Change | Warning shown |
|---|---|---|
| standard | user's policy | — |
| extendedDay | day ends up to 2 h later, starts 1 h earlier, +1 h daily driving, −1 h overnight rest (≥ 7 h) | "Some driving days start as early as … end as late as …" |
| shorterBreaks | breaks of 10 min | "Breaks are shortened to 10 minutes." |
| nightDriving | no end-of-day cutoff | "Some driving happens late at night…" |
| lastResort | lodging search areas, emergency fuel at pull-offs (minimum fuel level kept) | lodging / fuel gap warnings |

All levels are first tried **with** the deadline; only if none meets it is the deadline dropped,
and the plan reports the earliest safe arrival. `maxContinuousDriving` is never relaxed.

## Finalization

Directions for the chosen stops are requested in batches of ≤ 25 intermediate waypoints. The
`ScheduleRetimer` recomputes times and fuel from real leg durations/distances; the
`ScheduleValidator` re-checks every hard constraint. If real detours pushed a leg over a limit,
the plan is recomputed once with limits scaled by 0.9 and the better result is kept.

Finally, each option is replaced by whichever finalized plan is best for its own goal (feasibility
first: met deadline, then fewer relaxations, then the objective). This guarantees the UI never
shows a "Fastest" plan that arrives later, or a "Cheapest" plan that costs more, than another
option.

## Verification

* Unit tests for each constraint and objective trade-off (`ItineraryOptimizerTests`).
* Ladder tests (`FeasibilityPlannerTests`).
* **Property tests**: 24 random scenarios (routes, stop densities, cars, intervals, goals,
  deadlines) — every plan must pass the independent `ScheduleValidator`.
* End-to-end integration tests through the real Google adapters (`PlanningIntegrationTests`).

## Known limitations

* Detours are estimated per candidate (Places routing summaries for gas stations, distance off
  the route for rest areas and hotels); finalization corrects times.
* Fuel purchases are "fill up" or "just enough to arrive"; partial top-ups to reach a cheaper
  station are not modelled (small cost impact).
* Traffic is taken from the Routes API at planning time; the drive mode updates ETAs live.
