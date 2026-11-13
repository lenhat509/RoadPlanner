# Test run history

Every execution of `scripts/test-all.sh` (locally, in the pre-push hook, or in CI) appends one
row per suite. Per-run details, including the names of failing tests, are in `runs/`.

| When (UTC) | Commit | Suite | Result | Tests | Duration | Details |
|---|---|---|---|---|---|---|
| 2026-11-13 03:54:47Z | `6b1795a+dirty` | core (Swift package) | ✅ pass | 173 tests | 23s | [runs/20261113T035447Z.md](runs/20261113T035447Z.md) |
| 2026-11-13 03:54:47Z | `6b1795a+dirty` | gateway (lint+types) | ✅ pass | - | 3s | [runs/20261113T035447Z.md](runs/20261113T035447Z.md) |
| 2026-11-13 03:54:47Z | `6b1795a+dirty` | gateway (vitest) | ✅ pass | 66 passed (66) | 1s | [runs/20261113T035447Z.md](runs/20261113T035447Z.md) |
| 2026-11-13 03:54:47Z | `6b1795a+dirty` | iOS package tests | ⏭️ skipped | - | 0s | [runs/20261113T035447Z.md](runs/20261113T035447Z.md) |
| 2026-11-13 03:54:47Z | `6b1795a+dirty` | iOS app unit + UI tests | ⏭️ skipped | - | 0s | [runs/20261113T035447Z.md](runs/20261113T035447Z.md) |
| 2026-11-13 04:01:15Z | `7c30b8a` | core (Swift package) | ✅ pass | 173 tests | 21s | [runs/20261113T040115Z.md](runs/20261113T040115Z.md) |
| 2026-11-13 04:01:15Z | `7c30b8a` | gateway (lint+types) | ✅ pass | - | 2s | [runs/20261113T040115Z.md](runs/20261113T040115Z.md) |
| 2026-11-13 04:01:15Z | `7c30b8a` | gateway (vitest) | ✅ pass | 66 passed (66) | 2s | [runs/20261113T040115Z.md](runs/20261113T040115Z.md) |
| 2026-11-13 04:01:15Z | `7c30b8a` | iOS package tests | ⏭️ skipped | - | 0s | [runs/20261113T040115Z.md](runs/20261113T040115Z.md) |
| 2026-11-13 04:01:15Z | `7c30b8a` | iOS app unit + UI tests | ⏭️ skipped | - | 0s | [runs/20261113T040115Z.md](runs/20261113T040115Z.md) |
