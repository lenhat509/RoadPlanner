import CarPlay
import GoogleNavigation
import MapKit
import Observation
import TripFeatures
import TripModels
import UIKit

/// Waystage on the CarPlay screen. It shows the same drive as the iPhone (`AppEnvironment.drive`),
/// with Apple's CarPlay templates on top of the map:
///
/// * "Trips": the trip in progress and saved trips, to start or resume without the iPhone.
/// * Each leg opens as a trip preview (the next stop, time and distance) with a Start button; at a
///   stop, the preview of the next leg says "Continue".
/// * While guiding, the maneuver card and estimates come from Google's Navigation SDK
///   turn-by-turn feed, and its voice plays through the car. "End" (or CarPlay ending navigation,
///   e.g. when the car's own navigation starts) stops guidance at once and goes back to the
///   preview.
/// * Map buttons pan, zoom and re-center; nothing else on the map is tappable.
///
/// Planning (text entry) isn't offered on CarPlay.
@MainActor
final class CarPlayController: NSObject {
    private let interfaceController: CPInterfaceController
    private let window: CPWindow
    private let environment: AppEnvironment
    private let mapTemplate = CPMapTemplate()
    private let mapController: CarPlayMapViewController
    private let instructionOptions = GMSNavigationInstructionOptions()
    private let imageOptions = GMSNavigationStepInfoImageOptions()

    private var isConnected = false
    /// The leg shown (preview or navigation).
    private var currentTrip: CPTrip?
    private var previewKey: String?
    private var navigationSession: CPNavigationSession?
    private var lastStepNumber: Int?
    private var lastInstruction: GuidanceInstruction?
    private var estimatesKey: String?
    private var barButtonsKey: String?
    private var shownMessage: String?
    private var isShowingArrivalAlert = false

    init(interfaceController: CPInterfaceController, window: CPWindow, environment: AppEnvironment) {
        self.interfaceController = interfaceController
        self.window = window
        self.environment = environment
        mapController = CarPlayMapViewController(screen: window.screen, usesGoogle: environment.navigation != nil)
        super.init()
        imageOptions.screenMetrics = window.screen
        imageOptions.maneuverImageSize = .square48
        instructionOptions.imageOptions = imageOptions
    }

    func connect() {
        isConnected = true
        window.rootViewController = mapController
        mapTemplate.mapDelegate = self
        mapTemplate.mapButtons = makeMapButtons()
        interfaceController.setRootTemplate(mapTemplate, animated: false, completion: nil)
        if let navigation = environment.navigation {
            navigation.onSessionReady = { [weak self] session in self?.mapController.enableNavigation(with: session) }
            navigation.onNavInfo = { [weak self] info in self?.update(with: info) }
            if let session = navigation.session { mapController.enableNavigation(with: session) }
        }
        observe()
        refresh()
    }

    func disconnect() {
        isConnected = false
        navigationSession?.cancelTrip()
        navigationSession = nil
        environment.navigation?.onNavInfo = nil
        environment.navigation?.onSessionReady = nil
    }

    // MARK: Following the drive

    /// Refreshes the CarPlay screen whenever the drive changes.
    private func observe() {
        guard isConnected else { return }
        withObservationTracking {
            readDriveState()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.refresh()
                self?.observe()
            }
        }
    }

    private func readDriveState() {
        guard let drive = environment.drive else { return }
        _ = drive.mode
        _ = drive.stage
        _ = drive.trip
        _ = drive.route
        _ = drive.legProgress
        _ = drive.instruction
        _ = drive.statusMessage
        _ = drive.isMuted
        _ = drive.isHeadingToStart
    }

    private func refresh() {
        guard isConnected else { return }
        updateBarButtons()
        guard let drive = environment.drive else {
            endNavigation(finished: false)
            hidePreview()
            if isShowingArrivalAlert {
                isShowingArrivalAlert = false
                mapTemplate.dismissNavigationAlert(animated: true) { _ in }
            }
            return
        }
        showStatus(of: drive)
        switch drive.mode {
        case .completed:
            endNavigation(finished: true)
            hidePreview()
            showArrivalAlert(for: drive)
        case .atStop:
            endNavigation(finished: true)
            if let next = drive.trip.stopAfterTarget {
                showPreview(to: next, startTitle: "Continue", key: "after-\(drive.trip.progress.targetStopIndex)", drive: drive)
            }
        case .driving:
            guard let stop = drive.guidedStop else { return }
            if drive.stage == .preview {
                endNavigation(finished: false)
                let title = drive.isHeadingToStart ? "Go to start" : "Start"
                showPreview(to: stop, startTitle: title, key: "leg-\(stop.id)-\(drive.isHeadingToStart)", drive: drive)
            } else {
                hidePreview()
                startNavigationIfNeeded(to: stop, drive: drive)
                if !drive.engineDrawsGuidance { updateManeuvers(from: drive) }
                updateTripEstimates(drive)
            }
        }
    }

    // MARK: Trip preview

    private func showPreview(to stop: ItineraryStop, startTitle: String, key: String, drive: DriveViewModel) {
        if previewKey != key {
            previewKey = key
            estimatesKey = nil
            let trip = makeTrip(to: stop, drive: drive)
            currentTrip = trip
            let text = CPTripPreviewTextConfiguration(
                startButtonTitle: startTitle, additionalRoutesButtonTitle: nil, overviewButtonTitle: nil
            )
            mapTemplate.showTripPreviews([trip], textConfiguration: text)
        }
        updateTripEstimates(drive)
    }

    private func hidePreview() {
        guard previewKey != nil else { return }
        previewKey = nil
        mapTemplate.hideTripPreviews()
    }

    private func makeTrip(to stop: ItineraryStop, drive: DriveViewModel) -> CPTrip {
        let destination = MKMapItem(placemark: MKPlacemark(coordinate: stop.place.coordinate.clCoordinate))
        destination.name = stop.place.name
        let kind = stop.isRoadsidePullOff ? "Rest break" : stop.kind.displayName
        let detail = StopPresentation(
            stop: stop, formatters: environment.dependencies.formatters,
            tankCapacityGallons: drive.trip.itinerary.request.vehicle.tankCapacityGallons
        ).detail
        let choice = CPRouteChoice(
            summaryVariants: [stop.place.name],
            additionalInformationVariants: [[kind, detail].compactMap { $0 }.joined(separator: " · ")],
            selectionSummaryVariants: [kind]
        )
        let trip = CPTrip(origin: MKMapItem.forCurrentLocation(), destination: destination, routeChoices: [choice])
        trip.userInfo = stop.id
        return trip
    }

    /// Time and distance left to the stop (only when they change noticeably).
    private func updateTripEstimates(_ drive: DriveViewModel) {
        guard let trip = currentTrip, let progress = drive.legProgress, drive.mode == .driving else { return }
        let key = "\(Int(progress.timeRemaining / 60))-\(Int(progress.distanceRemaining / 200))"
        guard key != estimatesKey else { return }
        estimatesKey = key
        mapTemplate.update(Self.estimates(meters: progress.distanceRemaining, seconds: progress.timeRemaining), for: trip, with: .default)
    }

    // MARK: Navigation

    private func startNavigationIfNeeded(to stop: ItineraryStop, drive: DriveViewModel) {
        guard navigationSession == nil else { return }
        let trip = currentTrip.flatMap { ($0.userInfo as? String) == stop.id ? $0 : nil } ?? makeTrip(to: stop, drive: drive)
        currentTrip = trip
        estimatesKey = nil
        lastStepNumber = nil
        lastInstruction = nil
        navigationSession = mapTemplate.startNavigationSession(for: trip)
        mapController.recenter(guiding: true)
    }

    private func endNavigation(finished: Bool) {
        guard let navigationSession else { return }
        if finished { navigationSession.finishTrip() } else { navigationSession.cancelTrip() }
        self.navigationSession = nil
        lastStepNumber = nil
        lastInstruction = nil
    }

    /// Google's turn-by-turn feed: the maneuver card and its estimates.
    private func update(with navInfo: GMSNavigationNavInfo) {
        guard let session = navigationSession, navInfo.navState == .enroute, let step = navInfo.currentStep else { return }
        if step.stepNumber != lastStepNumber {
            lastStepNumber = step.stepNumber
            var maneuvers = [maneuver(for: step, in: navInfo)]
            if let next = navInfo.remainingSteps.first { maneuvers.append(maneuver(for: next, in: navInfo)) }
            session.upcomingManeuvers = maneuvers
        }
        if let current = session.upcomingManeuvers.first {
            session.updateEstimates(
                CPTravelEstimates(
                    distanceRemaining: navInfo.roundedDistance(navInfo.distanceToCurrentStepMeters),
                    timeRemaining: navInfo.roundedTime(navInfo.timeToCurrentStepSeconds)
                ),
                for: current
            )
        }
    }

    private func maneuver(for step: GMSNavigationStepInfo, in navInfo: GMSNavigationNavInfo) -> CPManeuver {
        let maneuver = CPManeuver()
        maneuver.userInfo = step.stepNumber
        switch step.maneuver {
        case .destination:
            maneuver.instructionVariants = ["Your destination is ahead."]
        case .destinationLeft:
            maneuver.instructionVariants = ["Your destination is ahead on your left."]
        case .destinationRight:
            maneuver.instructionVariants = ["Your destination is ahead on your right."]
        default:
            let variants = navInfo.instructions(forStep: step, options: instructionOptions)
            if variants.isEmpty {
                maneuver.instructionVariants = [step.fullInstructionText]
            } else {
                maneuver.attributedInstructionVariants = variants
            }
        }
        maneuver.symbolImage = step.maneuverImage(with: imageOptions)
        maneuver.initialTravelEstimates = CPTravelEstimates(
            distanceRemaining: navInfo.roundedDistance(step.distanceFromPrevStepMeters),
            timeRemaining: navInfo.roundedTime(step.timeFromPrevStepSeconds)
        )
        return maneuver
    }

    /// Offline (demo): the simulation's maneuvers (made-up data).
    private func updateManeuvers(from drive: DriveViewModel) {
        guard let session = navigationSession, let instruction = drive.instruction else { return }
        if instruction.maneuver != lastInstruction?.maneuver || instruction.text != lastInstruction?.text {
            let maneuver = CPManeuver()
            maneuver.instructionVariants = [instruction.text]
            maneuver.symbolImage = UIImage(systemName: instruction.maneuver.symbolName)
            session.upcomingManeuvers = [maneuver]
        }
        lastInstruction = instruction
        if let current = session.upcomingManeuvers.first {
            session.updateEstimates(Self.estimates(meters: instruction.distanceToManeuver, seconds: 0), for: current)
        }
    }

    // MARK: Messages

    private func showStatus(of drive: DriveViewModel) {
        guard let message = drive.statusMessage else {
            shownMessage = nil
            return
        }
        guard message != shownMessage else { return }
        shownMessage = message
        // The first sentence: the rest can refer to the iPhone's screen.
        let sentence = message.components(separatedBy: ". ").first.map { $0.hasSuffix(".") ? $0 : $0 + "." } ?? message
        let alert = CPNavigationAlert(
            titleVariants: [sentence], subtitleVariants: [], image: nil,
            primaryAction: CPAlertAction(title: "OK", style: .cancel) { _ in }, secondaryAction: nil, duration: 8
        )
        mapTemplate.present(navigationAlert: alert, animated: true)
    }

    private func showArrivalAlert(for drive: DriveViewModel) {
        guard !isShowingArrivalAlert else { return }
        isShowingArrivalAlert = true
        let done = CPAlertAction(title: "Done", style: .default) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isShowingArrivalAlert = false
                Task { @MainActor [weak self] in
                    await drive.endTrip()
                    await self?.environment.endDrive()
                }
            }
        }
        let alert = CPNavigationAlert(
            titleVariants: ["You've arrived"], subtitleVariants: [drive.trip.itinerary.request.destination.name], image: nil,
            primaryAction: done, secondaryAction: nil, duration: 0
        )
        mapTemplate.present(navigationAlert: alert, animated: true)
    }

    // MARK: Buttons

    private func updateBarButtons() {
        let drive = environment.drive
        let guiding = drive.map { $0.mode == .driving && $0.stage == .navigating } ?? false
        let key = guiding ? "guiding-\(drive?.isMuted == true)" : "browsing"
        guard key != barButtonsKey else { return }
        barButtonsKey = key
        if guiding, let drive {
            let mute = CPBarButton(image: UIImage(systemName: drive.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") ?? UIImage()) { _ in
                MainActor.assumeIsolated { drive.isMuted.toggle() }
            }
            let overview = CPBarButton(image: UIImage(systemName: "point.topleft.down.to.point.bottomright.curvepath") ?? UIImage()) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.mapController.showRouteOverview() }
            }
            let end = CPBarButton(title: "End") { [weak self] _ in
                MainActor.assumeIsolated { self?.endGuidance() }
            }
            mapTemplate.leadingNavigationBarButtons = [mute, overview]
            mapTemplate.trailingNavigationBarButtons = [end]
        } else {
            let trips = CPBarButton(title: "Trips") { [weak self] _ in
                MainActor.assumeIsolated { self?.showTrips() }
            }
            mapTemplate.leadingNavigationBarButtons = [trips]
            mapTemplate.trailingNavigationBarButtons = []
        }
    }

    private func makeMapButtons() -> [CPMapButton] {
        [
            mapButton("dpad.fill") { [weak self] in self?.mapTemplate.showPanningInterface(animated: true) },
            mapButton("plus.magnifyingglass") { [weak self] in self?.mapController.zoom(in: true) },
            mapButton("minus.magnifyingglass") { [weak self] in self?.mapController.zoom(in: false) },
            mapButton("location.fill") { [weak self] in
                guard let self else { return }
                let guiding = self.environment.drive.map { $0.mode == .driving && $0.stage == .navigating } ?? false
                self.mapController.recenter(guiding: guiding)
            },
        ]
    }

    private func mapButton(_ symbol: String, action: @escaping @MainActor () -> Void) -> CPMapButton {
        let button = CPMapButton { _ in MainActor.assumeIsolated { action() } }
        button.image = UIImage(systemName: symbol)
        return button
    }

    /// "End": stops guidance at once; the leg's preview comes back.
    private func endGuidance() {
        endNavigation(finished: false)
        guard let drive = environment.drive else { return }
        Task { await drive.pauseGuidance() }
    }

    // MARK: Trips

    private func showTrips() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let list = CPListTemplate(title: "Trips", sections: await self.tripSections())
            self.interfaceController.pushTemplate(list, animated: true, completion: nil)
        }
    }

    private func tripSections() async -> [CPListSection] {
        guard environment.isReadyToDriveWithoutPhone else {
            // Not phrased as an instruction to pick up the phone (CarPlay rules).
            let item = CPListItem(
                text: "Waystage isn't set up yet",
                detailText: "The terms of use and the driving safety notice are accepted in Waystage before the first drive."
            )
            return [CPListSection(items: [item])]
        }
        let repository = environment.dependencies.repository
        let active = try? await repository.loadActiveTrip()
        let saved = (try? await repository.savedItineraries()) ?? []
        var sections: [CPListSection] = []
        if let active, active.progress.phase != .completed {
            let item = CPListItem(text: Self.title(of: active.itinerary), detailText: progressText(of: active))
            item.handler = { [weak self] _, completion in
                Task { @MainActor [weak self] in
                    await self?.drive(active, makeActive: false)
                    completion()
                }
            }
            sections.append(CPListSection(items: [item], header: "In progress", sectionIndexTitle: nil))
        }
        // Plans saved over 30 days ago are planned again on the iPhone (that needs text review).
        let drivable = saved.filter { $0.id != active?.itinerary.id && !GoogleContentRetention.isOutline($0) }
        let plans = drivable.prefix(12).map { itinerary in
            let item = CPListItem(text: Self.title(of: itinerary), detailText: summary(of: itinerary))
            item.handler = { [weak self] _, completion in
                Task { @MainActor [weak self] in
                    guard let self else { return completion() }
                    // Place names are fetched again by place ID (they aren't kept on the phone).
                    let full = await self.environment.dependencies.repository.withDetails(itinerary)
                    await self.drive(ActiveTrip(itinerary: full), makeActive: true)
                    completion()
                }
            }
            return item
        }
        if !plans.isEmpty { sections.append(CPListSection(items: Array(plans), header: "Saved trips", sectionIndexTitle: nil)) }
        if sections.isEmpty {
            sections.append(CPListSection(items: [CPListItem(text: "No trips yet", detailText: "Trips you plan in Waystage appear here.")]))
        }
        return sections
    }

    /// Opens drive mode for `trip` (also on the iPhone) without the iPhone's help.
    private func drive(_ trip: ActiveTrip, makeActive: Bool) async {
        if makeActive {
            // A saved plan becomes the trip in progress, as when it's started on the iPhone.
            try? await environment.dependencies.repository.saveActiveTrip(trip)
        }
        await environment.beginDrive(trip, asksForTerms: false)
        await environment.drive?.start()
        interfaceController.popToRootTemplate(animated: true, completion: nil)
        refresh()
    }

    private static func title(of itinerary: Itinerary) -> String {
        "\(itinerary.request.origin.name) → \(itinerary.request.destination.name)"
    }

    private func progressText(of trip: ActiveTrip) -> String {
        guard trip.progress.phase != .notStarted, let next = trip.targetStop else { return "Not started" }
        return trip.progress.phase == .atStop ? "At \(next.place.name)" : "Next: \(next.place.name)"
    }

    private func summary(of itinerary: Itinerary) -> String {
        let formatters = environment.dependencies.formatters
        let stops = max(0, itinerary.stops.count - 2)
        return "\(formatters.distance(itinerary.totals.distanceMeters)) · \(stops) stop\(stops == 1 ? "" : "s")"
    }

    private static func estimates(meters: Double, seconds: TimeInterval) -> CPTravelEstimates {
        let metric = Locale.current.measurementSystem == .metric
        let distance = Measurement(value: meters, unit: UnitLength.meters).converted(to: metric ? .kilometers : .miles)
        return CPTravelEstimates(distanceRemaining: distance, timeRemaining: seconds)
    }
}

extension CarPlayController: CPMapTemplateDelegate {
    nonisolated func mapTemplate(_ mapTemplate: CPMapTemplate, startedTrip trip: CPTrip, using routeChoice: CPRouteChoice) {
        MainActor.assumeIsolated {
            guard let drive = environment.drive else { return }
            hidePreview()
            Task { @MainActor [weak self] in
                switch drive.mode {
                case .atStop: await drive.continueToNextStop(startNavigating: true)
                case .driving: await drive.beginNavigation()
                case .completed: break
                }
                self?.refresh()
            }
        }
    }

    /// CarPlay ended navigation (e.g. the car's own navigation started): stop guidance at once.
    nonisolated func mapTemplateDidCancelNavigation(_ mapTemplate: CPMapTemplate) {
        MainActor.assumeIsolated {
            navigationSession = nil
            environment.navigation?.stopGuidance()
            guard let drive = environment.drive else { return }
            Task { await drive.pauseGuidance() }
        }
    }

    nonisolated func mapTemplate(_ mapTemplate: CPMapTemplate, panWith direction: CPMapTemplate.PanDirection) {
        MainActor.assumeIsolated { mapController.pan(direction) }
    }

    nonisolated func mapTemplate(_ mapTemplate: CPMapTemplate, shouldShowNotificationFor maneuver: CPManeuver) -> Bool {
        true
    }

    nonisolated func mapTemplate(
        _ mapTemplate: CPMapTemplate, shouldUpdateNotificationFor maneuver: CPManeuver, with travelEstimates: CPTravelEstimates
    ) -> Bool {
        true
    }

    nonisolated func mapTemplate(_ mapTemplate: CPMapTemplate, shouldShowNotificationFor navigationAlert: CPNavigationAlert) -> Bool {
        true
    }
}
