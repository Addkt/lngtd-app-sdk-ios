import Foundation

/// Represents the raw value of a floor in the JSON map.
///
/// `null` is a case rather than an absence because the ladder distinguishes
/// "key present holding a falsy value" from "key absent" — see `ladderFloor`.
/// Parsing that drops null-valued keys turns the former into the latter and
/// silently changes which tier wins.
public enum FloorValue: Equatable {
    case number(Double)
    case string(String)
    case null

    /// JavaScript truthiness, used *after* a tier has been selected to decide
    /// whether to fall back to baseFloor. Never used to decide whether a tier
    /// matches — that is presence only.
    var isTruthy: Bool {
        switch self {
        case .number(let n): return n != 0.0 && !n.isNaN
        case .string(let s): return !s.isEmpty
        case .null: return false
        }
    }
}

/// State of the per-uid floors map.
///
/// On the web this arrives as a JSON *string* and a parse failure is silently
/// swallowed into `{}`. `.unparseable` records that distinctly from `.missing` so
/// a caller can log which happened, while both resolve identically.
public enum FloorsMap: Equatable {
    case entries([String: FloorValue])
    case unparseable
    case missing
}

/// Dynamic floor parameters, as authored per unit.
public struct DynamicFloorParameters: Equatable {
    public let useStaticFloor: Bool
    public let useHardBaseFloor: Bool
    public let geoFloors: [String: FloorValue]?

    public init(
        useStaticFloor: Bool = false,
        useHardBaseFloor: Bool = false,
        geoFloors: [String: FloorValue]? = nil
    ) {
        self.useStaticFloor = useStaticFloor
        self.useHardBaseFloor = useHardBaseFloor
        self.geoFloors = geoFloors
    }
}

/// State of the dynamic floor parameters payload. Also a JSON string on the web,
/// with the same silently-swallowed parse failure.
public enum DynamicParametersState: Equatable {
    case valid(DynamicFloorParameters)
    case unparseable
    case missing
}

/// The unit's configured base floor.
public enum BaseFloorInput: Equatable {
    case value(Double)
    /// Present but non-numeric. The web's `parseFloat(x) || 0` makes this a
    /// configured `0`, which is different from no floor at all.
    case invalid
    case missing
}

/// The outcome of a resolution.
///
/// `noFloor` is distinct from `value(0)` because Phase 2d is explicit that sending
/// `imp.bidfloor: 0.0` is semantically different to omitting the field — PBS
/// enforces a zero floor as a floor. Collapsing the two would silently change what
/// the auction is told.
public enum ResolvedFloor: Equatable {
    case value(Double)
    case noFloor
}

/// Everything one floor resolution needs.
///
/// A struct rather than eleven parameters: the slot controller holds most of these
/// for the lifetime of a slot and only `auctionId` and `sessionDepth` change per
/// auction, so passing a value it builds once is both cheaper to call and harder to
/// call wrongly — eleven same-typed `String` parameters in a row invite transposing
/// `country` and `section` at a call site and never noticing.
public struct FloorRequest: Equatable {
    public let auctionId: String
    /// `"ios"` or `"android"`.
    public let platform: String
    public let country: String
    /// `"phone"` or `"tablet"`. The web ladder spells this `mobile`/`desktop`; see
    /// Tools/FloorContract/README.md for why the two cannot match.
    public let deviceClass: String
    /// The account's section *value*, e.g. `"app"` — not the literal `"section"`.
    public let section: String
    public let sessionDepth: Int
    /// The unit's reporting uid, which is also the key into the floors map.
    public let uid: String
    public let baseFloor: BaseFloorInput
    public let dynamicFloorsEnabled: Bool
    public let dynamicFloorParameters: DynamicParametersState
    public let floors: FloorsMap

    public init(
        auctionId: String,
        platform: String,
        country: String,
        deviceClass: String,
        section: String,
        sessionDepth: Int,
        uid: String,
        baseFloor: BaseFloorInput,
        dynamicFloorsEnabled: Bool,
        dynamicFloorParameters: DynamicParametersState,
        floors: FloorsMap
    ) {
        self.auctionId = auctionId
        self.platform = platform
        self.country = country
        self.deviceClass = deviceClass
        self.section = section
        self.sessionDepth = sessionDepth
        self.uid = uid
        self.baseFloor = baseFloor
        self.dynamicFloorsEnabled = dynamicFloorsEnabled
        self.dynamicFloorParameters = dynamicFloorParameters
        self.floors = floors
    }

    /// Bucket segment of the ladder key: A at depth 0, C above 2, B for 1 and 2.
    var depthBucket: String {
        if sessionDepth == 0 { return "A" }
        if sessionDepth > 2 { return "C" }
        return "B"
    }
}

/// Ports the web floor ladder from `base.js:getFloorForEnv`.
///
/// The web function has eight steps. Steps 1–5 and 8 are ported here. Two are
/// deliberately absent:
///
/// - **Step 6** raises the floor to the highest bid in the zone bid pool and
///   averages against a pool-derived floor once the unit has had fill. There is no
///   zone bid pool in the mobile SDK, so there is nothing to read. Revisit with
///   refresh in M4.
/// - **Step 7** applies a `floor_override` URL query parameter. There is no URL in
///   an app. A debug override would be a deliberate addition, not a port.
///
/// Behaviour is pinned by 26 golden fixtures generated from the real web function;
/// see Tools/FloorContract.
public final class FloorResolver {
    private struct CacheKey: Hashable {
        let uid: String
        let auctionId: String
    }

    /// Decoded form of the request's deliberately loose inputs, so `compute` reads
    /// as the ladder rather than as unwrapping.
    private struct Inputs {
        let baseFloor: Double
        let baseFloorIsMissing: Bool
        let useStaticFloor: Bool
        let useHardBaseFloor: Bool
        let geoFloors: [String: FloorValue]?
        let floors: [String: FloorValue]

        init(_ request: FloorRequest) {
            // Step 2. `parseFloat(baseFloor) || 0`, so non-numeric is 0 — but
            // tracked separately from absent, since only absence can mean "no
            // floor to send".
            switch request.baseFloor {
            case .value(let num):
                baseFloor = num
                baseFloorIsMissing = false
            case .invalid:
                baseFloor = 0
                baseFloorIsMissing = false
            case .missing:
                baseFloor = 0
                baseFloorIsMissing = true
            }

            let params: DynamicFloorParameters?
            switch request.dynamicFloorParameters {
            case .valid(let parsed): params = parsed
            // A parse failure is swallowed: no useStaticFloor, no geo_floors, no
            // useHardBaseFloor, and no error the caller sees.
            case .unparseable, .missing: params = nil
            }
            useStaticFloor = params?.useStaticFloor ?? false
            useHardBaseFloor = params?.useHardBaseFloor ?? false
            geoFloors = params?.geoFloors

            switch request.floors {
            case .entries(let entries): floors = entries
            case .unparseable, .missing: floors = [:]
            }
        }
    }

    private var cache: [CacheKey: ResolvedFloor] = [:]

    public init() {}

    /// Resolves the floor for one unit in one auction.
    ///
    /// Memoised per `(uid, auctionId)` — steps 1 and 8. Without the memo a refresh
    /// re-resolves mid-auction and the bid request disagrees with the reported
    /// floor. The key includes `uid` because on the web `_auctionFloors` is an
    /// instance member of a single BaseUnit and so is implicitly per-unit; this
    /// resolver is shared across slots, so keying on `auctionId` alone would make
    /// every slot in a 20-slot feed collide on the first slot's floor.
    public func resolve(_ request: FloorRequest) -> ResolvedFloor {
        let cacheKey = CacheKey(uid: request.uid, auctionId: request.auctionId)
        if let cached = cache[cacheKey] {
            return cached
        }
        let result = Self.compute(request)
        cache[cacheKey] = result
        return result
    }

    private static func compute(_ request: FloorRequest) -> ResolvedFloor {
        let inputs = Inputs(request)
        var selected: FloorValue?
        /// Whether the value in hand came from baseFloor rather than a configured
        /// tier. Only meaningful together with `baseFloorIsMissing` at the end.
        var fellBackToBaseFloor = false

        if request.dynamicFloorsEnabled && !inputs.useStaticFloor {
            // Step 3.
            selected = ladderFloor(for: request, in: inputs.floors)
            // `if (!unitFloor) unitFloor = baseFloor` — a *falsiness* test, so a
            // configured 0 is discarded in favour of baseFloor.
            if selected?.isTruthy != true {
                selected = .number(inputs.baseFloor)
                fellBackToBaseFloor = true
            }
        } else if let geo = inputs.geoFloors {
            // Step 4. An `else if`, so it runs only when step 3 did not — which
            // also means useStaticFloor skips both and lands on baseFloor.
            selected = geoFloor(for: request.country, in: geo)
            // The web needs no falsy check here: `unitFloor` was initialised to
            // baseFloor before step 3 and geo_floors only overwrites it on a typed
            // match. Assigning baseFloor reproduces that starting value.
            if selected == nil {
                selected = .number(inputs.baseFloor)
                fellBackToBaseFloor = true
            }
        } else {
            selected = .number(inputs.baseFloor)
            fellBackToBaseFloor = true
        }

        var resolved: Double
        switch selected {
        case .number(let num):
            resolved = num
        case .string, .null, .none:
            // A truthy string survives the ladder on the web and is returned *as a
            // String*, because step 3 does no type check. A Double-typed resolver
            // cannot reproduce that, and schemas/app_config_v1.json constrains
            // floors values to numbers, so a published app config cannot contain
            // one. baseFloor is the safe reading for the one remaining path: a
            // bundled LNGTDConfig.json no server-side validator has seen.
            //
            // `.null` and `.none` cannot reach here — both are falsy, so the step-3
            // check already replaced them — but they are handled explicitly so that
            // adding a FloorValue case becomes a compile error rather than a silent
            // behaviour change.
            resolved = inputs.baseFloor
            fellBackToBaseFloor = true
        }

        // Step 5. Only ever raises.
        if inputs.useHardBaseFloor {
            let beforeClamp = resolved
            resolved = max(resolved, inputs.baseFloor)
            if resolved > beforeClamp {
                // The value now comes from baseFloor, so attribute it there.
                fellBackToBaseFloor = true
            }
        }

        // A zero reached only by falling back to an absent baseFloor is "no floor",
        // which the caller must render as an omitted imp.bidfloor. A zero that was
        // configured — an explicit 0 baseFloor, or a geo_floors match of 0 — is a
        // floor and stays a value.
        if inputs.baseFloorIsMissing && fellBackToBaseFloor && resolved == 0 {
            return .noFloor
        }
        return .value(resolved)
    }

    /// Step 3's tier chain, most specific first.
    ///
    /// PRESENCE, not truthiness. The web tests `hasOwnProperty` at each tier, so a
    /// key holding `0`, `""` or `null` still *matches* and stops the chain — the
    /// caller's falsy check then replaces it with baseFloor. It does not fall
    /// through to a lower tier.
    ///
    /// Gating these lookups on truthiness instead makes a zero floor on the most
    /// specific key fall through, returning the next tier's price where the web
    /// returns baseFloor. Pinned by `zero_at_top_tier_does_not_fall_through` and its
    /// two siblings, and verified directly against the web function.
    private static func ladderFloor(
        for request: FloorRequest, in floors: [String: FloorValue]
    ) -> FloorValue? {
        let fullKey = [
            request.platform,
            request.country,
            request.deviceClass,
            request.section,
            request.depthBucket
        ].joined(separator: "_")

        let tiers = [
            fullKey,
            "\(request.platform)_\(request.country)",
            request.country,
            "default"
        ]

        for key in tiers {
            if let match = floors[key] { return match }
        }
        return nil
    }

    /// Step 4's country grouping.
    ///
    /// Unlike the step-3 ladder this type-checks: a non-numeric value is skipped
    /// rather than assigned, which is why a string here leaves baseFloor standing
    /// while a string in step 3 is returned as-is. That asymmetry is real web
    /// behaviour — see `geo_floors_non_numeric_ignored`.
    private static func geoFloor(
        for country: String, in geo: [String: FloorValue]
    ) -> FloorValue? {
        /// Numeric-only lookup, mirroring `typeof geoFloors[k] === "number"`.
        func number(_ key: String) -> FloorValue? {
            guard let val = geo[key], case .number = val else { return nil }
            return val
        }

        let escCountries: Set<String> = ["CA", "GB", "AU", "NZ", "IE"]

        if let exact = number(country) { return exact }
        if escCountries.contains(country), let esc = number("ESC") { return esc }
        // ROW excludes the ESC set *and* US, so a US request with only ESC/ROW
        // configured matches neither and keeps baseFloor.
        if !escCountries.contains(country), country != "US", let row = number("ROW") {
            return row
        }
        return nil
    }
}
