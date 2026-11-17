# CarPlay

Waystage is a CarPlay navigation app (entitlement `com.apple.developer.carplay-maps`, granted by
Apple). On the car's screen it shows the drive from the iPhone: Google's map with the route and
the car, the next turn and time to the next stop, and the trip's stops.

## Turning it on (once)

Apple has granted the entitlement to the developer account; the App ID and the provisioning
profile still need it.

1. In the [Apple Developer portal](https://developer.apple.com/account/resources/identifiers/list),
   open **Identifiers**, then the app's ID (the `WAYSTAGE_BUNDLE_ID`).
2. Turn on **CarPlay Navigation** (under *Capabilities* or *Additional Capabilities*; it appears
   once Apple has granted it) and click **Save**.
3. On GitHub, **Actions → Release → Run workflow**, lane `beta`, with **refresh_profile** ticked.
   fastlane makes a new App Store provisioning profile that includes CarPlay, then builds and
   uploads to TestFlight.

Later releases don't need **refresh_profile**. If the profile doesn't include CarPlay, the
`beta` lane stops before building and says which step is missing.

As soon as a build with the entitlement is installed, Waystage appears on the CarPlay home
screen of every user of that build (TestFlight testers first, then everyone after release).
Apple doesn't allow showing CarPlay to some users only.

## What it does

| On the car's screen | How |
|---|---|
| The map | A Google map (Navigation SDK) on the CarPlay screen: route, car, traffic. No part of it is tappable (CarPlay rule); map buttons pan, zoom and re-center. |
| **Trips** | The trip in progress and saved plans. Choosing one opens drive mode on the iPhone and in the car. Planning a new trip needs typing, so it's done on the iPhone. |
| Leg preview | The next stop, what it's for, time and distance, and **Start** (**Go to start** when the trip starts far away). At a stop: the next stop and **Continue**. |
| Guidance | Google's maneuvers, lane images and estimates, and its voice through the car's speakers. Buttons: mute, route overview, **End**. |
| End | **End**, or the car's own navigation starting, stops guidance at once and goes back to the leg's preview. |
| Arrival | "You've arrived" with **Done** at the destination. |

The iPhone and CarPlay share one drive: starting, continuing or ending on one shows on the other.
Before the very first drive, the terms, the driving safety notice and Google's navigation terms
are accepted on the iPhone (Google's dialog can't be shown in the car). Until then, **Trips** on
CarPlay says Waystage isn't set up yet, without asking the driver to pick up the phone.

## Testing

* **CarPlay Simulator** (Xcode → Open Developer Tool → Simulator → I/O → External Displays →
  CarPlay) with a build that has a Google key. Launch argument `-SimulateNavigation` drives each
  route with the Navigation SDK's location simulator.
* **In a car**, with the TestFlight build and a passenger: start a saved trip from CarPlay with the
  iPhone locked, follow a leg, let the car's own navigation take over (guidance must stop), arrive
  at a stop and **Continue**, and end the trip.

Google's CarPlay support for the Navigation SDK is in **Preview** (pre-GA): it can change, and
alternate routes can't be chosen on the car's screen. See [COMPLIANCE.md](COMPLIANCE.md).
