/// LongitudeCore holds the floor algorithm, config schema, event taxonomy,
/// session model and exposure checker, with zero ad-SDK dependencies.
///
/// Two consequences of that constraint, both load-bearing:
///
/// 1. It unit-tests on the host in milliseconds, with no simulator boot. That is
///    what makes a 24-case cross-runtime floor contract cheap enough to run on
///    every commit.
/// 2. It is the line-by-line specification for the Android port. Anything in here
///    that reaches for a platform API without need makes that port harder, so
///    UIKit use belongs behind `#if canImport(UIKit)` and nowhere else.
public enum LongitudeCore {
    /// Schema version of the config document this build understands.
    /// Matches `schema` in schemas/app_config_v1.json.
    public static let configSchemaVersion = 1
}
