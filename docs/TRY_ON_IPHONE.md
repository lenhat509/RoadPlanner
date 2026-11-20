# Try Waystage on your iPhone

Waystage is tested on a real iPhone through **TestFlight**. Builds run on GitHub's Mac machines
(free for public repos), so you don't need a Mac.

| | TestFlight |
|---|---|
| Apple account needed | Apple Developer Program ($99/year) |
| Time to first try | About an hour once the account is approved |
| Runs | Installed on your iPhone |
| GPS / voice guidance | Real GPS; Google's turn-by-turn navigation and voice (Navigation SDK) |
| CarPlay | Yes, once CarPlay Navigation is on for the App ID ([CARPLAY.md](CARPLAY.md)) |

To look at the app without installing it, open the latest **Screenshots** workflow run: it walks
through the main screens on a simulator and shows them in the log.

## Step 0 — make sure CI is green

Open **Actions** in the repository. The *CI* workflow runs on every push. The *iOS* job is the
first real compile of the app; if it fails, open the failing step, copy the error lines and fix
them (or share them).

## TestFlight on your iPhone

### One-time Apple setup

1. Join the **Apple Developer Program**: <https://developer.apple.com/programs/>.
2. **Certificates, IDs & Profiles → Identifiers → +** → App ID, e.g. `com.waystage.waystage`.
   Turn on **CarPlay Navigation** once Apple has granted it (see [CARPLAY.md](CARPLAY.md)); no
   other capability is needed.
3. **App Store Connect → Apps → +** → New App: iOS, name (must be unique, e.g.
   "Waystage: Road Trip Planner"), the bundle ID above, SKU e.g. `waystage-ios`, Full Access.
4. **App Store Connect → Users and Access → Integrations → App Store Connect API → +**: role
   *App Manager*. Download the `.p8` file (only once!) and note the **Key ID** and **Issuer ID**.
5. Create an **empty private** GitHub repository for signing certificates, e.g.
   `RoadPlanner-certificates`, and a fine-grained personal access token with *Contents:
   read & write* on it.
6. Find your **Team ID**: <https://developer.apple.com/account> → Membership details.

### GitHub secrets and variables

Everything goes in GitHub, under **Settings → Secrets and variables → Actions**: secrets on the
*Secrets* tab, variables on the *Variables* tab. Nothing goes in a file in the repository.

| Kind | Name | Value |
|---|---|---|
| Secret | `GOOGLE_MAPS_API_KEY` | your Google Maps key ([API_KEYS.md](API_KEYS.md)) |
| Secret | `ASC_KEY_ID` | Key ID from step 4 |
| Secret | `ASC_ISSUER_ID` | Issuer ID from step 4 |
| Secret | `ASC_KEY_CONTENT` | base64 of the `.p8` file (`base64 -i AuthKey_XXXX.p8`, or any base64 tool) |
| Secret | `MATCH_GIT_URL` | `https://github.com/<you>/RoadPlanner-certificates.git` |
| Secret | `MATCH_PASSWORD` | a new strong passphrase (encrypts the certificates; keep it) |
| Secret | `MATCH_GIT_BASIC_AUTHORIZATION` | base64 of `<github-username>:<token from step 5>` |
| Variable | `WAYSTAGE_BUNDLE_ID` | your bundle ID, e.g. `com.waystage.waystage` |
| Variable | `WAYSTAGE_TEAM_ID` | your Team ID |
| Variable (optional) | `WAYSTAGE_COMPANY_NAME` | the legal name on your Google Maps Platform account, shown in Google's navigation terms dialog (default "Waystage") |
| Secret (optional) | `WAYSTAGE_GATEWAY_URL`, `WAYSTAGE_GATEWAY_TOKEN` | only once the gateway is deployed |
| Secret (optional) | `REVIEW_FIRST_NAME`, `REVIEW_LAST_NAME`, `REVIEW_PHONE`, `REVIEW_EMAIL` | the App Review contact, uploaded with the version page (only Apple sees it) |

Nothing uses `SECRETS_XCCONFIG` or any `APPETIZE_…` secret or variable any more; delete them if
they're listed.

Never paste these values into issues, chats or commits.

### Build and install

1. First time only: **Actions → Signing → Run workflow** creates your distribution certificate and
   profile in the certificates repo. Run it again after turning on CarPlay Navigation for the App
   ID (a profile that includes CarPlay) and when the certificate expires (yearly).
   Then **Actions → Release → Run workflow** with lane `upload_build`.
2. After the run, App Store Connect processes the build (~10–30 minutes). In **TestFlight →
   Internal Testing**, add yourself as a tester (internal testers need no beta review).
3. On your iPhone, install **TestFlight** from the App Store, open the invitation email and
   install Waystage.

Test in a real car with a passenger operating the phone: Google's navigation terms before the
first drive, voice guidance with the screen locked, arrival at a stop, **Continue to next stop**,
rerouting after a wrong turn, and resuming after force-quitting the app. With CarPlay: start a
saved trip from **Trips** on the car's screen, follow a leg, **End**, and **Continue** at a stop
(see [CARPLAY.md](CARPLAY.md#testing)).

## Keeping your Google key safe

The release build carries your Google Maps key inside the app (every app that uses Google Maps
does), so it can't be fully secret. Protect it instead, as described in [API_KEYS.md](API_KEYS.md):
restrict it to your bundle ID and to the four APIs Waystage uses (including the Navigation SDK), and set daily quotas and a
budget alert. No workflow publishes a built app on GitHub: the Release workflow sends it straight
to TestFlight.
