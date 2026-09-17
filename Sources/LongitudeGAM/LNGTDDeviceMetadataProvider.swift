#if os(iOS)
import Foundation
import UIKit
import AppTrackingTransparency
import AdSupport
import LongitudeCore

/// Reads the device fields contract §5 expects.
///
/// Everything here is main-actor state, and the event path is not on main, so the caller
/// caches the result in a box the synchronous path reads. See `Longitude.start`.
public final class DefaultDeviceMetadataProvider: LNGTDDeviceMetadataProvider, @unchecked Sendable {
    /// The value `ASIdentifierManager` hands back when tracking is not authorised.
    ///
    /// It is a syntactically valid UUID, so nothing downstream rejects it — every unauthorised
    /// device on every install would collapse into this single identifier and any count
    /// distinct on `ifa` would be wrong while looking healthy. `LNGTDEventCustomDetails` also
    /// rejects it, because the two checks can disagree after a status change.
    static let unauthorisedIdentifier = "00000000-0000-0000-0000-000000000000"

    public init() {}

    public func currentMetadata() -> LNGTDDeviceMetadata {
        guard !Thread.isMainThread else {
            return Self.read()
        }
        // `UIDevice` and `ATTrackingManager` are main-actor. Guarded so this can never be
        // reached from main, where `sync` would deadlock.
        return DispatchQueue.main.sync { Self.read() }
    }

    private static func read() -> LNGTDDeviceMetadata {
        let status = trackingStatus()
        let identifier = advertisingIdentifier(for: status)

        return LNGTDDeviceMetadata(
            appBundle: Bundle.main.bundleIdentifier,
            // The marketing version, not CFBundleVersion. A publisher can put anything in it —
            // an internal build numbered "1.0.0,42" is exactly why these fields live in
            // `custom` rather than the comma-truncating `extra`.
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            osVersion: UIDevice.current.systemVersion,
            deviceModel: deviceModel(),
            ifa: identifier,
            ifaType: identifier == nil ? nil : "idfa",
            attStatus: string(for: status)
        )
    }

    /// `hw.machine`, giving `iPhone14,2`. `UIDevice.current.model` returns only `"iPhone"`.
    ///
    /// Returns nil rather than a placeholder when it cannot be read: a literal `"Unknown"` is a
    /// magic string that reaches the warehouse as if it were a device.
    private static func deviceModel() -> String? {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return simulatorModel() }

        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        let raw = String(cString: machine)

        // On a simulator `hw.machine` is the host architecture, not a device. This branch
        // exists for that and nothing else.
        if raw == "arm64" || raw == "x86_64" {
            return simulatorModel() ?? raw
        }
        return raw.isEmpty ? nil : raw
    }

    private static func simulatorModel() -> String? {
        ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
    }

    private static func trackingStatus() -> ATTrackingManager.AuthorizationStatus {
        #if DEBUG
        // Debug only. Compiling an override for a privacy-sensitive value into a release
        // binary would let a shipped app's ATT status be spoofed from launch arguments.
        if let forced = forcedStatus() {
            return forced
        }
        #endif
        return ATTrackingManager.trackingAuthorizationStatus
    }

    #if DEBUG
    private static func forcedStatus() -> ATTrackingManager.AuthorizationStatus? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-LNGTD_FAKE_ATT"),
              index + 1 < arguments.count else {
            return nil
        }
        switch arguments[index + 1] {
        case "authorized": return .authorized
        case "denied": return .denied
        case "not_determined": return .notDetermined
        case "restricted": return .restricted
        default: return nil
        }
    }
    #endif

    /// Never requests authorisation. The prompt is the publisher's to time — `waitsForATT`
    /// exists because starting GMA before ATT resolves loses the IDFA on the first requests —
    /// and an SDK raising it fires at a moment they did not choose.
    private static func advertisingIdentifier(
        for status: ATTrackingManager.AuthorizationStatus
    ) -> String? {
        guard status == .authorized else { return nil }
        let identifier = ASIdentifierManager.shared().advertisingIdentifier.uuidString
        return identifier == unauthorisedIdentifier ? nil : identifier
    }

    private static func string(for status: ATTrackingManager.AuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .notDetermined: return "not_determined"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }
}
#endif
