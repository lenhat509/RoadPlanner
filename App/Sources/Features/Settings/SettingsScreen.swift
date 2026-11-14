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
        Form {
            Section {
                LabeledContent("Fuel economy") {
                    TextField("MPG", value: $model.preferences.vehicle.milesPerGallon, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Tank size (gal)") {
                    TextField("Gallons", value: $model.preferences.vehicle.tankCapacityGallons, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                Picker("Fuel grade", selection: $model.preferences.vehicle.fuelType) {
                    ForEach(FuelType.allCases) { Text($0.title).tag($0) }
                }
                Stepper(value: $model.minimumFuelPercent, in: 5...50, step: 5) {
                    Text("Refuel before \(Int(model.minimumFuelPercent))% left")
                }
            } header: {
                Text("Your car")
            } footer: {
                let grade = model.preferences.vehicle.fuelType
                Text("\(grade.ethanolDescription) \(grade.planningNote) \(PlanTripScreen.unlistedGradesNote)")
            }

            Section {
                Stepper(value: $model.restIntervalHours, in: 0.5...5, step: 0.25) {
                    Text("Break at least every \(PlanTripScreen.hoursText(model.restIntervalHours))")
                }
                .accessibilityIdentifier(AccessibilityID.Settings.restInterval)
                Stepper(value: $model.restBreakMinutes, in: 10...60, step: 5) {
                    Text("Breaks last \(Int(model.restBreakMinutes)) min")
                }
            } header: {
                Text("Breaks")
            } footer: {
                Text("Waystage never plans more non-stop driving than this. The recommended default is a break every 2–3 hours.")
            }

            Section("Driving day") {
                Stepper(value: $model.maxDailyDrivingHours, in: 2...14, step: 0.5) {
                    Text("Up to \(PlanTripScreen.hoursText(model.maxDailyDrivingHours)) of driving")
                }
                Picker("Start driving at", selection: $model.dayStartHour) {
                    ForEach(4...12, id: \.self) { Text(Self.hourText($0)).tag($0) }
                }
                Picker("Stop for the night by", selection: $model.dayEndHour) {
                    ForEach(15...23, id: \.self) { Text(Self.hourText($0)).tag($0) }
                }
            }

            Section {
                Picker("Default goal", selection: $model.preferences.goal) {
                    ForEach(OptimizationGoal.allCases) { Text($0.displayName).tag($0) }
                }
                Stepper(value: $model.preferences.policy.valueOfTimePerHour, in: 0...200, step: 5) {
                    Text("Your time is worth $\(Int(model.preferences.policy.valueOfTimePerHour))/hour")
                }
            } header: {
                Text("Planning")
            } footer: {
                Text("“Balanced” plans trade time against money using this value.")
            }

            Section("Guidance") {
                Toggle("Voice guidance", isOn: $model.preferences.voiceGuidanceEnabled)
                    .accessibilityIdentifier(AccessibilityID.Settings.voiceGuidance)
            }

            Section {
                NavigationLink("Terms of Use") { TermsOfUseView() }
                    .accessibilityIdentifier(AccessibilityID.Settings.terms)
                Link("Privacy Policy", destination: AppLinks.privacyPolicy)
                Link("Google Maps Terms of Service", destination: Disclosures.googleMapsTermsURL)
                Link("Google Privacy Policy", destination: Disclosures.googlePrivacyURL)
                Link("Help & Support", destination: AppLinks.support)
                LabeledContent("Version", value: AppLinks.versionString)
            } header: {
                Text("About")
            } footer: {
                Text(
                    "Maps, directions and places by Google Maps. Hotel rates via Expedia. Regional fuel price averages "
                        + "from the U.S. Energy Information Administration. Plans are suggestions and costs are estimates; "
                        + "Waystage doesn't book anything."
                )
            }

            Section {
                Button("Reset to defaults", role: .destructive) { confirmsReset = true }
                    .accessibilityIdentifier(AccessibilityID.Settings.reset)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.canvas.ignoresSafeArea())
        .navigationTitle("Settings")
        .confirmationDialog("Reset all settings to their defaults?", isPresented: $confirmsReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { model.resetToDefaults() }
        }
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
