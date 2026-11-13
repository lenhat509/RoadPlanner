# Contributing

## Workflow

1. Branch from `main`: `feature/<short-name>` or `fix/<short-name>`.
2. **Write the failing test first**, then the code. Keep the change focused.
3. `make test-quick` (also runs automatically on `git push`); `make test` on a Mac for UI changes.
4. Commit with [Conventional Commits](https://www.conventionalcommits.org/):
   `feat(planner): …`, `fix(drive): …`, `test: …`, `docs: …`, `chore: …`.
5. Open a pull request; CI must be green. Update `CHANGELOG.md` for user-visible changes.

## Code style

* Swift: [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/),
  SwiftLint (`.swiftlint.yml`) and SwiftFormat (`.swiftformat`). Document public APIs with `///`.
* Keep logic out of SwiftUI views: put it in `TripFeatures` view models (testable on any platform).
* Domain code depends on ports, never on concrete services.
* Package code is Swift 6 language mode: no data races, no `@unchecked Sendable` without a lock
  and a comment explaining why it's safe.
* TypeScript (gateway): ESLint + `tsc --strict`; validate all input with zod.
* No secrets, personal data or generated build output in commits.

## Definition of done

- [ ] Tests for the new behaviour (unit; integration/UI where the flow changes)
- [ ] `make test` green and logged in `test-logs/`
- [ ] Lint clean
- [ ] Docs updated (architecture, algorithm, privacy, if affected)
