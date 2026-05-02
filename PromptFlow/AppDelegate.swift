import UIKit
import FBSDKCoreKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Defer FBSDK init to ~500ms after first frame. The dominant cost
        // here is `ApplicationDelegate.shared.application(...)`, which
        // takes hundreds of ms on cold start. Splash / first UI frame
        // appears immediately while the user reads the welcome screen;
        // FBSDK comes online during that window. Deep-link handling for
        // links arriving in this gap is the trade — acceptable since the
        // app's deep-link surface is minimal.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Settings.shared.appID = "1512546243786316"
            if let clientToken = SecretsManager.facebookClientToken() {
                Settings.shared.clientToken = clientToken
            }
            ApplicationDelegate.shared.application(
                application,
                didFinishLaunchingWithOptions: launchOptions
            )
        }
        return true
    }
}
