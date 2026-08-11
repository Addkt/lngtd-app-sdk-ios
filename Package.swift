// swift-tools-version:5.9
//
// Only LongitudeCore exists so far, deliberately.
//
// The plan's full graph is
//   Longitude → LongitudeGAM → LongitudeAuction → LongitudeCore → LNGTDExceptionShim
// but LongitudeAuction depends on the Prebid mirror at
// github.com/lngtd/prebid-mobile-ios tagged 3.3.3-lngtd.1, which does not exist
// yet, and LongitudeGAM depends on GoogleMobileAds. Declaring either target now
// would make `swift build` fail on an unresolvable dependency and leave the repo
// with no working verification at all. They get added when the mirror lands.
//
// macOS is declared alongside iOS purely for test velocity: LongitudeCore is
// Foundation-only, so `swift test` runs on the host in milliseconds rather than
// booting a simulator. That is the property the plan asks of this target ("it
// unit-tests in milliseconds and becomes the line-by-line spec for the Android
// port"). Anything needing UIKit — the exposure checker — must be written behind
// `#if canImport(UIKit)` so the host build keeps working. Once the ad-SDK targets
// exist, CI gains an `xcodebuild -destination 'platform=iOS Simulator'` step for
// them; this package is not claiming macOS is a supported publisher platform.
//
// Language mode is Swift 5 (implied by tools-version 5.9), not Swift 6 strict
// concurrency. That is a deliberate deferral: the config layer's actor isolation
// is a design question for M1, and fighting strict concurrency before the floor
// resolver exists would be the wrong order.

import PackageDescription

let package = Package(
    name: "Longitude",
    platforms: [
        .iOS(.v14),
        .macOS(.v11),
    ],
    products: [
        .library(name: "LongitudeCore", targets: ["LongitudeCore"]),
    ],
    targets: [
        .target(
            name: "LongitudeCore",
            path: "Sources/LongitudeCore"
        ),
        .testTarget(
            name: "LongitudeCoreTests",
            dependencies: ["LongitudeCore"],
            path: "Tests/LongitudeCoreTests",
            resources: [
                // Generated from the real web ladder by Tools/FloorContract.
                // Never hand-edit; regenerate and let CI's --check gate notice.
                .copy("Fixtures/floor-contract.json"),
            ]
        ),
    ]
)
