import GoogleMobileAds
import LongitudeGAM
import UIKit

/// 24 ad slots in a reusing collection view.
///
/// The point is cell reuse, not the ads. A banner created in `cellForItemAt` and never
/// torn down leaks a view, a GMA request and — once refresh lands in M4 — a timer, per
/// scroll. Scrolling this list is the cheapest way to see that: the counters at the top
/// show how many banners have been created versus deallocated, and they should stay
/// close together rather than one climbing forever.
final class FeedViewController: UIViewController {

    private static let adEveryNRows = 4
    private static let rowCount = 96  // 24 ad slots

    private var collectionView: UICollectionView!
    private let counters = StatusLabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 8
        layout.estimatedItemSize = UICollectionViewFlowLayout.automaticSize

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.backgroundColor = .systemBackground
        collectionView.register(AdCell.self, forCellWithReuseIdentifier: AdCell.reuseID)
        collectionView.register(TextCell.self, forCellWithReuseIdentifier: TextCell.reuseID)

        for subview in [counters, collectionView as UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            counters.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            counters.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            counters.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            collectionView.topAnchor.constraint(equalTo: counters.bottomAnchor, constant: 8),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.counters.text = AdCell.bannerCensus()
        }

        // `-autoScroll 1` scrolls the feed on its own, so the reuse behaviour can be
        // checked from a script or a screenshot rather than needing someone to swipe.
        // Without it the counters only ever show the initial viewport, where nothing has
        // been recycled yet and a leak would be invisible.
        if UserDefaults.standard.bool(forKey: "autoScroll") {
            startAutoScroll()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Longitude.trackScreenView("Feed")
    }

    private func startAutoScroll() {
        var row = 0
        Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] timer in
            guard let self, row < Self.rowCount else { return timer.invalidate() }
            self.collectionView.scrollToItem(
                at: IndexPath(item: row, section: 0), at: .top, animated: false
            )
            row += 6
        }
    }
}

extension FeedViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func collectionView(_ view: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        Self.rowCount
    }

    func collectionView(
        _ view: UICollectionView, cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        if indexPath.item % Self.adEveryNRows == 0 {
            let cell = view.dequeueReusableCell(
                withReuseIdentifier: AdCell.reuseID, for: indexPath
            )
            (cell as? AdCell)?.configure(rootViewController: self)
            return cell
        }
        let cell = view.dequeueReusableCell(
            withReuseIdentifier: TextCell.reuseID, for: indexPath
        )
        (cell as? TextCell)?.configure(row: indexPath.item)
        return cell
    }

    func collectionView(
        _ view: UICollectionView, layout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let isAd = indexPath.item % Self.adEveryNRows == 0
        return CGSize(width: view.bounds.width, height: isAd ? 66 : 44)
    }
}

/// Creates a banner on configure and releases it on `prepareForReuse`.
///
/// Releasing on reuse rather than holding one banner per cell forever is the behaviour
/// under test — a real feed scrolls past hundreds of slots, and the SDK must not
/// accumulate one live request per slot ever seen.
final class AdCell: UICollectionViewCell {
    static let reuseID = "AdCell"

    private static var created = 0
    private static var released = 0

    static func bannerCensus() -> String {
        "banners created \(created) · released \(released) · live \(created - released)"
    }

    private var banner: LNGTDBannerView?
    private let label = StatusLabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(rootViewController: UIViewController) {
        guard banner == nil, let created = Longitude.bannerView(slot: "feed_slot") else { return }
        Self.created += 1

        created.adUnitID = "/21775744923/example/adaptive-banner"
        created.validAdSizes = [AdSizeBanner]
        created.rootViewController = rootViewController
        created.onResolution = { [weak self] resolution in
            if case .passthrough(let cause) = resolution {
                self?.label.text = "passthrough (\(cause))"
            } else {
                self?.label.text = "longitude"
            }
        }
        created.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(created)
        NSLayoutConstraint.activate([
            created.topAnchor.constraint(equalTo: contentView.topAnchor),
            created.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            created.widthAnchor.constraint(equalToConstant: 320),
            created.heightAnchor.constraint(equalToConstant: 50),
        ])
        banner = created
        created.load(AdManagerRequest())
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if banner != nil {
            Self.released += 1
        }
        banner?.removeFromSuperview()
        banner = nil
        label.text = ""
    }
}

final class TextCell: UICollectionViewCell {
    static let reuseID = "TextCell"
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .preferredFont(forTextStyle: .body)
        label.textColor = .label
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(row: Int) {
        label.text = "Content row \(row)"
    }
}
