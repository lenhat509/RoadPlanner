# Try Cadence on your iPhone

Two routes, both driven by GitHub Actions on GitHub's Mac machines (free for public repos), so
you don't need a Mac.

| | A. Browser preview (Appetize) | B. TestFlight |
|---|---|---|
| Apple account needed | No | Apple Developer Program ($99/year) |
| Time to first try | ~30 minutes | Account approval (up to 48 h), then ~1 hour |
| Runs | Streamed in Safari from a cloud iPhone simulator | Installed on your iPhone |
| GPS / voice guidance | Simulated drive (demo mode drives the route itself) | Real GPS, real voice guidance |

## Step 0 — make sure CI is green

Open **Actions** in the repository. The *CI* workflow runs on every push. The *iOS* job is the
first real compile of the app; if it fails, open the failing step, copy the error lines and fix
them (or share them). Both routes below need the app to compile.

## A. Browser preview with Appetize (no Apple account)

1. Create a free account at <https://appetize.io> and copy your API token
   (Account → API Token).
2. In GitHub: **Settings → Secrets and variables → Actions → New repository secret**:
   `APPETIZE_API_TOKEN` = your token.
3. *(Optional, for real maps and places)* add a secret `SECRETS_XCCONFIG` with the contents of
   your `Config/Secrets.xcconfig` (at minimum `GOOGLE_MAPS_API_KEY = …`; see
   [API_KEYS.md](API_KEYS.md)). Without it the app runs in **demo mode** with six sample cities
   (San Francisco, Los Angeles, Las Vegas, Denver, Chicago, New York) and a blank map background.
4. **Actions → Preview (Appetize) → Run workflow.**
5. When it finishes, open the run's **Summary**: it shows a link
   `https://appetize.io/app/<key>`. Open it in Safari on your iPhone and tap play.
6. Add a repository **variable** `APPETIZE_PUBLIC_KEY` with the key shown, so every later push
   to `main` updates the same link.

Things to try: Plan a trip → "Los" → Los Angeles, "Vegas" → Las Vegas → Plan trip → compare
Fastest/Cheapest/Balanced → Start trip. In demo mode the simulated car drives the route; at each
stop tap **Continue to next stop**. Close and reopen the app to see the trip resume.

## B. TestFlight on your iPhone

### One-time Apple setup

1. Join the **Apple Developer Program**: <https://developer.apple.com/programs/>.
2. **Certificates, IDs & Profiles → Identifiers → +** → App ID, e.g. `com.yourname.cadence`.
3. **App Store Connect → Apps → +** → New App: iOS, name (must be unique, e.g.
   "Cadence Road Trip <yourname>"), the bundle ID above, any SKU.
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
| Variable | `CADENCE_BUNDLE_ID` | e.g. `com.yourname.cadence` |
| Variable | `CADENCE_TEAM_ID` | your Team ID |

`SECRETS_XCCONFIG` (same format as `Config/Secrets.example.xcconfig`):

```
CADENCE_BUNDLE_ID = com.yourname.cadence
CADENCE_TEAM_ID = ABCDE12345
GOOGLE_MAPS_API_KEY = AIza...
// Optional until the gateway is deployed:
CADENCE_GATEWAY_URL =
CADENCE_GATEWAY_TOKEN =
```

Never paste these values into issues, chats or commits.

### Build and install

1. **Actions → Release → Run workflow** with lane `beta` and **create_certificates** ticked
   (first run only — it creates your distribution certificate and profile in the certificates
   repo). Untick it for every later run.
2. After the run, App Store Connect processes the build (~10–30 minutes). In **TestFlight →
   Internal Testing**, add yourself as a tester (internal testers need no beta review).
3. On your iPhone, install **TestFlight** from the App Store, open the invitation email and
   install Cadence.

Test in a real car with a passenger operating the phone: voice guidance with the screen locked,
arrival at a stop, **Continue to next stop**, rerouting after a wrong turn, and resuming after
force-quitting the app.
