import GoogleMobileAds
import LongitudeCore
import LongitudeGAM
import UIKit

/// The debug overlay from the plan.
///
/// Shows config version, source and age, freshness, passthrough state, the network gate
/// hit count, and the resolved floor for a slot. Deliberately reads only public SDK API —
/// if something here needs `@testable` or reflection, that is a signal the SDK should
/// expose it rather than the overlay reaching in.
///
/// Not shown yet, and honest about why: the last auction's targeting keys and the bid
/// table need LongitudeAuction (M2), and event queue depth needs the event logger (2e).
final class DebugViewController: UIViewController {

    private let output = UILabel()
    private let enqueueButton = UIButton(type: .system)
    private var probeBanner: LNGTDBannerView?
    private var timer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        enqueueButton.setTitle("Enqueue Test Event", for: .normal)
        enqueueButton.addTarget(self, action: #selector(didTapEnqueue), for: .touchUpInside)
        enqueueButton.translatesAutoresizingMaskIntoConstraints = false

        output.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        output.numberOfLines = 0
        output.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(output)
        view.addSubview(scroll)
        view.addSubview(enqueueButton)

        NSLayoutConstraint.activate([
            enqueueButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            enqueueButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            scroll.topAnchor.constraint(equalTo: enqueueButton.bottomAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            output.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 12),
            output.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 16),
            output.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -16),
            output.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -32),
        ])

        // A hidden banner purely to resolve a slot, so the overlay can show the floor
        // this device would actually get without needing a visible ad.
        let probe = Longitude.bannerView(slot: "demo_banner")
        probe?.adUnitID = "/21775744923/example/adaptive-banner"
        probe?.load(AdManagerRequest())
        probeBanner = probe

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    deinit {
        timer?.invalidate()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Longitude.trackScreenView("Debug")
    }

    @objc private func didTapEnqueue() {
        Longitude.enqueueTestEvent()
    }

    private func refresh() {
        Task { @MainActor in
            var lines: [String] = []

            lines.append("── cold start ──")
            lines.append(String(
                format: "Longitude.start()      %.2f ms   (claim: never blocks)",
                DemoMetrics.shared.startDurationMs
            ))
            if let first = DemoMetrics.shared.firstAdResponseMs {
                lines.append(String(format: "first ad response      %.0f ms", first))
            } else {
                lines.append("first ad response      pending")
            }

            if let diagnostics = await Longitude.diagnostics() {
                lines.append("")
                lines.append("── config ──")
                lines.append("version                \(diagnostics.configVersion ?? "—")")
                lines.append("source                 \(diagnostics.source?.rawValue ?? "none")")
                lines.append(
                    "age                    " + (diagnostics.ageSeconds
                        .map { String(format: "%.0fs", $0) } ?? "n/a (bundled)")
                )
                lines.append("freshness              \(diagnostics.freshness.map(String.init(describing:)) ?? "—")")
                lines.append("passthrough reason     \(diagnostics.passthroughReason.map(\.rawValue) ?? "none")")
                lines.append("network gate hits      \(diagnostics.networkGateHits)   (SLO: 0)")
            } else {
                lines.append("")
                lines.append("Longitude.start has not been called")
            }

            if let pipeline = await Longitude.pipelineDiagnostics() {
                lines.append("")
                lines.append("── session ──")
                lines.append("session id             \(pipeline.sessionId)")
                lines.append("session depth          \(pipeline.sessionDepth)")
                lines.append("page                   \(pipeline.page ?? "none")")
                lines.append("referrer               \(pipeline.referrer ?? "none")")
                let sampledStr = pipeline.isSampled.map { $0 ? "yes" : "no" } ?? "not evaluated yet"
                lines.append("sampled                \(sampledStr)")

                lines.append("")
                lines.append("── pipeline ──")
                lines.append("pending queue depth    \(pipeline.pendingQueueDepth)")
                lines.append("stored record count    \(pipeline.storedRecordCount)")
                lines.append("ticks fired            \(pipeline.ticksFired)")
                lines.append("last trigger           \(pipeline.lastTrigger?.rawValue ?? "—")")
                lines.append("bg task active         \(pipeline.isBackgroundTaskActive)")
                lines.append("event endpoint         \(DemoMetrics.shared.eventEndpoint)")
            }

            lines.append("")
            lines.append("── slot demo_banner ──")
            if let plan = probeBanner?.lastPlan {
                lines.append("gamPath                \(plan.gamPath)")
                lines.append("uid                    \(plan.uid)")
                switch plan.resolvedFloor {
                case .value(let value):
                    lines.append(String(format: "resolved floor         %.2f", value))
                case .noFloor:
                    lines.append("resolved floor         none — imp.bidfloor omitted")
                }
                lines.append("refresh                \(plan.refreshSeconds.map { "\($0)s" } ?? "off")")
                lines.append("lazy load              \(plan.lazyLoad)")
                lines.append("sizes                  \(plan.sizes.map(String.init(describing:)) ?? "publisher's")")
            } else if let cause = probeBanner?.passthroughCause {
                lines.append("PASSTHROUGH (\(cause))")
                lines.append("serving the publisher's own adUnitID")
            } else {
                lines.append("resolving…")
            }

            lines.append("")
            lines.append("── not yet wired ──")
            lines.append("targeting keys         needs LongitudeAuction (M2)")
            lines.append("bid table              needs LongitudeAuction (M2)")

            self.output.text = lines.joined(separator: "\n")
        }
    }
}
