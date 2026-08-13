import Foundation

public enum LNGTDEventStoreError: Error, Equatable {
    case unwritable
    /// Present but not readable — typically the OS purging Caches mid-read. Kept distinct
    /// from a parse failure for the reason documented on `ConfigDiskStoreError`: the
    /// response differs, so collapsing them loses the distinction that matters.
    case unreadable
}

public protocol LNGTDEventStoreReporting: Sendable {
    func storeDidFail(reason: LNGTDEventStoreError)
    /// Lines that did not parse and were skipped on read. Reported because silent skipping
    /// makes a systematic writer bug look like normal operation.
    func storeDidSkipUnparseableLines(count: Int)
    /// Oldest records discarded to make room for new ones.
    func storeDidTrimOldest(count: Int)
    /// A single append was larger than the entire store cap, so no amount of trimming
    /// would have made room. Distinct from a trim: nothing was stored at all.
    func storeDidRefuseOversizedAppend()
}

/// Append-only NDJSON store holding one **already-encoded** event per line.
///
/// Bytes rather than decoded events, on purpose. `LNGTDEvent` is `Encodable` only, and the
/// obvious route — add `Decodable` and round-trip through the type — puts the event's
/// original timestamp at the mercy of an initialiser that must not re-stamp it. 2e-2 stamps
/// the timestamp in `init` from a clock; a drain that re-stamped would relabel a night of
/// recovered impressions as happening at launch. Storing bytes makes that **impossible by
/// construction** rather than guarded by a test, and lets a drain re-batch stored events
/// without re-encoding them.
///
/// One event per line only works because compact `JSONEncoder` output contains no literal
/// newlines — a newline inside a string field is escaped. A `.prettyPrinted` encoder
/// anywhere in this path would make every record span lines, and the reader would treat the
/// fragments as records and drop the file.
public final class LNGTDEventStore: @unchecked Sendable {
    /// Serialises the read-modify-write sequences below. The durable sink happens to call
    /// this store serially, but the type must not depend on its caller for that: two
    /// concurrent appends without this lock lose records.
    private let lock = NSLock()

    private let baseDirectory: URL
    private let fileURL: URL
    private let reporter: LNGTDEventStoreReporting?

    private let maxRecords: Int
    private let maxBytes: Int

    /// Maintained incrementally so the fast path never reads the file. Seeded once, lazily,
    /// because `init` should not perform I/O.
    private var isSeeded = false
    private var recordCount = 0
    private var byteCount = 0

    private static let newline = UInt8(ascii: "\n")

    /// Decimal, matching the 200000 style of the payload cap rather than 1_048_576.
    public init(
        baseDirectory: URL,
        reporter: LNGTDEventStoreReporting? = nil,
        maxRecords: Int = 500,
        maxBytes: Int = 1_000_000
    ) {
        self.baseDirectory = baseDirectory
        self.fileURL = baseDirectory.appendingPathComponent("events.ndjson")
        self.reporter = reporter
        self.maxRecords = maxRecords
        self.maxBytes = maxBytes
    }

    /// Where records live. Internal so tests can ask rather than rebuilding the name.
    var storeFileURL: URL { fileURL }

    // MARK: - Append

    /// Appends encoded events, trimming the oldest records if the caps require it.
    ///
    /// A real append — seek to end and write — not a read-concatenate-rewrite. Two reasons
    /// beyond the obvious cost of moving up to a megabyte per batch: a whole-file atomic
    /// rewrite can never leave a truncated final line, so the truncation handling in
    /// `readAll()` would be dead code guarding a state its own writer could not produce.
    /// An append genuinely can be interrupted mid-write, which is the case that matters.
    public func append(lines: [Data]) {
        guard !lines.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }
        seedIfNeeded()

        // Each line costs its bytes plus the newline that terminates it.
        let incomingBytes = lines.reduce(0) { $0 + $1.count + 1 }
        let incomingRecords = lines.count

        // No amount of trimming makes room for this, so trimming would throw away good
        // records and still fail. Refuse it and say so.
        if incomingBytes > maxBytes || incomingRecords > maxRecords {
            reporter?.storeDidRefuseOversizedAppend()
            return
        }

        if byteCount + incomingBytes > maxBytes || recordCount + incomingRecords > maxRecords {
            // Trim the OLDEST rather than refusing the new records.
            //
            // Both lose data; this one cannot wedge. Refusing new records means a full file
            // holds 500 stale events and discards everything after it forever — a device
            // offline for a day would keep yesterday morning and drop the rest. Trimming
            // always holds the freshest 500, which are also the likeliest to still be
            // inside any lateness window the collector applies.
            trimOldest(toFitBytes: incomingBytes, records: incomingRecords)
        }

        writeAppending(lines: lines, byteCost: incomingBytes)
    }

    // MARK: - Read

    /// Every complete, parseable line, in stored order.
    ///
    /// Line by line, skipping what does not parse. An app killed mid-write leaves a partial
    /// final line; decoding the whole file at once, or bailing on the first bad line, turns
    /// one truncated byte into up to 500 lost events.
    public func readAll() -> [Data] {
        lock.lock()
        defer { lock.unlock() }

        let result = readLines()
        if result.skipped > 0 {
            reporter?.storeDidSkipUnparseableLines(count: result.skipped)
        }
        return result.lines
    }

    // MARK: - Remove

    /// Removes exactly these records, matched by bytes.
    ///
    /// Multiset semantics: two identical events produce identical bytes, and removing one
    /// must leave the other. Matching by bytes rather than by position is what makes this
    /// safe against an append arriving between the read and the remove.
    public func remove(records: [Data]) {
        guard !records.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }
        seedIfNeeded()

        var outstanding = records
        let kept = readLines().lines.filter { line in
            if let index = outstanding.firstIndex(of: line) {
                outstanding.remove(at: index)
                return false
            }
            return true
        }

        write(lines: kept)
    }

    // MARK: - Private

    private func seedIfNeeded() {
        guard !isSeeded else { return }
        isSeeded = true

        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        let result = readLines()
        recordCount = result.lines.count
        byteCount = result.lines.reduce(0) { $0 + $1.count + 1 }
    }

    /// Splits on newlines and keeps only lines that parse as a JSON object. A line without a
    /// terminating newline is a mid-write truncation and is counted as skipped — every
    /// complete line before it survives.
    private func readLines() -> (lines: [Data], skipped: Int) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ([], 0)
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            reporter?.storeDidFail(reason: .unreadable)
            return ([], 0)
        }

        var lines: [Data] = []
        var skipped = 0
        var cursor = data.startIndex

        while cursor < data.endIndex {
            guard let terminator = data[cursor...].firstIndex(of: Self.newline) else {
                skipped += 1
                break
            }

            let line = Data(data[cursor..<terminator])
            cursor = data.index(after: terminator)

            guard !line.isEmpty else { continue }

            if (try? JSONSerialization.jsonObject(with: line)) is [String: Any] {
                lines.append(line)
            } else {
                skipped += 1
            }
        }

        return (lines, skipped)
    }

    private func trimOldest(toFitBytes incomingBytes: Int, records incomingRecords: Int) {
        var kept = readLines().lines
        var keptBytes = kept.reduce(0) { $0 + $1.count + 1 }
        var trimmed = 0

        while !kept.isEmpty,
              keptBytes + incomingBytes > maxBytes || kept.count + incomingRecords > maxRecords {
            keptBytes -= kept.removeFirst().count + 1
            trimmed += 1
        }

        write(lines: kept)

        if trimmed > 0 {
            reporter?.storeDidTrimOldest(count: trimmed)
        }
    }

    private func writeAppending(lines: [Data], byteCost: Int) {
        var blob = Data()
        blob.reserveCapacity(byteCost)
        for line in lines {
            blob.append(line)
            blob.append(Self.newline)
        }

        // A previous append interrupted mid-record leaves an unterminated final line.
        // Appending onto it would concatenate the fragment and the new record into one corrupt
        // line, so the new record would be lost too — the store silently destroying the thing
        // it was asked to keep. Compact instead: rewrite the parsed records plus the new ones.
        // Only reachable after an interrupted write, and it is what makes a real append safe.
        if FileManager.default.fileExists(atPath: fileURL.path), !endsWithNewline() {
            write(lines: readLines().lines + lines)
            return
        }

        do {
            try prepareDirectory()

            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: blob)
            } else {
                try blob.write(to: fileURL, options: .atomic)
            }

            byteCount += byteCost
            recordCount += lines.count
        } catch {
            reporter?.storeDidFail(reason: .unwritable)
        }
    }

    /// Reads only the final byte. `true` when it cannot tell, which takes the plain append
    /// path: at worst that leaves one corrupt line the reader skips, whereas guessing the
    /// other way would rewrite the file from a read that just failed and drop live records.
    private func endsWithNewline() -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return true }
        defer { try? handle.close() }

        guard let end = try? handle.seekToEnd(), end > 0 else { return true }
        guard (try? handle.seek(toOffset: end - 1)) != nil,
              let last = try? handle.read(upToCount: 1) else { return true }

        return last == Data([Self.newline])
    }

    /// Whole-file replacement, for trim and remove. Atomic, because a half-written
    /// replacement would lose records that were never meant to go.
    private func write(lines: [Data]) {
        var blob = Data()
        for line in lines {
            blob.append(line)
            blob.append(Self.newline)
        }

        do {
            if blob.isEmpty {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                }
            } else {
                try prepareDirectory()
                try blob.write(to: fileURL, options: .atomic)
            }

            recordCount = lines.count
            byteCount = blob.count
        } catch {
            reporter?.storeDidFail(reason: .unwritable)
        }
    }

    private func prepareDirectory() throws {
        guard !FileManager.default.fileExists(atPath: baseDirectory.path) else { return }

        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

        // Queued events are recoverable telemetry, not user data worth restoring onto a new
        // device. Set once at creation rather than on every append.
        var directory = baseDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
    }
}
