// swift-tools-version:6.0
//
// WaystageKit — platform-independent core of the Waystage road-trip planner.
//
// Every module here builds on iOS, macOS and Linux so that the planning engine,
// service adapters, navigation logic and view models can be unit-tested
// without a simulator. The iOS app target is a thin SwiftUI shell on top.
//
import PackageDescription

let package = Package(
    name: "WaystageKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TripModels", targets: ["TripModels"]),
        .library(name: "TripPlanner", targets: ["TripPlanner"]),
        .library(name: "TripServices", targets: ["TripServices"]),
        .library(name: "TripNavigation", targets: ["TripNavigation"]),
        .library(name: "TripPersistence", targets: ["TripPersistence"]),
        .library(name: "TripFeatures", targets: ["TripFeatures"]),
        .library(name: "TripSandbox", targets: ["TripSandbox"]),
    ],
    targets: [
        // Value types shared by every layer (no dependencies).
        .target(name: "TripModels"),
        // Pure planning domain: route profiles, candidate stops, optimizer, ports.
        .target(name: "TripPlanner", dependencies: ["TripModels"]),
        // Adapters for Google Maps Platform and the Waystage gateway (Expedia, EIA).
        .target(name: "TripServices", dependencies: ["TripModels", "TripPlanner"]),
        // Turn-by-turn guidance and trip progress state machine.
        .target(name: "TripNavigation", dependencies: ["TripModels"]),
        // Auto-saved trips and user preferences.
        .target(name: "TripPersistence", dependencies: ["TripModels"]),
        // Observable view models consumed by the SwiftUI app.
        .target(
            name: "TripFeatures",
            dependencies: ["TripModels", "TripPlanner", "TripNavigation", "TripPersistence"]
        ),
        // Deterministic offline fakes used by tests, previews and UI-test sandbox mode.
        .target(
            name: "TripSandbox",
            dependencies: ["TripModels", "TripPlanner", "TripNavigation", "TripServices", "TripPersistence", "TripFeatures"]
        ),

        .testTarget(name: "TripModelsTests", dependencies: ["TripModels"]),
        .testTarget(name: "TripPlannerTests", dependencies: ["TripPlanner", "TripSandbox"]),
        .testTarget(
            name: "TripServicesTests",
            dependencies: ["TripServices", "TripSandbox"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "TripNavigationTests", dependencies: ["TripNavigation", "TripSandbox"]),
        .testTarget(name: "TripPersistenceTests", dependencies: ["TripPersistence", "TripSandbox"]),
        .testTarget(name: "TripFeaturesTests", dependencies: ["TripFeatures", "TripSandbox"]),
        .testTarget(
            name: "IntegrationTests",
            dependencies: [
                "TripModels", "TripPlanner", "TripServices", "TripNavigation",
                "TripPersistence", "TripFeatures", "TripSandbox",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
