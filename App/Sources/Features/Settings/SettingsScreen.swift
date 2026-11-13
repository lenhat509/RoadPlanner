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
            Section("Your car") {
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
                Picker("Fuel type", selection: $model.preferences.vehicle.fuelType) {
                    ForEach(FuelType.allCases) { Text($0.displayName).tag($0) }
                }
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
                Text("Cadence never plans more non-stop driving than this. The recommended default is a break every 2–3 hours.")
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
                Link("Privacy Policy", destination: AppLinks.privacyPolicy)
                Link("Help & Support", destination: AppLinks.support)
                LabeledContent("Version", value: AppLinks.versionString)
            } header: {
                Text("About")
            } footer: {
                Text("Maps, directions and places by Google. Hotel rates via Expedia. Regional fuel price averages from the U.S. Energy Information Administration. Prices are estimates.")
            }

            Section {
                Button("Reset to defaults", role: .destructive) { confirmsReset = true }
                    .accessibilityIdentifier(AccessibilityID.Settings.reset)
            }
        }
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

/// Public URLs (also listed in fastlane metadata). Replace before release.
enum AppLinks {
    static let privacyPolicy = URL(string: "https://cadence.example.com/privacy")!
    static let support = URL(string: "https://cadence.example.com/support")!

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
