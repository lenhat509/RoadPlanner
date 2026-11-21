import SwiftUI
import TripFeatures
import TripModels
import TripPlanner

/// The rest of the trip, adjusted from where the car is: what changes, the next stops, and (when
/// tonight's hotel is now reached late) stopping earlier tonight, at a hotel Waystage picks.
struct AdjustRestSheet: View {
    let adjustment: DriveViewModel.Adjustment
    let formatters: TripFormatters
    let isWorking: Bool
    let onStopEarlier: () -> Void
    let onUse: () -> Void
    let onCancel: () -> Void

    private var nextStops: [StopPresentation] {
        adjustment.plan.stops.dropFirst().prefix(8).map {
            StopPresentation(stop: $0, formatters: formatters, tankCapacityGallons: adjustment.plan.request.vehicle.tankCapacityGallons)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("What changes") {
                    ForEach(adjustment.changes, id: \.self) { line in
                        Text(line)
                    }
                }
                if adjustment.isLateTonight && !adjustment.stopsEarlierTonight {
                    Section {
                        Button(action: onStopEarlier) {
                            Label("Stop earlier tonight", systemImage: "bed.double")
                        }
                        .accessibilityIdentifier(AccessibilityID.Drive.stopEarlier)
                    } footer: {
                        Text("Tonight's hotel is now reached after your driving day ends. Stopping earlier finds a hotel near where today's driving ends; your own stops stay.")
                    }
                }
                Section("Next stops") {
                    ForEach(nextStops) { stop in
                        HStack(alignment: .top, spacing: Theme.Spacing.s) {
                            StopDot(kind: stop.kind, isPullOff: stop.isPullOff, size: 14)
                                .padding(.top, 4)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(stop.title).font(.subheadline.weight(.semibold))
                                Text(stop.timeText).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .overlay {
                if isWorking {
                    ProgressView()
                        .padding(Theme.Spacing.l)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .navigationTitle("Adjust the rest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
            .safeAreaInset(edge: .bottom) {
                BottomActionBar {
                    Button(action: onUse) {
                        Label("Use adjusted plan", systemImage: "checkmark")
                    }
                    .buttonStyle(.primary)
                    .disabled(isWorking)
                    .accessibilityIdentifier(AccessibilityID.Drive.useAdjustment)
                }
            }
        }
    }
}
