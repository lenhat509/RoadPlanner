// Shared by the app and the UI tests (compiled into both targets) so identifiers never drift.

enum AccessibilityID {
    enum Home {
        static let planTrip = "home.planTrip"
        static let resume = "home.resume"
        static let discard = "home.discard"
        static let settings = "home.settings"
        static let savedTrip = "home.savedTrip"
        static let demoBanner = "home.demoBanner"
    }

    enum Plan {
        static let origin = "plan.origin"
        static let destination = "plan.destination"
        static let currentLocation = "plan.currentLocation"
        static let swap = "plan.swap"
        static let departure = "plan.departure"
        static let arriveByToggle = "plan.arriveByToggle"
        static let mpg = "plan.mpg"
        static let tank = "plan.tank"
        static let minimumFuel = "plan.minimumFuel"
        static let fuelGrade = "plan.fuelGrade"
        static let customRestToggle = "plan.customRestToggle"
        static let restInterval = "plan.restInterval"
        static let goal = "plan.goal"
        static let submit = "plan.submit"
        static let progress = "plan.progress"
        static let cancel = "plan.cancel"
        static let addStop = "plan.addStop"
        static func stop(_ index: Int) -> String { "plan.stop.\(index)" }
        static func stopStay(_ index: Int) -> String { "plan.stopStay.\(index)" }
        static func stopMenu(_ index: Int) -> String { "plan.stopMenu.\(index)" }
        static func suggestion(_ text: String) -> String { "plan.suggestion.\(text)" }
    }

    enum Results {
        static let map = "results.map"
        static let legend = "results.legend"
        static let start = "results.start"
        static let startNote = "results.startNote"
        static let estimateNote = "results.estimateNote"
        static let stopNotice = "results.stopNotice"
        static let save = "results.save"
        static let openInGoogleMaps = "results.openInGoogleMaps"
        static let warnings = "results.warnings"
        static let timeline = "results.timeline"
        static func option(_ goal: String) -> String { "results.option.\(goal)" }
        /// The routes found, best first.
        static func route(_ index: Int) -> String { "results.route.\(index)" }
        static func day(_ index: Int) -> String { "results.day.\(index)" }
        static let keepStop = "results.keepStop"
        static let removeStop = "results.removeStop"
        static func hotelChoice(_ index: Int) -> String { "results.hotelChoice.\(index)" }
        static let undo = "results.undo"
        static let updating = "results.updating"
        static let addStopHere = "results.addStopHere"
        static let addStopSearch = "results.addStopSearch"
        static let addStopConfirm = "results.addStopConfirm"
    }

    enum Drive {
        static let banner = "drive.banner"
        static let nextStop = "drive.nextStop"
        static let continueToNext = "drive.continue"
        static let arrivalCard = "drive.arrivalCard"
        static let menu = "drive.menu"
        static let planRestAgain = "drive.planRestAgain"
        static let replanSuggestion = "drive.replanSuggestion"
        static let arrived = "drive.arrived"
        static let skip = "drive.skip"
        static let mute = "drive.mute"
        static let endTrip = "drive.endTrip"
        static let exit = "drive.exit"
        static let preview = "drive.preview"
        static let startNavigation = "drive.start"
        static let startHere = "drive.startHere"
        static let recenter = "drive.recenter"
        static let overview = "drive.overview"
        static let done = "drive.done"
        static let completedCard = "drive.completedCard"
        static let safetyAccept = "drive.safetyAccept"
    }

    enum Terms {
        static let agree = "terms.agree"
        static let readTerms = "terms.read"
        static let document = "terms.document"
    }

    enum Settings {
        static let terms = "settings.terms"
        static let restInterval = "settings.restInterval"
        static let voiceGuidance = "settings.voiceGuidance"
        static let reset = "settings.reset"
    }
}
