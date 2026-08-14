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

        var configuration = LongitudeConfiguration()

        // The event endpoint, as an explicit launch argument.
        //
        // The SDK default is production ld.lngtd.com, so a reviewer tapping "Enqueue Test
        // Event" with no argument would post demo rows into the live warehouse. Verify against
        // a local server (-eventAPIURL http://127.0.0.1:8099/) for the success path, or an
        // unroutable address (-eventAPIURL https://10.255.255.1/) for the failure path.
        if let override = UserDefaults.standard.string(forKey: "eventAPIURL"),
           let url = URL(string: override) {
            configuration.eventAPIURL = url
            // Point the fallback at the same place, or a refused primary falls through to
            // production it.lngtd.com and the failure test posts real rows.
            configuration.eventFallbackURL = url
            DemoMetrics.shared.eventEndpoint = url.absoluteString
        } else {
            DemoMetrics.shared.eventEndpoint = "default (production)"
        }

        Longitude.start(accountId: "demo", section: "app", configuration: configuration)
        DemoMetrics.shared.startDurationMs = (ProcessInfo.processInfo.systemUptime - start) * 1000

        // Enqueues events at launch so the flush and drain paths can be verified without UI
        // automation, and identically on every run.
        let autoEnqueue = UserDefaults.standard.integer(forKey: "autoEnqueue")
        for _ in 0..<autoEnqueue {
            Longitude.enqueueTestEvent()
        }

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
    /// Which event endpoint this launch is pointed at, so a reviewer can never mistake a
    /// local verification run for one hitting production.
    var eventEndpoint = "default (production)"
    /// Set when the Longitude banner's first delegate callback lands, so the cold-start
    /// path (`start()` → first ad response) is visible rather than assumed.
    var firstAdResponseMs: Double?
    let launchedAt = ProcessInfo.processInfo.systemUptime

    func recordFirstAdResponse() {
        guard firstAdResponseMs == nil else { return }
        firstAdResponseMs = (ProcessInfo.processInfo.systemUptime - launchedAt) * 1000
    }
}
