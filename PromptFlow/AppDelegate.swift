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
}
