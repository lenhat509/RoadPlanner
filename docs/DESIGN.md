# Design rules

Waystage looks plain and practical, like a road atlas. Similar elements look the same on every
screen; use the shared pieces below rather than styling a screen's own.

| Element | Look | Use |
|---|---|---|
| Page | Neutral grey (`Theme.canvas`), 16 pt margins | `BoxPage` for settings-style pages |
| Box (card, group of rows, note, panel over a map, map) | White, 1 pt border (`Theme.cardStroke`), 8 pt corners (`Theme.Radius.card`), no shadow (a light one only over a map) | `.card()`, `BoxSection` + `BoxRow`, `boxListRow()` in a `List` that reorders |
| Selectable box (plan, route, goal) | A box; selected: 2 pt green border | `.selectableBox(isSelected:)` |
| Primary button | Solid green (`Theme.brand`), white text, 50 pt tall, 6 pt corners | `.buttonStyle(.primary)` |
| Secondary button | White, border, primary-colour text, 50 pt tall, 6 pt corners | `.buttonStyle(.secondary)` |
| Icon-only button | White square, border, 6 pt corners: 40 pt (50 pt in drive mode, beside 50 pt buttons); red to leave drive mode | `IconButtonLabel`, `MapControlButton` |
| Buttons side by side | One line, same height | `HStack` of the styles above |
| Text input | Grey fill (`Theme.mutedFill`), 6 pt corners | `NumberTile`, `NumberFieldRow` |
| Choice from a list | Value with a green up-down mark; tapping lists the options at the bottom | `OptionTile` (form), `ChoiceRow` (box row) |
| Switch | Green (`Theme.accent`) | `Toggle(...).tint(Theme.accent)` |
| Link or action row | Title, trailing chevron (another screen) or ↗ (website); destructive in red | `BoxRowLabel` |
| Section title | Small grey capitals above a box | `SectionLabel` |
| Note | Footnote, grey, under its box | `BoxSection(footer:)` or `.font(.footnote).foregroundStyle(.secondary)` |
| Stop in a list | Coloured dot 18 pt (visits: numbered pin 22 pt), title semibold, details in caption grey | `StopDot`, `NumberedPin` |
| Stop marker | All colour: no ring in lists and legends; a 1 pt ring in the box's colour over a line (trip timelines); a 1.5 pt white ring on maps. Timeline dots are as tall as the timeline (16 pt), 80 % for stops between the ends | `StopDot(ring:)`, `TripRibbonView` |
| Type | The system font (never the rounded design); numbers `monospacedDigit()` | |

Colours carry meaning: green for actions and selection, the stop colours for stop kinds (deep
Okabe–Ito hues, each at least 4:1 against white: teal rest, amber fuel, purple night, blue visit,
red destination, near-black start, grey roadside break), blue for routes on the map, orange for warnings, red for leaving or removing. No gradients.

The system `List` and `Form` grouped look is not used: iOS draws its sections with its own large
rounded corners and background, which can't be restyled. A list that needs the system's
drag-to-reorder keeps `List` in the plain style, with each row drawn by `boxListRow()`.
