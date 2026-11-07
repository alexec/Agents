import Sentry
import SwiftUI

@main
struct StarterApp: App {
    init() {
        // The workflows put the DSN in Info.plist from the SENTRY_DSN variable. The release is
        // <bundle id>@<version>+<build>, as on TestFlight, so that each crash names its build.
        let info = Bundle.main.infoDictionary ?? [:]
        let dsn = info["SentryDSN"] as? String ?? ""
        guard !dsn.isEmpty else { return }
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        SentrySDK.start { options in
            options.dsn = dsn
            options.releaseName = "\(bundleID)@\(version)+\(build)"
            #if DEBUG
            options.environment = "development"
            #else
            options.environment = "production"
            #endif
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
