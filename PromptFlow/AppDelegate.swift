import UIKit
import FBSDKCoreKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        Settings.shared.appID = "1512546243786316"
        if let clientToken = SecretsManager.facebookClientToken() {
            Settings.shared.clientToken = clientToken
        }
        ApplicationDelegate.shared.application(
            application,
            didFinishLaunchingWithOptions: launchOptions
        )
        return true
    }
}
