import CarPlay
import UIKit

/// The CarPlay screen (declared in Info.plist). The app can be launched on CarPlay alone, so the
/// shared `AppEnvironment` is used rather than anything from the iPhone's scene.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var controller: CarPlayController?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
        to window: CPWindow
    ) {
        let controller = CarPlayController(interfaceController: interfaceController, window: window, environment: .shared)
        self.controller = controller
        controller.connect()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController,
        from window: CPWindow
    ) {
        controller?.disconnect()
        controller = nil
    }
}
