import GoogleMobileAds
import LongitudeGAM
import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {

        // Time the call, because "never blocks" is the claim and this is where it is
        // either true or not. The number is shown in the debug tab.
        let start = ProcessInfo.processInfo.systemUptime
        Longitude.start(accountId: "demo", section: "app")
        DemoMetrics.shared.startDurationMs = (ProcessInfo.processInfo.systemUptime - start) * 1000

        // Simulators are automatically test devices for GMA, so the sample ad unit in
        // LNGTDConfig.json serves real test creatives without any account setup.

        let tabs = UITabBarController()
        tabs.viewControllers = [
            wrap(SideBySideViewController(), title: "Side by side", symbol: "rectangle.split.2x1"),
            wrap(FeedViewController(), title: "Feed", symbol: "list.bullet"),
            wrap(DebugViewController(), title: "Debug", symbol: "wrench.and.screwdriver"),
        ]

        // `-startTab side|feed|debug` selects a tab at launch, so screenshots can be
        // taken without driving taps. Useful for automated capture and for reviewing a
        // specific screen from a terminal.
        switch UserDefaults.standard.string(forKey: "startTab") {
        case "feed": tabs.selectedIndex = 1
        case "debug": tabs.selectedIndex = 2
        default: tabs.selectedIndex = 0
        }

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = tabs
        window.makeKeyAndVisible()
        self.window = window
        return true
    }

    private func wrap(
        _ controller: UIViewController, title: String, symbol: String
    ) -> UIViewController {
        let nav = UINavigationController(rootViewController: controller)
        controller.title = title
        nav.tabBarItem = UITabBarItem(
            title: title, image: UIImage(systemName: symbol), tag: 0
        )
        return nav
    }
}

/// Numbers the demo measures about itself, for the debug tab.
final class DemoMetrics {
    static let shared = DemoMetrics()
    var startDurationMs: Double = 0
    /// Set when the Longitude banner's first delegate callback lands, so the cold-start
    /// path (`start()` → first ad response) is visible rather than assumed.
    var firstAdResponseMs: Double?
    let launchedAt = ProcessInfo.processInfo.systemUptime

    func recordFirstAdResponse() {
        guard firstAdResponseMs == nil else { return }
        firstAdResponseMs = (ProcessInfo.processInfo.systemUptime - launchedAt) * 1000
    }
}
