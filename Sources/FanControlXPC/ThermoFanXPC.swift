import Foundation
import Security

/// Narrow, versioned protocol shared by the user app and the root daemon.
/// Caller identity is deliberately absent: the daemon obtains PID, UID, and
/// audit-session metadata from the kernel-owned NSXPCConnection.
@objc public protocol ThermoFanDaemonProtocol {
    func handshake(
        protocolVersion: Int,
        reply: @escaping @Sendable (Int, Int, Int, String) -> Void
    )

    func armWatchdog(
        protocolVersion: Int,
        fanIndex: Int,
        reply: @escaping @Sendable (Int, String) -> Void
    )

    func heartbeat(
        protocolVersion: Int,
        reply: @escaping @Sendable (Int, String) -> Void
    )

    func applyFan(
        protocolVersion: Int,
        fanIndex: Int,
        mode: Int,
        rpm: Int,
        revision: UInt64,
        reply: @escaping @Sendable (Int, String) -> Void
    )

    func returnAllFansToAutomatic(
        protocolVersion: Int,
        reply: @escaping @Sendable (Int, String) -> Void
    )

    func retryAutomaticRecovery(
        protocolVersion: Int,
        reply: @escaping @Sendable (Int, String) -> Void
    )

    /// Stable from protocol 9 onward. Future app versions must retain this
    /// selector so an older registered daemon can prove Auto before update or
    /// uninstall, even when the normal wire protocol has changed.
    func recoveryHandshake(
        reply: @escaping @Sendable (Int, Int, Int, String) -> Void
    )

    func prepareForServiceRemoval(
        reply: @escaping @Sendable (Int, String) -> Void
    )
}

public enum ThermoFanXPC {
    public static let protocolVersion = 9
    /// Bump whenever the daemon executable or launchd plist changes without a
    /// wire-protocol change. A mismatch forces verified Auto, unregister, then
    /// re-registration before the new helper can write.
    /// The direct-release build number is intentionally tied to this value so
    /// launchd payload changes cannot be shipped without forcing an update.
    public static let implementationRevision = 9
    public static let stableRecoveryProtocolVersion = 9
    public static let recoveryRequiredStatus = 75
    public static let leaseLostStatus = 76
    public static let appIdentifier = "io.github.girginomer10.ThermoFan"
    public static let helperIdentifier = "io.github.girginomer10.ThermoFan.helper"
    public static let daemonPlistName = "io.github.girginomer10.ThermoFan.helper.plist"
    public static let heartbeatInterval: TimeInterval = 2
    public static let heartbeatTimeout: TimeInterval = 8
    public static let maximumFanIndex = 7
    public static let maximumRPM = 20_000

    public enum Mode: Int {
        case automatic = 0
        case fixed = 1
        case curve = 2
    }

    /// Returns the Team ID of the running signed code. Ad-hoc signatures have
    /// no Team ID and are intentionally ineligible for privileged fan control.
    public static func currentTeamIdentifier() -> String? {
        guard let staticCode = currentStaticCode() else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
        let dictionary = information as? [CFString: Any],
        let teamID = dictionary[kSecCodeInfoTeamIdentifier] as? String,
        isSafeSigningComponent(teamID)
        else {
            return nil
        }
        return teamID
    }

    public static func currentCodeIsDeveloperID(identifier: String) -> Bool {
        guard let staticCode = currentStaticCode(),
              let teamID = currentTeamIdentifier(),
              let expression = developerIDRequirement(identifier: identifier, teamID: teamID)
        else {
            return false
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              let requirement
        else {
            return false
        }
        return SecStaticCodeCheckValidity(
            staticCode,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            requirement
        ) == errSecSuccess
    }

    /// Exact Developer ID Application peer requirement. Besides the exact
    /// identifier and Team ID, the Developer ID OIDs are pinned and a debug
    /// (`get-task-allow`) peer is rejected.
    public static func developerIDRequirement(identifier: String, teamID: String) -> String? {
        guard isSafeIdentifier(identifier), isSafeSigningComponent(teamID) else {
            return nil
        }
        return "anchor apple generic"
            + " and identifier \"\(identifier)\""
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and certificate leaf[subject.OU] = \"\(teamID)\""
            + " and ! entitlement[\"com.apple.security.get-task-allow\"] exists"
    }

    public static func peerRequirement(identifier: String, currentIdentifier: String) -> String? {
        guard currentCodeIsDeveloperID(identifier: currentIdentifier) else { return nil }
        guard let teamID = currentTeamIdentifier() else { return nil }
        return developerIDRequirement(identifier: identifier, teamID: teamID)
    }

    private static func currentStaticCode() -> SecStaticCode? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess else {
            return nil
        }
        return staticCode
    }

    public static func isSafeIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 255 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-"
        }
    }

    public static func isSafeSigningComponent(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 64 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
        }
    }
}
