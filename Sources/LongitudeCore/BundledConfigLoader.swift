import Foundation

public enum BundledConfigError: Error, Equatable {
    case undecodable
    /// The file is present but could not be read. Distinct from absence, which is
    /// the ordinary case for a publisher who has not shipped a bundled config and
    /// must never be reported as a failure.
    case unreadable
}

public protocol BundledConfigReporting: AnyObject {
    func bundledConfigDidFail(reason: BundledConfigError)
}

public final class BundledConfigLoader {
    private let bundle: Bundle
    public weak var reporter: BundledConfigReporting?

    public init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    /// Not `Equatable`: `AppConfig` is not, and making it so would mean conforming
    /// the whole model graph for the benefit of test assertions. Tests compare the
    /// fields they care about instead.
    public struct Result {
        public let config: AppConfig
        public let freshness: ConfigFreshness
    }

    public func load() -> Result? {
        guard let url = bundle.url(forResource: "LNGTDConfig", withExtension: "json") else {
            return nil
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // The bundle told us this file exists, so a read failure here is a real
            // fault worth reporting — silently returning nil would make it
            // indistinguishable from "the publisher shipped no bundled config",
            // which is the one case that is not a failure.
            reporter?.bundledConfigDidFail(reason: .unreadable)
            return nil
        }

        do {
            let config = try JSONDecoder().decode(AppConfig.self, from: data)
            // Reported as `.staleUsable` explicitly, rather than fabricating a
            // `fetchedAt` of 0 and letting the freshness arithmetic decide.
            //
            // A bundled config is fully usable — serving immediately on a cold,
            // offline, first-ever launch is the entire reason it exists — but it is a
            // build-time artifact of unknown age and cannot know about anything that
            // changed after the app was submitted. So it must never be `.fresh`, which
            // would suppress the fetch, and `.staleUsable` says exactly that: use it
            // now, and still go and ask.
            return Result(config: config, freshness: .staleUsable)
        } catch {
            reporter?.bundledConfigDidFail(reason: .undecodable)
            // Bundled files are inside the signed app bundle and cannot be deleted.
            return nil
        }
    }
}
