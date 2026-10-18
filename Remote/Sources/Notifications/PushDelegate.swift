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

    /// What to do with this device's APNs token (#1460). Set by the app once the model
    /// exists; a token that came first is handed over then.
    var registered: @MainActor (Data) -> Void = { _ in } {
        didSet { if let token { registered(token) } }
    }
    private var token: Data?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // CloudKit subscriptions arrive as remote notifications. The token goes only to the
        // control plane (#1460), which pushes here itself when no Mac host relays notices.
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await received(userInfo)
        return .newData
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        token = deviceToken
        registered(deviceToken)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        // Nothing to do: the LAN link still works, and the Devices pane on the Mac
        // shows this device as unable to notify once it says so.
    }
}
