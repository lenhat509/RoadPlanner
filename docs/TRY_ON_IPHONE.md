# Try Waystage on your iPhone

Waystage is tested on a real iPhone through **TestFlight**. Builds run on GitHub's Mac machines
(free for public repos), so you don't need a Mac.

| | TestFlight |
|---|---|
| Apple account needed | Apple Developer Program ($99/year) |
| Time to first try | About an hour once the account is approved |
| Runs | Installed on your iPhone |
| GPS / voice guidance | Real GPS, real voice guidance |

To look at the app without installing it, open the latest **Screenshots** workflow run: it walks
through the main screens on a simulator and shows them in the log.

## Step 0 — make sure CI is green

Open **Actions** in the repository. The *CI* workflow runs on every push. The *iOS* job is the
first real compile of the app; if it fails, open the failing step, copy the error lines and fix
them (or share them).

## TestFlight on your iPhone

### One-time Apple setup

1. Join the **Apple Developer Program**: <https://developer.apple.com/programs/>.
2. **Certificates, IDs & Profiles → Identifiers → +** → App ID, e.g. `com.yourname.waystage`.
3. **App Store Connect → Apps → +** → New App: iOS, name (must be unique, e.g.
   "Waystage Road Trip <yourname>"), the bundle ID above, any SKU.
4. **App Store Connect → Users and Access → Integrations → App Store Connect API → +**: role
   *App Manager*. Download the `.p8` file (only once!) and note the **Key ID** and **Issuer ID**.
5. Create an **empty private** GitHub repository for signing certificates, e.g.
   `RoadPlanner-certificates`, and a fine-grained personal access token with *Contents:
   read & write* on it.
6. Find your **Team ID**: <https://developer.apple.com/account> → Membership details.

### GitHub secrets and variables

**Settings → Secrets and variables → Actions**

| Kind | Name | Value |
|---|---|---|
| Secret | `ASC_KEY_ID` | Key ID from step 4 |
| Secret | `ASC_ISSUER_ID` | Issuer ID from step 4 |
| Secret | `ASC_KEY_CONTENT` | base64 of the `.p8` file (`base64 -i AuthKey_XXXX.p8`, or any base64 tool) |
| Secret | `MATCH_GIT_URL` | `https://github.com/<you>/RoadPlanner-certificates.git` |
| Secret | `MATCH_PASSWORD` | a new strong passphrase (encrypts the certificates; keep it) |
| Secret | `MATCH_GIT_BASIC_AUTHORIZATION` | base64 of `<github-username>:<token from step 5>` |
| Secret | `SECRETS_XCCONFIG` | see below |
| Variable | `WAYSTAGE_BUNDLE_ID` | e.g. `com.yourname.waystage` |
| Variable | `WAYSTAGE_TEAM_ID` | your Team ID |

`SECRETS_XCCONFIG` (same format as `Config/Secrets.example.xcconfig`):

```
WAYSTAGE_BUNDLE_ID = com.yourname.waystage
WAYSTAGE_TEAM_ID = ABCDE12345
GOOGLE_MAPS_API_KEY = AIza...
// Optional until the gateway is deployed:
WAYSTAGE_GATEWAY_URL =
WAYSTAGE_GATEWAY_TOKEN =
```

Never paste these values into issues, chats or commits.

### Build and install

1. **Actions → Release → Run workflow** with lane `beta` and **create_certificates** ticked
   (first run only — it creates your distribution certificate and profile in the certificates
   repo). Untick it for every later run.
2. After the run, App Store Connect processes the build (~10–30 minutes). In **TestFlight →
   Internal Testing**, add yourself as a tester (internal testers need no beta review).
3. On your iPhone, install **TestFlight** from the App Store, open the invitation email and
   install Waystage.

Test in a real car with a passenger operating the phone: voice guidance with the screen locked,
arrival at a stop, **Continue to next stop**, rerouting after a wrong turn, and resuming after
force-quitting the app.

## Keeping your Google key safe

The release build carries your Google Maps key inside the app (every app that uses Google Maps
does), so it can't be fully secret. Protect it instead, as described in [API_KEYS.md](API_KEYS.md):
restrict it to your bundle ID and to the three APIs Waystage uses, and set daily quotas and a
budget alert. No workflow publishes a built app on GitHub: the Release workflow sends it straight
to TestFlight.
