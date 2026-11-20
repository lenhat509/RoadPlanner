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
3. On GitHub, **Actions → Signing → Run workflow**. fastlane makes a new App Store provisioning
   profile that includes CarPlay. Then build as usual (**Actions → Release**, lane
   `upload_build`).

Later releases don't need the Signing workflow. If the profile doesn't include CarPlay, the
building lanes stop before building and say which step is missing.

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

What CI checks: the CarPlay code compiles, and the drive logic it uses is tested (including
"Ending guidance from CarPlay returns to the leg's preview at once" and the iPhone and CarPlay
sharing one drive). What it can't check: the CarPlay screens themselves, which iOS draws outside
the app, where UI tests can't reach. Check them by hand:

* **Xcode's CarPlay simulator** (a Mac, your own or rented by the hour): iPhone Simulator → I/O →
  External Displays → CarPlay, with a build that has a Google key. Launch argument
  `-SimulateNavigation` drives each route with the Navigation SDK's location simulator.
* **Apple's CarPlay Simulator app** (in Additional Tools for Xcode, on a Mac): the Mac acts as the
  car's screen for a real iPhone over USB, running the TestFlight build.
* **A portable CarPlay screen** (an aftermarket dash display, powered by a 12 V adapter at a desk):
  real CarPlay from the iPhone with the TestFlight build, no Mac or car needed.
* **In a car**, with the TestFlight build and a passenger: start a saved trip from CarPlay with the
  iPhone locked, follow a leg, let the car's own navigation take over (guidance must stop), arrive
  at a stop and **Continue**, and end the trip. Only a car checks voice through its speakers
  alongside the radio, its own controls (knob, touchpad) and real GPS.

Google's CarPlay support for the Navigation SDK is in **Preview** (pre-GA): it can change, and
alternate routes can't be chosen on the car's screen. See [COMPLIANCE.md](COMPLIANCE.md).
