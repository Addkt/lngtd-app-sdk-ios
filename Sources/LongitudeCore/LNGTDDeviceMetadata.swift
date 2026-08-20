import Foundation

public struct LNGTDDeviceMetadata: Sendable, Equatable {
    public let appBundle: String?
    public let appVersion: String?
    public let osVersion: String?
    public let deviceModel: String?
    public let ifa: String?
    public let ifaType: String?
    public let attStatus: String?

    public init(
        appBundle: String? = nil,
        appVersion: String? = nil,
        osVersion: String? = nil,
        deviceModel: String? = nil,
        ifa: String? = nil,
        ifaType: String? = nil,
        attStatus: String? = nil
    ) {
        self.appBundle = appBundle
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.deviceModel = deviceModel
        self.ifa = ifa
        self.ifaType = ifaType
        self.attStatus = attStatus
    }
}

public protocol LNGTDDeviceMetadataProvider: Sendable {
    func currentMetadata() -> LNGTDDeviceMetadata
}

public final class LNGTDDeviceMetadataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _metadata: LNGTDDeviceMetadata

    public init(metadata: LNGTDDeviceMetadata) {
        self._metadata = metadata
    }

    public var metadata: LNGTDDeviceMetadata {
        lock.lock()
        defer { lock.unlock() }
        return _metadata
    }

    public func update(metadata: LNGTDDeviceMetadata) {
        lock.lock()
        defer { lock.unlock() }
        self._metadata = metadata
    }
}
