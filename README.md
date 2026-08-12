# Longitude App SDK (iOS)

Phase 2 of the Longitude Mobile SDK plan. The backend half (Phases 1b–1f) is in
review as [Addkt/addkt#1278](https://github.com/Addkt/addkt/pull/1278),
[Addkt/lngtd-dataform#195](https://github.com/Addkt/lngtd-dataform/pull/195) and
[Addkt/aws_lambdas#15](https://github.com/Addkt/aws_lambdas/pull/15).

## Status

Toolchain: Xcode 26.3, Swift 6.2.4, iOS 26.2 SDK.

```bash
swift build && swift test        # LongitudeCore, ~3s, no simulator
xcodebuild -scheme LongitudeGAM -destination 'generic/platform=iOS Simulator' build
swiftlint lint --strict
```

**Two build paths, on purpose.** `LongitudeCore` is Foundation-only and tests on the
macOS host in about three seconds, which is what makes 100+ tests worth running on
every change. `LongitudeGAM` needs GoogleMobileAds, which is iOS-only — so its
GMA dependency is conditional on iOS and every source file is wrapped in
`#if os(iOS)`. On macOS it compiles to an empty module; the simulator build is what
actually typechecks it.

Removing either half of that arrangement silently moves the whole suite onto the slow
path, so CI asserts the empty-module build still happens.

### What this means for confidence

Everything in `LongitudeCore` is verified by running it. `LongitudeGAM` is not, and
cannot be by any test in this repo: it is a thin forwarding shell over a binary
framework, and its correctness depends on GMA delegate semantics. It compiles, and
that is the extent of the guarantee. The demo app in the plan — side-by-side GMA vs
Longitude, debug overlay, 20-slot feed — is the thing that would actually exercise it,
and it does not exist yet.

That asymmetry is why as much logic as possible lives in `LongitudeCore`:
`SlotResolution` and `LongitudeEngine` make every decision the banner needs, so the
GAM layer only wires and forwards.

## What is here

`Tools/FloorContract/` — the node half of the cross-runtime floor contract test,
which the plan names the highest-value single test for the SDK. It runs today and
needs no Swift.

It extracts and executes the **real** `getFloorForEnv` from the web bundle
(`addkt/static/header/v4-zone/src/units/base.js`) over a 24-case matrix and writes
golden fixtures to `Tests/LongitudeCoreTests/Fixtures/floor-contract.json`. The
Swift `FloorResolver` will be written against those fixtures, so it is specified by
executable web behaviour rather than by prose.

```bash
node Tools/FloorContract/generate.mjs          # regenerate
node Tools/FloorContract/generate.mjs --check  # CI gate
```

Reading the real function found five things the plan's summary of Phase 2d misses
— two portable ladder steps that are simply absent from it, a falsiness trap, a
type-check asymmetry, and a key segment the plan's shorthand renders as a literal.
All are written up with named fixture cases in
[`Tools/FloorContract/README.md`](Tools/FloorContract/README.md).

## Unblocking

1. ~~Install Xcode.~~ **Done** — Xcode 26.3, Swift 6.2.4, iOS 26.2 SDK.
2. ~~Mirror the Prebid repo.~~ **Done** —
   [Addkt/prebid-mobile-ios](https://github.com/Addkt/prebid-mobile-ios) at tag
   `3.3.3-lngtd.1`, a fork of `prebid/prebid-mobile-ios` (Apache-2.0) diverging in
   exactly one file: the core-only manifest promoted to root. Public, because it
   becomes a transitive SPM dependency that every publisher's Xcode fetches
   directly.

   Verified rather than assumed: upstream's root manifest really does depend on
   both GMA and AppLovin unconditionally; the mirror resolves to
   `prebid-mobile-ios 3.3.3-lngtd.1` + GMA 13.7.0 + its UMP transitive with **no
   AppLovin**; and the whole graph compiles for iOS Simulator (818 steps,
   `BUILD SUCCEEDED`).

   **The pin must be `exact: "3.3.3-lngtd.1"`, not the plan's
   `.upToNextMinor(from: "3.3.3")`** — a pre-release tag sorts below `3.3.3`, so
   the range excludes it and resolution fails outright. Details in `Package.swift`.
3. **M0 spike decisions** the plan defers, both needing a device or simulator:
   whether app slots require GAM line items (raised during Phase 1c-3 and deferred
   to M0), and confirming `impORTBConfig` drives bidder params on live LNGTD PBS.

Once Xcode is in place the first target is `LongitudeCore` — zero ad-SDK
dependencies, unit-testable in milliseconds, and the line-by-line spec for the
Android port — starting with the `FloorResolver` against the fixtures above.
