import UIKit

/// The one thing on a device that needs an application delegate: a push arriving.
///
/// Registering for remote notifications and hearing a silent one have no scene-based
/// route, so this exists — and nothing else does. It owns no window and touches no
/// scene; the UIScene lifecycle the app was built on is untouched, and everything a
/// push means is decided by `RemoteModel`, which this only calls.
final class PushDelegate: NSObject, UIApplicationDelegate {
    /// What to do with a push. Set by the app once the model exists.
    var received: @MainActor ([AnyHashable: Any]) async -> Void = { _ in }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // CloudKit subscriptions arrive as remote notifications; the token itself is
        // Apple's business and is never sent to the Mac.
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await received(userInfo)
        return .newData
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        // Nothing to do: the LAN link still works, and the Devices pane on the Mac
        // shows this device as unable to notify once it says so.
    }
}
