import UIKit

/// Retained for the `@UIApplicationDelegateAdaptor` in `SteadyEyeApp`, which
/// requires a concrete delegate type. Previously this also deferred Facebook
/// SDK initialization by 500ms; the Facebook SDK has been removed, so launch
/// now has nothing to defer.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        return true
    }

    /// Portrait everywhere, as Info.plist declares — except on iPhone Duo's
    /// inner display, which rotates whatever an app declares on hardware
    /// (Apple's iPhone Duo tech talk; confirmed by Duo reports), while the
    /// simulator holds the declared lock. Declaring every orientation there
    /// makes both behave the same. Recording never shows there (folded only).
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        guard DuoDisplayMonitor.deviceHasHinge,
              let window,
              min(window.bounds.width, window.bounds.height) >= 600 else { return .portrait }
        return .all
    }
}
