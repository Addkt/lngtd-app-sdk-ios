import Foundation

public enum ConfigDiskStoreError: Error, Equatable {
    case corrupted
    case oversized
    case unwritable
    /// Present but not readable — typically the OS purging Caches mid-read. Kept
    /// distinct from `corrupted` because the response differs: a corrupt file is
    /// deleted, an unreadable one is left alone.
    case unreadable
}

public protocol ConfigDiskStoreReporting: AnyObject {
    func storeDidFail(reason: ConfigDiskStoreError)
}

public final class ConfigDiskStore {
    public weak var reporter: ConfigDiskStoreReporting?
    private let baseDirectory: URL

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    /// Percent-encodes each component down to alphanumerics, then joins with `_`.
    ///
    /// Substituting separators for `_` while also using `_` as the delimiter is not
    /// injective: with that scheme `(account: "x", section: "y_app_z")` and
    /// `(account: "x_app_y", section: "z")` produce the same filename, and whichever
    /// writes second serves its ad units to the other. Because `_` is not in
    /// `.alphanumerics` it encodes to `%5F` inside a component, so it survives only
    /// as the delimiter and the mapping is one-to-one.
    ///
    /// This also handles traversal for free: `/` becomes `%2F` and `.` becomes `%2E`,
    /// so no input can climb out of `baseDirectory`. That matters because the account
    /// slug arrives from the publisher's own `Longitude.start` call.
    /// Internal rather than private so tests can ask where a record lives instead of
    /// rebuilding the filename by hand. Hardcoding the expected name in tests couples
    /// them to the encoding scheme, so changing the scheme breaks them spuriously
    /// while still not proving the two agree.
    func fileURL(account: String, section: String, platform: String) -> URL {
        let name = [account, section, platform]
            .map(Self.encodeComponent)
            .joined(separator: "_")

        // HFS+/APFS cap a filename at 255 bytes. Percent-encoding can triple a
        // component, so fall back to a deterministic digest of the exact triple
        // rather than letting the write fail with an opaque .unwritable.
        let filename = name.utf8.count > 200
            ? "cfg-\(Self.digest(name))"
            : name

        return baseDirectory.appendingPathComponent(filename + ".json")
    }

    private static func encodeComponent(_ raw: String) -> String {
        // Non-nil for any String; the coalesce exists only because the API is
        // Optional and force-unwrapping is a lint error.
        raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "invalid"
    }

    /// FNV-1a. Deterministic across processes and launches, which `hashValue` is
    /// not — Swift seeds its hasher per process, so a cache keyed on it would miss
    /// on every launch.
    private static func digest(_ input: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    public func read(account: String, section: String, platform: String) -> ConfigRecord? {
        let url = fileURL(account: account, section: section, platform: platform)

        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        let size: Int
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let sizeNumber = attrs[.size] as? NSNumber else {
                reporter?.storeDidFail(reason: .unreadable)
                return nil
            }
            size = sizeNumber.intValue
        } catch {
            // The file existed a moment ago and now cannot be stat'd — most likely
            // the OS is purging Caches underneath us. Report it, but do not delete:
            // there is nothing wrong with the file that we know of.
            reporter?.storeDidFail(reason: .unreadable)
            return nil
        }

        // Cap the read size to 1MB.
        if size > 1024 * 1024 {
            reporter?.storeDidFail(reason: .oversized)
            // I chose to DELETE an oversized file. A cache file that exceeds a reasonable
            // ceiling (like 1MB for a 30KB config) is completely worthless to the SDK.
            // Leaving it in place permanently occupies disk space and causes every subsequent
            // read to parse its attributes only to reject it again. Deleting it cleans up the
            // device and ensures we fetch fresh.
            try? FileManager.default.removeItem(at: url)
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let record = try JSONDecoder().decode(ConfigRecord.self, from: data)
            // Validate that the payload is actually decodable. We do this here so that
            // if the envelope is valid but the payload is junk, we still treat it as corrupt.
            _ = try record.decodedPayload()
            return record
        } catch is DecodingError {
            // Corrupt, or written by an SDK version whose envelope shape differs.
            // Either way it will never decode, so delete it — otherwise every launch
            // for the life of the install pays the same failed decode.
            reporter?.storeDidFail(reason: .corrupted)
            try? FileManager.default.removeItem(at: url)
            return nil
        } catch {
            // Any other error is an I/O error (transient, e.g. unreadable during purge).
            // Do not delete in this case.
            return nil
        }
    }

    public func write(record: ConfigRecord, account: String, section: String, platform: String) {
        let url = fileURL(account: account, section: section, platform: platform)

        do {
            try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

            // Files under `Caches` are already excluded from device backups by iOS
            // convention, making this call belt-and-braces today. However, it is kept
            // because this exclusion is load-bearing the moment anyone moves this directory
            // to `Application Support`. A restored backup would otherwise carry one device's
            // cached config (including geo) onto another device.
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var dirURL = baseDirectory
            try dirURL.setResourceValues(resourceValues)

            let data = try JSONEncoder().encode(record)
            try data.write(to: url, options: .atomic)
        } catch {
            reporter?.storeDidFail(reason: .unwritable)
        }
    }
}
