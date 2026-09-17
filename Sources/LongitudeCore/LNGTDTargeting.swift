import Foundation

public enum LNGTDTargeting {
    public static func merge(
        existing: [String: Any]?,
        auctionKeys: [String: String]?
    ) -> [String: Any] {
        // The prefix Prebid itself strips in `Utils.removeHBKeywords` — named once so the
        // merge and any future caller cannot drift apart.
        let stalePrefix = "hb_"
        var result: [String: Any] = [:]

        if let existing = existing {
            for (key, value) in existing where !key.hasPrefix(stalePrefix) {
                result[key] = value
            }
        }

        if let auctionKeys = auctionKeys {
            for (key, value) in auctionKeys {
                result[key] = value
            }
        }

        return result
    }
}
