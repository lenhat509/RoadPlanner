import SwiftUI
import TripFeatures
import TripModels

/// Defaults for the car and driving preferences.
struct SettingsScreen: View {
    @State private var model: SettingsViewModel
    @State private var confirmsReset = false

    init(dependencies: AppDependencies) {
        _model = State(initialValue: SettingsViewModel(dependencies: dependencies))
    }

    var body: some View {
        BoxPage {
            BoxSection("Your car", footer: fuelNote) {
                BoxRow {
                    HStack {
                        Text("Fuel economy")
                        Spacer()
                        TextField("MPG", value: $model.preferences.vehicle.milesPerGallon, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 100)
                        Text("mpg").foregroundStyle(.secondary)
                    }
                }
                BoxRow {
                    HStack {
                        Text("Tank size")
                        Spacer()
                        TextField("Gallons", value: $model.preferences.vehicle.tankCapacityGallons, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 100)
                        Text("gal").foregroundStyle(.secondary)
                    }
                }
                BoxRow {
                    choice("Fuel grade", selection: $model.preferences.vehicle.fuelType) {
                        ForEach(FuelType.allCases) { Text($0.title).tag($0) }
                    }
                }
                BoxRow(isLast: true) {
                    Stepper(value: $model.minimumFuelPercent, in: 5...50, step: 5) {
                        Text("Refuel before \(Int(model.minimumFuelPercent))% left")
                    }
                }
            }

            BoxSection(
                "Breaks",
                footer: "Waystage never plans more non-stop driving than this. The recommended default is a break every 2–3 hours."
            ) {
                BoxRow {
                    Stepper(value: $model.restIntervalHours, in: 0.5...5, step: 0.25) {
                        Text("Break at least every \(PlanTripScreen.hoursText(model.restIntervalHours))")
                    }
                    .accessibilityIdentifier(AccessibilityID.Settings.restInterval)
                }
                BoxRow(isLast: true) {
                    Stepper(value: $model.restBreakMinutes, in: 10...60, step: 5) {
                        Text("Breaks last \(Int(model.restBreakMinutes)) min")
                    }
                }
            }

            BoxSection("Driving day") {
                BoxRow {
                    Stepper(value: $model.maxDailyDrivingHours, in: 2...14, step: 0.5) {
                        Text("Up to \(PlanTripScreen.hoursText(model.maxDailyDrivingHours)) of driving")
                    }
                }
                BoxRow {
                    choice("Start driving at", selection: $model.dayStartHour) {
                        ForEach(4...12, id: \.self) { Text(Self.hourText($0)).tag($0) }
                    }
                }
                BoxRow(isLast: true) {
                    choice("Stop for the night by", selection: $model.dayEndHour) {
                        ForEach(15...23, id: \.self) { Text(Self.hourText($0)).tag($0) }
                    }
                }
            }

            BoxSection("Planning") {
                BoxRow(isLast: true) {
                    choice("Default goal", selection: $model.preferences.goal) {
                        ForEach(OptimizationGoal.allCases) { Text($0.displayName).tag($0) }
                    }
                }
            }

            BoxSection("Guidance") {
                BoxRow(isLast: true) {
                    Toggle("Voice guidance", isOn: $model.preferences.voiceGuidanceEnabled)
                        .tint(Theme.brand)
                        .accessibilityIdentifier(AccessibilityID.Settings.voiceGuidance)
                }
            }

            BoxSection("About", footer: Self.creditsNote) {
                BoxRow {
                    NavigationLink { TermsOfUseView() } label: {
                        BoxRowLabel(title: "Terms of Use")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AccessibilityID.Settings.terms)
                }
                BoxRow { link("Privacy Policy", AppLinks.privacyPolicy) }
                BoxRow { link("Google Maps Terms of Service", Disclosures.googleMapsTermsURL) }
                BoxRow { link("Google Privacy Policy", Disclosures.googlePrivacyURL) }
                BoxRow { link("Help & Support", AppLinks.support) }
                BoxRow(isLast: true) {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(AppLinks.versionString).foregroundStyle(.secondary)
                    }
                }
            }

            BoxSection {
                BoxRow(isLast: true) {
                    Button { confirmsReset = true } label: {
                        BoxRowLabel(title: "Reset to defaults", trailingSymbol: nil, tint: Theme.danger)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AccessibilityID.Settings.reset)
                }
            }
        }
        .navigationTitle("Settings")
        .confirmationDialog("Reset all settings to their defaults?", isPresented: $confirmsReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { model.resetToDefaults() }
        }
    }

    private var fuelNote: String {
        let grade = model.preferences.vehicle.fuelType
        return "\(grade.ethanolDescription) \(grade.planningNote) \(PlanTripScreen.unlistedGradesNote)"
    }

    private static let creditsNote = "Maps, directions and places by Google Maps. Hotel rates via Expedia. Regional fuel price averages "
        + "from the U.S. Energy Information Administration. Plans are suggestions and costs are estimates; "
        + "Waystage doesn't book anything."

    /// A setting chosen from a list: its name, and the choice as a menu at the trailing edge.
    private func choice<Value: Hashable, Options: View>(
        _ title: String, selection: Binding<Value>, @ViewBuilder options: () -> Options
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Picker(title, selection: selection, content: options)
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(Theme.accent)
        }
    }

    /// A website opened in the browser.
    private func link(_ title: String, _ url: URL) -> some View {
        Link(destination: url) {
            BoxRowLabel(title: title, trailingSymbol: "arrow.up.right")
        }
        .buttonStyle(.plain)
    }

    static func hourText(_ hour: Int) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("j")
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return formatter.string(from: date)
    }
}

/// The public website (built from docs/ by scripts/build_site.py, published by the Website
/// workflow to GitHub Pages). The same URLs are in fastlane/metadata/en-US/*_url.txt.
enum AppLinks {
    static let website = URL(string: "https://lenhat509.github.io/RoadPlanner/")!
    static let privacyPolicy = URL(string: "privacy/", relativeTo: website)!.absoluteURL
    static let support = URL(string: "support/", relativeTo: website)!.absoluteURL
    static let terms = URL(string: "terms/", relativeTo: website)!.absoluteURL

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
