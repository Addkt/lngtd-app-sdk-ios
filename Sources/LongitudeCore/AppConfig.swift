import Foundation

// MARK: - AppConfig Model

/// The main application configuration model.
///
/// The server schema uses `additionalProperties: false`, but this decoder explicitly
/// ignores unknown keys by relying on standard Swift synthesized `Decodable` where possible
/// and `decodeIfPresent` elsewhere. This ensures that a newer Lambda serving unknown fields
/// will not cause decoding to fail on older installed SDKs.
public struct AppConfig: Decodable {
    public let schema: Int
    public let version: String?
    public let ttl: TimeInterval
    public let platform: String
    /// The Lambda's `_error` flag. Wire name keeps the underscore; the Swift name
    /// does not, because a leading underscore reads as "internal detail" in Swift
    /// and these are public API.
    private let serverError: Bool?
    /// The Lambda's `_warnings`, e.g. that it stripped arrays out of `impOrtb`.
    public let warnings: [String]?
    public let adUnitsRef: JSONValue?
    public let adUnits: [String: AdUnit]
    public let floors: [String: [String: FloorValue]]

    public let geo: Geo?
    public let account: Account?
    public let app: AppInfo?
    public let features: Features?
    public let prebid: Prebid?
    public let excludeFromRefresh: [String]?
    public let creativeIdBlocks: [String]?
    public let tests: [String]?

    /// A config the Lambda flagged with `_error` is usable but must never be
    /// persisted — the Lambda pairs it with `ttl: 0`, meaning "serve this once".
    public var isCacheable: Bool {
        return serverError != true
    }

    /// True when the Lambda reported its own internal failure. Freshness must never
    /// classify such a config as `fresh`.
    public var isServerError: Bool {
        return serverError == true
    }

    public enum AppConfigError: Error, Equatable {
        case unsupportedSchema(Int)
        case unsupportedPlatform(String)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let schema = try container.decode(Int.self, forKey: .schema)
        guard schema == 1 else {
            throw AppConfigError.unsupportedSchema(schema)
        }
        self.schema = schema

        let platform = try container.decode(String.self, forKey: .platform)
        guard platform == "ios" else {
            throw AppConfigError.unsupportedPlatform(platform)
        }
        self.platform = platform

        self.version = try container.decodeIfPresent(String.self, forKey: .version)
        self.ttl = try container.decode(TimeInterval.self, forKey: .ttl)
        self.serverError = try container.decodeIfPresent(Bool.self, forKey: .serverError)
        self.warnings = try container.decodeIfPresent([String].self, forKey: .warnings)
        self.adUnitsRef = try container.decodeIfPresent(JSONValue.self, forKey: .adUnitsRef)
        self.adUnits = try container.decode([String: AdUnit].self, forKey: .adUnits)
        self.floors = try container.decode([String: [String: FloorValue]].self, forKey: .floors)

        self.geo = try container.decodeIfPresent(Geo.self, forKey: .geo)
        self.account = try container.decodeIfPresent(Account.self, forKey: .account)
        self.app = try container.decodeIfPresent(AppInfo.self, forKey: .app)
        self.features = try container.decodeIfPresent(Features.self, forKey: .features)
        self.prebid = try container.decodeIfPresent(Prebid.self, forKey: .prebid)
        self.excludeFromRefresh = try container.decodeIfPresent([String].self, forKey: .excludeFromRefresh)
        self.creativeIdBlocks = try container.decodeIfPresent([String].self, forKey: .creativeIdBlocks)
        self.tests = try container.decodeIfPresent([String].self, forKey: .tests)
    }

    private enum CodingKeys: String, CodingKey {
        case schema, version, ttl, platform, adUnitsRef, adUnits, floors
        case geo, account, app, features, prebid, excludeFromRefresh
        case creativeIdBlocks, tests
        // Wire names keep their leading underscores.
        case serverError = "_error"
        case warnings = "_warnings"
    }
}

extension AppConfig {
    public struct AdUnit: Decodable {
        public let uid: String
        public let gamPath: String
        public let gpid: String?
        public let adFormat: String?
        public let sizes: [[Int]]?
        public let prebidConfigId: String?
        /// `BaseFloorInput`, not `Double?`.
        ///
        /// A published config is schema-constrained to a number or null, but a
        /// bundled `LNGTDConfig.json` is validated by nothing, and decoding straight
        /// to `Double?` throws `typeMismatch` on a hand-authored `"0.25"` — which
        /// discards the **entire** config, every ad unit and every floor, dropping
        /// the app to passthrough on a cold launch because of one character.
        ///
        /// It also preserves a distinction `Double?` cannot express: the web does
        /// `parseFloat(baseFloor) || 0`, so a present-but-non-numeric floor is a
        /// configured **0**, whereas an absent one means "send no floor at all".
        /// Collapsing those two is the difference between `imp.bidfloor: 0` and an
        /// omitted field, which PBS treats differently.
        public let baseFloor: BaseFloorInput
        public let dynamicFloorParameters: DynamicFloorParameters?
        public let timeoutMs: Int?
        public let refresh: Refresh?
        public let lazyLoad: Bool?
        public let video: JSONValue?
        public let impOrtb: JSONValue?
        public let storedRequestId: String?

        private enum CodingKeys: String, CodingKey {
            case uid, gamPath, gpid, adFormat, sizes, prebidConfigId
            case baseFloor, dynamicFloorParameters, timeoutMs, refresh
            case lazyLoad, video, impOrtb, storedRequestId
        }

        /// Hand-written rather than synthesised, for one reason: `baseFloor` must
        /// tolerate an absent key, a null, a number, and a non-numeric value, and
        /// synthesised decoding cannot express "absent means `.missing`" for a
        /// non-optional property — it throws `keyNotFound` instead.
        ///
        /// Everything else decodes exactly as the synthesised version would. Unknown
        /// keys are ignored, deliberately: a newer Lambda will serve fields an older
        /// installed SDK has never seen, and the publisher cannot ship an app update
        /// to fix a decode failure. Do not add strict validation here.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)

            uid = try container.decode(String.self, forKey: .uid)
            gamPath = try container.decode(String.self, forKey: .gamPath)
            gpid = try container.decodeIfPresent(String.self, forKey: .gpid)
            adFormat = try container.decodeIfPresent(String.self, forKey: .adFormat)
            sizes = try container.decodeIfPresent([[Int]].self, forKey: .sizes)
            prebidConfigId = try container.decodeIfPresent(String.self, forKey: .prebidConfigId)
            dynamicFloorParameters = try container.decodeIfPresent(
                DynamicFloorParameters.self, forKey: .dynamicFloorParameters
            )
            timeoutMs = try container.decodeIfPresent(Int.self, forKey: .timeoutMs)
            refresh = try container.decodeIfPresent(Refresh.self, forKey: .refresh)
            lazyLoad = try container.decodeIfPresent(Bool.self, forKey: .lazyLoad)
            video = try container.decodeIfPresent(JSONValue.self, forKey: .video)
            impOrtb = try container.decodeIfPresent(JSONValue.self, forKey: .impOrtb)
            storedRequestId = try container.decodeIfPresent(String.self, forKey: .storedRequestId)

            baseFloor = Self.decodeBaseFloor(from: container)
        }

        /// Absent or null -> `.missing` (send no floor). A number -> `.value`.
        /// Anything else -> `.invalid`, which the resolver treats as a configured 0,
        /// matching the web's `parseFloat(x) || 0`. Never throws: a junk floor in a
        /// bundled config must not discard the whole document.
        private static func decodeBaseFloor(
            from container: KeyedDecodingContainer<CodingKeys>
        ) -> BaseFloorInput {
            guard container.contains(.baseFloor) else { return .missing }
            if let isNull = try? container.decodeNil(forKey: .baseFloor), isNull {
                return .missing
            }
            if let number = try? container.decode(Double.self, forKey: .baseFloor) {
                return .value(number)
            }
            return .invalid
        }

        public func impOrtbArrays() -> [String] {
            guard let impOrtb = impOrtb else { return [] }
            var paths: [String] = []
            findArrays(in: impOrtb, currentPath: "", paths: &paths)
            return paths
        }

        private func findArrays(in value: JSONValue, currentPath: String, paths: inout [String]) {
            switch value {
            case .array(let arr):
                paths.append(currentPath.isEmpty ? "root" : currentPath)
                for (index, val) in arr.enumerated() {
                    let newPath = currentPath.isEmpty ? "[\(index)]" : "\(currentPath)[\(index)]"
                    findArrays(in: val, currentPath: newPath, paths: &paths)
                }
            case .object(let dict):
                // Sorted so reported paths are deterministic rather than
                // dictionary-order, which would make assertions flake.
                for (key, nested) in dict.sorted(by: { $0.key < $1.key }) {
                    let newPath = currentPath.isEmpty ? key : "\(currentPath).\(key)"
                    findArrays(in: nested, currentPath: newPath, paths: &paths)
                }
            default:
                break
            }
        }
    }

    public struct Geo: Decodable {
        public let country: String?
        public let continent: String?
        public let regionState: String?
        public let asn: String?
    }

    public struct Refresh: Decodable {
        public let seconds: Int?
    }

    public struct Account: Decodable {
        public let name: String?
        public let adsEnabled: Bool?
        public let prebidEnabled: Bool?
        public let prebidServerEndpoint: String?
        public let dynamicFloorsEnabled: Bool?
        public let auctionTimeoutMs: Int?
        public let configTimeoutMs: Int?
        public let sampleRate: Double?
        public let eventEndpoint: String?
        public let eventFallbackEndpoint: String?
    }

    public struct AppInfo: Decodable {
        public let bundle: String?
        public let storeUrl: String?
        public let name: String?
        public let publisherId: String?
        public let cat: [String]?
    }

    public struct Features: Decodable {
        public let viewability: JSONValue?
        public let refresh: JSONValue?
        public let killSwitch: Bool?
    }

    public struct Prebid: Decodable {
        public let aliases: JSONValue?
        public let allowUnknownBidderCodes: Bool?
        public let globalOrtb: JSONValue?
    }
}

// MARK: - JSONValue

/// A recursive JSON value type for free-form payloads like `impOrtb`.
/// Defined in the target instead of reusing the one from `Tests/LongitudeCoreTests/FloorContractFixture.swift`
/// because the test type is internal to the test target and includes test-specific parsing
/// logic (e.g. `isUnparseableSentinel`) that isn't appropriate for generic app config payload usage.
public enum JSONValue: Decodable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    /// Bool is tried before Double deliberately: `JSONDecoder` will happily decode
    /// `true` as `1.0`, so checking Double first would turn every boolean in an
    /// `impOrtb` payload into a number.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unsupported JSON value"
                )
            )
        }
    }
}

// MARK: - Floor Types Conformance

extension FloorValue: Decodable {
    /// Accepts number, string and null, because a bundled config is validated by
    /// nothing and the resolver reproduces the web's behaviour for each — a string
    /// floor is returned as-is by the web ladder, and a null is present-but-falsy,
    /// which is not the same as an absent key. Anything else (a bool, an object) is
    /// a genuine type error.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else {
            throw DecodingError.typeMismatch(
                FloorValue.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected a number, string or null floor value"
                )
            )
        }
    }
}

extension DynamicFloorParameters: Decodable {
    private enum CodingKeys: String, CodingKey {
        case useStaticFloor, useHardBaseFloor, geoFloors = "geo_floors"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            useStaticFloor: try container.decodeIfPresent(Bool.self, forKey: .useStaticFloor) ?? false,
            useHardBaseFloor: try container.decodeIfPresent(Bool.self, forKey: .useHardBaseFloor) ?? false,
            geoFloors: try container.decodeIfPresent([String: FloorValue].self, forKey: .geoFloors)
        )
    }
}
