// swift-tools-version:5.9
//
// Only LongitudeCore exists so far, deliberately.
//
// The plan's full graph is
//   Longitude → LongitudeGAM → LongitudeAuction → LongitudeCore → LNGTDExceptionShim
// The ad-SDK targets are added when they have something to do; declaring them
// before then only means `swift build` pulls ~350MB of Prebid on every clean
// checkout to compile nothing.
//
// The Prebid mirror now exists and is verified:
//
//     .package(url: "https://github.com/Addkt/prebid-mobile-ios.git",
//              exact: "3.3.3-lngtd.1")
//
// Note `exact:`, NOT the plan's `.upToNextMinor(from: "3.3.3")`. Those two are
// incompatible and the plan asks for both: `3.3.3-lngtd.1` is a semver
// *pre-release*, which sorts BELOW `3.3.3`, so the range `3.3.3..<3.4.0` excludes
// it. SwiftPM's exact words when tried:
//
//     error: Dependencies could not be resolved because no versions of
//     'prebid-mobile-ios' match the requirement 3.3.3..<3.4.0
//
// An exact pin is the right answer anyway — the plan wanted a tight constraint
// because the SDK leans on undocumented Prebid merge and reentrancy behaviour, and
// range flexibility across a fork we control is illusory: a new upstream version
// needs a new fork branch and tag regardless.
//
// GMA is pinned `.upToNextMajor(from: "13.0.0")` to match Prebid's own constraint
// so SPM can unify — verified against the mirror, which resolves GMA 13.7.0.
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
        // What a publisher adds. LongitudeGAM re-exports the core, so one product is
        // the whole SDK as far as an integration is concerned.
        .library(name: "LongitudeGAM", targets: ["LongitudeGAM"]),
    ],
    dependencies: [
        // Pinned .upToNextMajor(from: "13.0.0") to match Prebid's own constraint, so
        // SPM can unify the two when LongitudeAuction arrives. Verified against the
        // LNGTD Prebid mirror, which resolves GMA 13.7.0 alongside this.
        .package(
            url: "https://github.com/googleads/swift-package-manager-google-mobile-ads.git",
            .upToNextMajor(from: "13.0.0")
        ),
    ],
    targets: [
        .target(
            name: "LNGTDExceptionShim",
            path: "Sources/LNGTDExceptionShim",
            publicHeadersPath: "include"
        ),
        .target(
            name: "LongitudeCore",
            dependencies: ["LNGTDExceptionShim"],
            path: "Sources/LongitudeCore"
        ),
        // GoogleMobileAds is iOS-only, and naively depending on it would end the
        // millisecond host test loop for the entire package. Two things keep it alive:
        //
        //  1. the product dependency is conditional on iOS, so a macOS build never
        //     tries to link an iOS-only binary target; and
        //  2. every source file here is wrapped in `#if os(iOS)`, so on macOS this
        //     target compiles to an empty module rather than failing on the import.
        //
        // The result is that `swift test` on the host still runs the 102 LongitudeCore
        // tests in ~3s, while the simulator build gets the real thing. Removing either
        // half breaks that, so if you find yourself deleting an `#if os(iOS)` here,
        // check `swift build` on macOS before you commit.
        .target(
            name: "LongitudeGAM",
            dependencies: [
                "LongitudeCore",
                .product(
                    name: "GoogleMobileAds",
                    package: "swift-package-manager-google-mobile-ads",
                    condition: .when(platforms: [.iOS])
                ),
            ],
            path: "Sources/LongitudeGAM"
        ),
        .testTarget(
            name: "LongitudeCoreTests",
            dependencies: ["LongitudeCore"],
            path: "Tests/LongitudeCoreTests",
            resources: [
                // Generated from the real web ladder by Tools/FloorContract.
                // Never hand-edit; regenerate and let CI's --check gate notice.
                .copy("Fixtures/floor-contract.json"),
                .copy("Fixtures/lambda_ct_app_response.json"),
            ]
        ),
    ]
)
