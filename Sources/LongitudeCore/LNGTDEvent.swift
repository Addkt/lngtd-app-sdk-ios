import Foundation

public enum LNGTDBrowser: String, Encodable, Sendable {
    case ios
}

public enum LNGTDDeviceType: String, Encodable, Sendable {
    case phone
    case tablet
}

public enum LNGTDPlatform: String, Encodable, Sendable {
    case ios
    case android
}

public struct LNGTDEventCustomDetails: Encodable, Sendable {
    /// Swift properties are camelCase; the wire keys are the snake_case names the
    /// warehouse reads with `JSON_VALUE(custom_details.<key>)`. The mapping lives in
    /// `CodingKeys` below.
    ///
    /// `creativeId` and `regionState` are camelCase on the wire too — those are the
    /// existing names the web client sends, and matching the warehouse beats internal
    /// consistency. Renaming them to `creative_id` would create a second column nothing
    /// queries.
    public let platform: LNGTDPlatform
    public let appBundle: String?
    public let appVersion: String?
    public let sdkVersion: String?
    public let osVersion: String?
    public let deviceModel: String?
    public let ifa: String?
    public let ifaType: String?
    public let attStatus: String?
    public let connection: String?
    public let sessionId: String?
    public let configVersion: String?
    /// The contract lacks a top-level `pageview_id`, so it goes here in `custom` for now.
    public let pageviewId: String?

    public let uid: String?
    public let bidUid: String?
    public let auctionId: String?
    public let bidder: String?
    public let creativeId: String?
    public let asn: String?
    public let regionState: String?
    public let version: String?

    public init(
        platform: LNGTDPlatform,
        appBundle: String? = nil,
        appVersion: String? = nil,
        sdkVersion: String? = nil,
        osVersion: String? = nil,
        deviceModel: String? = nil,
        ifa: String? = nil,
        ifaType: String? = nil,
        attStatus: String? = nil,
        connection: String? = nil,
        sessionId: String? = nil,
        configVersion: String? = nil,
        pageviewId: String? = nil,
        uid: String? = nil,
        bidUid: String? = nil,
        auctionId: String? = nil,
        bidder: String? = nil,
        creativeId: String? = nil,
        asn: String? = nil,
        regionState: String? = nil,
        version: String? = nil
    ) {
        self.platform = platform
        self.appBundle = appBundle
        self.appVersion = appVersion
        self.sdkVersion = sdkVersion
        self.osVersion = osVersion
        self.deviceModel = deviceModel
        self.ifa = ifa
        self.ifaType = ifaType
        self.attStatus = attStatus
        self.connection = connection
        self.sessionId = sessionId
        self.configVersion = configVersion
        self.pageviewId = pageviewId
        self.uid = uid
        self.bidUid = bidUid
        self.auctionId = auctionId
        self.bidder = bidder
        self.creativeId = creativeId
        self.asn = asn
        self.regionState = regionState
        self.version = version
    }

    private enum CodingKeys: String, CodingKey {
        // Wire names that already match the Swift spelling.
        case platform, ifa, connection, uid, bidder, asn, version
        // Existing web keys that are camelCase on the wire — do not "correct" these.
        case creativeId, regionState
        // Swift camelCase to snake_case wire names.
        case appBundle = "app_bundle"
        case appVersion = "app_version"
        case sdkVersion = "sdk_version"
        case osVersion = "os_version"
        case deviceModel = "device_model"
        case ifaType = "ifa_type"
        case attStatus = "att_status"
        case sessionId = "session_id"
        case configVersion = "config_version"
        case pageviewId = "pageview_id"
        case bidUid = "bid_uid"
        case auctionId = "auction_id"
    }
}

public struct LNGTDEvent: Encodable, Sendable {
    public let event: LNGTDEventName
    public let timestamp: Int64
    public let details: Details

    public struct Details: Encodable, Sendable {
        public let account: String?
        public let section: String?
        public let page: String?
        public let pageUrl: String?
        public let referrerUrl: String?
        public let browser: LNGTDBrowser
        public let deviceType: LNGTDDeviceType
        public let unit: String?
        public let sessionDepth: Int?

        public let custom: LNGTDEventCustomDetails

        public init(
            account: String? = nil,
            section: String? = nil,
            page: String? = nil,
            pageUrl: String? = nil,
            referrerUrl: String? = nil,
            browser: LNGTDBrowser = .ios,
            deviceType: LNGTDDeviceType,
            unit: String? = nil,
            sessionDepth: Int? = nil,
            custom: LNGTDEventCustomDetails
        ) {
            self.account = account
            self.section = section
            self.page = page
            self.pageUrl = pageUrl
            self.referrerUrl = referrerUrl
            self.browser = browser
            self.deviceType = deviceType
            self.unit = unit
            self.sessionDepth = sessionDepth
            self.custom = custom
        }

        private enum CodingKeys: String, CodingKey {
            case account, section, page, browser, unit, custom, extra
            case pageUrl = "page_url"
            case referrerUrl = "referrer_url"
            case deviceType = "device_type"
            case sessionDepth = "session_depth"
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(account, forKey: .account)
            try container.encodeIfPresent(section, forKey: .section)
            try container.encodeIfPresent(page, forKey: .page)
            try container.encodeIfPresent(pageUrl, forKey: .pageUrl)
            try container.encodeIfPresent(referrerUrl, forKey: .referrerUrl)
            try container.encode(browser, forKey: .browser)
            try container.encode(deviceType, forKey: .deviceType)
            try container.encodeIfPresent(unit, forKey: .unit)
            try container.encodeIfPresent(sessionDepth, forKey: .sessionDepth)

            let customEncoder = JSONEncoder()
            let customData = try customEncoder.encode(custom)
            if let customString = String(data: customData, encoding: .utf8) {
                try container.encode(customString, forKey: .custom)
            } else {
                try container.encode("{}", forKey: .custom)
            }

            // Deliberately chose an empty JSON object for extra.
            // Putting version or sampleRate here subjects them to a regex truncation bug downstream
            // if a value contains a comma. Leaving it empty preserves the warehouse expectation
            // without corrupting data or duplicating it.
            try container.encode("{}", forKey: .extra)
        }
    }

    public init(
        event: LNGTDEventName,
        clock: () -> TimeInterval = { Date().timeIntervalSince1970 },
        details: Details
    ) {
        self.event = event
        self.timestamp = Int64(clock() * 1000)
        self.details = details
    }
}
