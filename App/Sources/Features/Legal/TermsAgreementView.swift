import SwiftUI
import TripFeatures
import TripPersistence

/// "Before you start": what to know before relying on a plan, agreed to once (and again when
/// the terms change). Shown on first launch, after the intro; it can't be dismissed otherwise.
struct TermsAgreementView: View {
    let onAgree: () -> Void
    @State private var showsTerms = false

    /// Needed until the current terms are agreed to. UI tests skip it unless they ask for it.
    static func isRequired(mode: AppEnvironment.Mode, arguments: [String], preferences: UserPreferences) -> Bool {
        if mode == .uiTest && !arguments.contains(LaunchArgument.showTerms) { return false }
        return TermsAgreement.isNeeded(preferences)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("Before you start")
                            .font(.largeTitle.bold())
                        Text("Waystage plans long drives from start to finish. A few things to know before you rely on a plan:")
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                        ForEach(Disclosures.keyPoints) { point in
                            HStack(alignment: .top, spacing: Theme.Spacing.s) {
                                Image(systemName: point.systemImage)
                                    .font(.title3)
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 30)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(point.title)
                                        .font(.headline)
                                    Text(point.detail)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Button("Read the Terms of Use") { showsTerms = true }
                            .accessibilityIdentifier(AccessibilityID.Terms.readTerms)
                        Link("Google Maps Terms of Service", destination: Disclosures.googleMapsTermsURL)
                        Link("Waystage Privacy Policy", destination: AppLinks.privacyPolicy)
                        Link("Google Privacy Policy", destination: Disclosures.googlePrivacyURL)
                    }
                    .font(.subheadline.weight(.semibold))
                    .tint(Theme.accent)
                }
                .padding(Theme.Spacing.l)
            }
            BottomActionBar {
                VStack(spacing: Theme.Spacing.xs) {
                    Text(Disclosures.agreementLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Agree and continue", action: onAgree)
                        .buttonStyle(.primary)
                        .accessibilityIdentifier(AccessibilityID.Terms.agree)
                }
            }
        }
        .background(Theme.canvas.ignoresSafeArea())
        .sheet(isPresented: $showsTerms) {
            NavigationStack {
                TermsOfUseView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showsTerms = false }
                        }
                    }
            }
        }
    }
}

/// The full Terms of Use (the same text as docs/TERMS_OF_USE.md).
struct TermsOfUseView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Text("Last updated: \(Disclosures.termsLastUpdated)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(Array(Disclosures.termsOfUse.enumerated()), id: \.offset) { index, section in
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("\(index + 1). \(section.title)")
                            .font(.headline)
                        ForEach(section.paragraphs, id: \.self) { paragraph in
                            Text(paragraph)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Link("Google Maps Terms of Service", destination: Disclosures.googleMapsTermsURL)
                    Link("Google Privacy Policy", destination: Disclosures.googlePrivacyURL)
                    Link("Waystage Privacy Policy", destination: AppLinks.privacyPolicy)
                }
                .font(.subheadline.weight(.semibold))
                .tint(Theme.accent)
            }
            .padding(Theme.Spacing.m)
        }
        .background(Theme.canvas.ignoresSafeArea())
        .navigationTitle("Terms of Use")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier(AccessibilityID.Terms.document)
    }
}
