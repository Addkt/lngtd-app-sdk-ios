# Longitude App SDK (iOS)

Phase 2 of the Longitude Mobile SDK plan. The backend half (Phases 1b–1f) is in
review as [Addkt/addkt#1278](https://github.com/Addkt/addkt/pull/1278),
[Addkt/lngtd-dataform#195](https://github.com/Addkt/lngtd-dataform/pull/195) and
[Addkt/aws_lambdas#15](https://github.com/Addkt/aws_lambdas/pull/15).

## Status

**No Swift source yet, deliberately.** This machine has Command Line Tools but no
Xcode, so the toolchain is Swift 5.3.2 with no iOS SDK and no simulators:

- Swift 5.3 predates `async`/`await` and `Task`, which the plan's config layer uses
- `LongitudeCore` is specified as Foundation **and UIKit**, so it needs the iOS SDK
- `xcodebuild` is unavailable, so no target can be built and `swift test` cannot run

Every delegated change in Phase 1 shipped a bug that only running the code caught,
and in several cases the accompanying tests encoded the bug. Writing an SDK that
cannot be compiled would repeat that at much larger scale. Xcode is a hard
prerequisite — see "Unblocking" below.

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

1. **Install Xcode** (App Store, ~15 GB), then point the toolchain at it:
   ```bash
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   ```
   This needs your password, so it is not something the agent can do.
2. **Mirror the Prebid repo.** The plan requires
   `github.com/lngtd/prebid-mobile-ios` tagged `3.3.3-lngtd.1` with the core-only
   manifest promoted to root. It does not exist yet. Without it SPM resolves
   upstream's root manifest, which unconditionally depends on GMA **and AppLovin**,
   so every publisher gets phantom AppLovin in their `Package.resolved`. This gates
   the `LongitudeAuction` target, not `LongitudeCore`.
3. **M0 spike decisions** the plan defers, both needing a device or simulator:
   whether app slots require GAM line items (raised during Phase 1c-3 and deferred
   to M0), and confirming `impORTBConfig` drives bidder params on live LNGTD PBS.

Once Xcode is in place the first target is `LongitudeCore` — zero ad-SDK
dependencies, unit-testable in milliseconds, and the line-by-line spec for the
Android port — starting with the `FloorResolver` against the fixtures above.
