# App Store screenshots and app previews

The Release workflow's `create_version`, `update_version` and `release_all` lanes upload what's
here to the version page in App Store Connect (**App Previews and Screenshots**). Everything here
is public on the App Store.

| Folder | Files | Rules |
|---|---|---|
| `screenshots/en-US/` | `01-plan.png`, `02-routes.png`, … | Up to 10, shown in file-name order. The size picks the slot: 1179 × 2556 or 1206 × 2622 is the 6.1" slot, 1290 × 2796 or 1320 × 2868 the 6.9" slot. |
| `previews/en-US/` | `01-plan-and-drive_IPHONE_67.mp4`, … | Up to 3 per slot, 15–30 seconds, 886 × 1920. The file name must contain the slot: `IPHONE_67` (6.9"), `IPHONE_61` (6.1"). |

- **A folder with files** replaces that media in App Store Connect.
- **An empty or missing folder** leaves App Store Connect's media as it is (the previous version's
  carry over).
- **Taken on a real iPhone with real data:** see
  [docs/APP_STORE_RELEASE.md](../../docs/APP_STORE_RELEASE.md#screenshots). The sandbox
  screenshots in `fastlane/screenshots/` (made-up data) are never uploaded.
