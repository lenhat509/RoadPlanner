import SwiftUI

// The app's own grouped sections, used instead of the system `List`/`Form` look (whose rounded
// grouped sections and colours the app can't change): a titled box of rows with thin dividers, on
// the app's grey page, with the same small corners and borders as every other box.

/// A page of box sections: scrolls, on the app's background, with the usual margins.
struct BoxPage<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                content()
            }
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.m)
        }
        .background(Theme.canvas.ignoresSafeArea())
    }
}

/// A titled group of rows in one box: an optional label above, the rows (separated by
/// `BoxRow`'s dividers) in a white box with a thin border, and an optional note below.
struct BoxSection<Content: View, Header: View>: View {
    var footer: String?
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            header()
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            )
            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Spacing.xxs)
            }
        }
    }
}

extension BoxSection where Header == BoxSectionTitle {
    /// A section with a plain title (or none).
    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.footer = footer
        self.header = { BoxSectionTitle(title: title) }
        self.content = content
    }
}

/// A section's title above its box (nothing when there is no title).
struct BoxSectionTitle: View {
    let title: String?

    var body: some View {
        if let title {
            SectionLabel(title: title)
                .padding(.horizontal, Theme.Spacing.xxs)
        }
    }
}

/// A row in a box: padded, at least 44 points tall, with a thin divider below unless it is the
/// section's last row.
struct BoxRow<Content: View>: View {
    var isLast = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.vertical, Theme.Spacing.xs)
            if !isLast {
                Divider().padding(.leading, Theme.Spacing.m)
            }
        }
    }
}

/// A row's content for an action or a link: an icon (optional), the title, and a trailing mark
/// (a chevron for another screen, an arrow for a website).
struct BoxRowLabel: View {
    let title: String
    var systemImage: String?
    var trailingSymbol: String? = "chevron.right"
    var tint: Color = .primary

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 24)
            }
            Text(title)
                .foregroundStyle(tint)
                .multilineTextAlignment(.leading)
            Spacer(minLength: Theme.Spacing.xs)
            if let trailingSymbol {
                Image(systemName: trailingSymbol)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Lists that keep `List` (reordering)

extension View {
    /// A row of a plain `List` drawn as one of the app's boxes: a white box with small corners and a
    /// thin border (tinted for a change, e.g. green to be added or red to be removed). For lists that
    /// need the system's drag-to-reorder, without the grouped list look.
    func boxListRow(tint: Color? = nil) -> some View {
        listRowInsets(EdgeInsets(top: Theme.Spacing.s, leading: Theme.Spacing.m + Theme.Spacing.s,
                                 bottom: Theme.Spacing.s, trailing: Theme.Spacing.m + Theme.Spacing.s))
            .listRowSeparator(.hidden)
            .listRowBackground(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Theme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                            .fill((tint ?? .clear).opacity(0.10))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                            .strokeBorder(tint ?? Theme.cardStroke, lineWidth: 1)
                    )
                    .padding(.horizontal, Theme.Spacing.m)
                    .padding(.vertical, Theme.Spacing.xxs)
            )
    }

    /// A row of a plain `List` with no box (buttons, titles and notes between the boxes).
    func plainListRow() -> some View {
        listRowInsets(EdgeInsets(top: Theme.Spacing.xs, leading: Theme.Spacing.m, bottom: Theme.Spacing.xs, trailing: Theme.Spacing.m))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

// MARK: - Controls in box rows

/// A setting chosen from a list, in a box row: its name, the choice and the same up-down mark as
/// the plan form's option tiles; like them, tapping lists the options at the bottom of the screen.
struct ChoiceRow<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let optionTitle: (Value) -> String
    @State private var isChoosing = false

    var body: some View {
        Button { isChoosing = true } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Text(title).foregroundStyle(.primary)
                Spacer(minLength: Theme.Spacing.xs)
                Text(optionTitle(selection)).foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(optionTitle(selection))
        .confirmationDialog(title, isPresented: $isChoosing, titleVisibility: .visible) {
            ForEach(options, id: \.self) { option in
                Button(optionTitle(option)) { selection = option }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// A number typed in a box row: its name, and the number in a grey input box like the plan form's
/// number tiles, with its unit.
struct NumberFieldRow: View {
    let title: String
    let unit: String
    @Binding var value: Double

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text(title)
            Spacer(minLength: Theme.Spacing.xs)
            TextField(title, value: $value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .padding(.horizontal, Theme.Spacing.xs)
                .frame(width: 84, height: 36)
                .background(Theme.mutedFill, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            Text(unit)
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
        }
    }
}
