import XCTest
@testable import LongitudeCore

final class MetadataFakeTransport: LNGTDEventTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var storedPayloads: [Data] = []

    var payloads: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return storedPayloads
    }

    func send(payload: Data, endpoint: LNGTDEndpoint) async -> LNGTDEventTransportResult {
        lock.lock()
        storedPayloads.append(payload)
        lock.unlock()
        return .success
    }
}

final class LNGTDDeviceMetadataTests: XCTestCase {

    private var tempDir = FileManager.default.temporaryDirectory

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lngtd-metadata-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    private struct SUT {
        let pipeline: LNGTDEventPipeline
        let transport: MetadataFakeTransport
        let metadataBox: LNGTDDeviceMetadataBox
        let configVersionBox: ConfigVersionTestBox
    }

    final class ConfigVersionTestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _version: String?
        var version: String? {
            get { lock.lock(); defer { lock.unlock() }; return _version }
            set { lock.lock(); defer { lock.unlock() }; _version = newValue }
        }
    }

    private func makeSUT() -> SUT {
        let transport = MetadataFakeTransport()
        let session = LNGTDSession()
        let box = LNGTDDeviceMetadataBox(metadata: LNGTDDeviceMetadata())
        let vBox = ConfigVersionTestBox()
        let pipeline = LNGTDEventPipeline(
            store: LNGTDEventStore(baseDirectory: tempDir),
            transport: transport,
            backgroundHost: nil,
            session: session,
            isSampled: { true },
            metadata: { box.metadata },
            configVersion: { vBox.version },
            deviceType: .phone
        )
        return SUT(pipeline: pipeline, transport: transport, metadataBox: box, configVersionBox: vBox)
    }

    private func settle(_ sut: SUT) async {
        await sut.pipeline.quiesce()
        await sut.pipeline.queue.awaitPendingSends()
    }

    private func custom(in payload: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let details = object["details"] as? [String: Any],
              let raw = details["custom"] as? String,
              let parsed = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return parsed
    }

    // 1.
    func test01_EmittedPageviewCarriesMetadataFields() async throws {
        let sut = makeSUT()
        sut.metadataBox.update(metadata: LNGTDDeviceMetadata(
            appBundle: "com.test.app",
            appVersion: "1.2.3",
            osVersion: "iOS 16.0",
            deviceModel: "iPhone14,2",
            ifa: nil,
            ifaType: nil,
            attStatus: "not_determined"
        ))

        sut.pipeline.trackScreenView("Home")
        await settle(sut)

        let c = try custom(in: sut.transport.payloads[0])
        XCTAssertEqual(c["app_bundle"] as? String, "com.test.app")
        XCTAssertEqual(c["app_version"] as? String, "1.2.3")
        XCTAssertEqual(c["sdk_version"] as? String, LNGTDSDKVersion)
        XCTAssertEqual(c["os_version"] as? String, "iOS 16.0")
        XCTAssertEqual(c["device_model"] as? String, "iPhone14,2")
        XCTAssertEqual(c["platform"] as? String, "ios")
    }

    // 2.
    func test02_NotAuthorizedIFAIsAbsent() async throws {
        let sut = makeSUT()
        sut.metadataBox.update(metadata: LNGTDDeviceMetadata(
            ifa: nil,
            ifaType: nil,
            attStatus: "not_determined"
        ))

        sut.pipeline.trackScreenView("Home")
        await settle(sut)

        let c = try custom(in: sut.transport.payloads[0])
        XCTAssertNil(c["ifa"], "ifa must be absent")
        XCTAssertNil(c["ifa_type"], "ifa_type must be absent")
    }

    // 3.
    func test03_AuthorizedIFAIsPresent() async throws {
        let sut = makeSUT()
        sut.metadataBox.update(metadata: LNGTDDeviceMetadata(
            ifa: "AABBCCDD-1234-5678-ABCD-0123456789AB",
            ifaType: "idfa",
            attStatus: "authorized"
        ))

        sut.pipeline.trackScreenView("Home")
        await settle(sut)

        let c = try custom(in: sut.transport.payloads[0])
        XCTAssertEqual(c["ifa"] as? String, "AABBCCDD-1234-5678-ABCD-0123456789AB")
        XCTAssertEqual(c["ifa_type"] as? String, "idfa")
    }

    // 4.
    func test04_AllZeroIFAIsAbsent() async throws {
        let sut = makeSUT()
        sut.metadataBox.update(metadata: LNGTDDeviceMetadata(
            ifa: "00000000-0000-0000-0000-000000000000",
            ifaType: "idfa",
            attStatus: "authorized"
        ))

        sut.pipeline.trackScreenView("Home")
        await settle(sut)

        let c = try custom(in: sut.transport.payloads[0])
        XCTAssertNil(c["ifa"], "All zero UUID must be omitted")
    }

    // 5.
    func test05_IfaTypeIsAbsentWhenIfaIsAbsent() async throws {
        let sut = makeSUT()
        sut.metadataBox.update(metadata: LNGTDDeviceMetadata(
            ifa: nil,
            ifaType: "idfa",
            attStatus: "denied"
        ))

        sut.pipeline.trackScreenView("Home")
        await settle(sut)

        let c = try custom(in: sut.transport.payloads[0])
        XCTAssertNil(c["ifa"])
        XCTAssertNil(c["ifa_type"], "ifa_type must be absent when ifa is absent")
    }

    // 6.
    func test06_ATTStatusStringsDoNotCollide() async throws {
        let sut = makeSUT()
        let statuses = ["authorized", "denied", "not_determined", "restricted", "unknown"]
        var seen = Set<String>()

        for status in statuses {
            sut.metadataBox.update(metadata: LNGTDDeviceMetadata(attStatus: status))
            sut.pipeline.trackScreenView(status)
        }
        await settle(sut)

        for payload in sut.transport.payloads {
            let c = try custom(in: payload)
            if let st = c["att_status"] as? String {
                seen.insert(st)
            }
        }
        XCTAssertEqual(seen.count, statuses.count)
    }

    // 7.
    func test07_StatusChangeUpdatesNextEvent() async throws {
        let sut = makeSUT()
        sut.metadataBox.update(metadata: LNGTDDeviceMetadata(attStatus: "not_determined"))
        sut.pipeline.trackScreenView("Home")

        sut.metadataBox.update(metadata: LNGTDDeviceMetadata(attStatus: "authorized"))
        sut.pipeline.trackScreenView("Feed")
        await settle(sut)

        let c1 = try custom(in: sut.transport.payloads[0])
        let c2 = try custom(in: sut.transport.payloads[1])
        XCTAssertEqual(c1["att_status"] as? String, "not_determined")
        XCTAssertEqual(c2["att_status"] as? String, "authorized")
    }

    // 8.
    func test08_DeviceModelWithCommaSurvives() async throws {
        let sut = makeSUT()
        sut.metadataBox.update(metadata: LNGTDDeviceMetadata(deviceModel: "iPhone14,2"))

        sut.pipeline.trackScreenView("Home")
        await settle(sut)

        let c = try custom(in: sut.transport.payloads[0])
        XCTAssertEqual(c["device_model"] as? String, "iPhone14,2")
    }

    // 9.
    func test09_ConfigVersionUpdates() async throws {
        let sut = makeSUT()
        sut.configVersionBox.version = "v1"
        sut.pipeline.trackScreenView("Home")

        sut.configVersionBox.version = "v2"
        sut.pipeline.trackScreenView("Feed")
        await settle(sut)

        let c1 = try custom(in: sut.transport.payloads[0])
        let c2 = try custom(in: sut.transport.payloads[1])
        XCTAssertEqual(c1["config_version"] as? String, "v1")
        XCTAssertEqual(c2["config_version"] as? String, "v2")
    }

    // 10.
    func test10_SDKVersionMatchesHeader() async throws {
        let sut = makeSUT()
        sut.pipeline.trackScreenView("Home")
        await settle(sut)

        let c = try custom(in: sut.transport.payloads[0])
        let sdkV = c["sdk_version"] as? String

        // Assert matches the constant used in transport header
        XCTAssertEqual(sdkV, LNGTDSDKVersion)

        // Let's also make a transport instance to confirm it's used
        let transport = URLSessionEventTransport()
        let mirror = Mirror(reflecting: transport)
        let transportVersion = mirror.children.first(where: { $0.label == "sdkVersion" })?.value as? String
        XCTAssertEqual(sdkV, transportVersion)
    }

    // 11.
    func test11_UnknownFieldsAreAbsent() async throws {
        let sut = makeSUT()
        sut.pipeline.trackScreenView("Home")
        await settle(sut)

        let c = try custom(in: sut.transport.payloads[0])
        // Missing fields should not be empty strings. They should not exist.
        XCTAssertNil(c["app_bundle"])
        XCTAssertNil(c["device_model"])
        XCTAssertNil(c["os_version"])
    }

    // 12.
    func test12_PrivacyManifest() throws {
        let url = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LongitudeGAM/PrivacyInfo.xcprivacy")

        let data = try Data(contentsOf: url)
        let parsed = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        )
        guard let plist = parsed as? [String: Any] else {
            XCTFail("Not a plist dictionary")
            return
        }

        let tracking = plist["NSPrivacyTracking"] as? Bool
        XCTAssertEqual(tracking, true)

        guard let domains = plist["NSPrivacyTrackingDomains"] as? [String] else {
            XCTFail("Missing domains")
            return
        }
        // An EXACT set, not `contains`. Over-declaring is the direction that does damage:
        // domains listed here are blocked by the OS when the user denies tracking, so adding
        // the config host would silently stop floor updates — and the kill switch — from ever
        // reaching a denied user. `contains` cannot see an extra entry.
        XCTAssertEqual(
            Set(domains), ["ld.lngtd.com", "it.lngtd.com"],
            "only domains that actually receive a tracking identifier belong here"
        )

        // Tied to the real endpoints, so renaming a host breaks this rather than drifting.
        XCTAssertEqual(
            Set(domains),
            Set([
                URLSessionEventTransport.defaultPrimaryURL.host,
                URLSessionEventTransport.defaultFallbackURL.host
            ].compactMap { $0 }),
            "the manifest must list exactly the endpoints the transport posts to"
        )

        // The config fetch carries account, section, ct and p — no identifier of any kind.
        XCTAssertFalse(
            domains.contains("floors.lngtd.com"),
            "the config host is not a tracking domain; listing it blocks config for denied users"
        )

        // Tied to the constant rather than a literal, so renaming the host cannot quietly
        // break the link. The non-tracking endpoint exists precisely to be reachable when
        // tracking is denied; listing it here would block it and undo the whole of 2e-8.
        if let nonTrackingHost = URLSessionEventTransport.defaultNonTrackingURL.host {
            XCTAssertFalse(
                domains.contains(nonTrackingHost),
                "\(nonTrackingHost) must never be a tracking domain — listing it blocks the "
                + "endpoint that carries events for ATT-denied users"
            )
        }
    }
}
