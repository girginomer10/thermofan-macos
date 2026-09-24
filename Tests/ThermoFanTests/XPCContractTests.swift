import FanControlXPC
import Foundation
import ObjectiveC.runtime
import XCTest

/// Pins the NSXPC wire contract between the app and an already-registered
/// root daemon. The extended encodings carry every reply block's signature, so
/// a swapped, re-ordered, added, or retyped argument fails here and has to ship
/// as a deliberate protocol or implementation-revision change.
final class XPCContractTests: XCTestCase {
    private typealias ExtendedTypeEncoding =
        @convention(c) (Protocol, Selector, ObjCBool, ObjCBool) -> UnsafePointer<CChar>?

    /// Selector -> (method type encoding, extended encoding with the reply block).
    private static let requiredInstanceMethods: [String: (String, String)] = [
        "handshakeWithProtocolVersion:reply:":
            ("v32@0:8q16@?24", #"v32@0:8q16@?<v@?qqq@"NSString">24"#),
        "armWatchdogWithProtocolVersion:fanIndex:reply:":
            ("v40@0:8q16q24@?32", #"v40@0:8q16q24@?<v@?q@"NSString">32"#),
        "heartbeatWithProtocolVersion:reply:":
            ("v32@0:8q16@?24", #"v32@0:8q16@?<v@?q@"NSString">24"#),
        "applyFanWithProtocolVersion:fanIndex:mode:rpm:revision:reply:":
            ("v64@0:8q16q24q32q40Q48@?56", #"v64@0:8q16q24q32q40Q48@?<v@?q@"NSString">56"#),
        "returnAllFansToAutomaticWithProtocolVersion:reply:":
            ("v32@0:8q16@?24", #"v32@0:8q16@?<v@?q@"NSString">24"#),
        "retryAutomaticRecoveryWithProtocolVersion:reply:":
            ("v32@0:8q16@?24", #"v32@0:8q16@?<v@?q@"NSString">24"#),
        "recoveryHandshakeWithReply:":
            ("v24@0:8@?16", #"v24@0:8@?<v@?qqq@"NSString">16"#),
        "prepareForServiceRemovalWithReply:":
            ("v24@0:8@?16", #"v24@0:8@?<v@?q@"NSString">16"#)
    ]

    func testDaemonProtocolExposesExactlyThePinnedSelectorsAndEncodings() throws {
        let daemonProtocol = try XCTUnwrap(NSProtocolFromString("FanControlXPC.ThermoFanDaemonProtocol"))
        XCTAssertTrue(protocol_isEqual(daemonProtocol, ThermoFanDaemonProtocol.self))
        let symbol = try XCTUnwrap(
            dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_protocol_getMethodTypeEncoding"),
            "The Objective-C runtime no longer exports extended protocol encodings."
        )
        let extendedTypes = unsafeBitCast(symbol, to: ExtendedTypeEncoding.self)

        XCTAssertEqual(selectors(daemonProtocol, required: true, instance: true), Set(Self.requiredInstanceMethods.keys))
        XCTAssertTrue(selectors(daemonProtocol, required: false, instance: true).isEmpty)
        XCTAssertTrue(selectors(daemonProtocol, required: true, instance: false).isEmpty)
        XCTAssertTrue(selectors(daemonProtocol, required: false, instance: false).isEmpty)

        for (name, (types, extended)) in Self.requiredInstanceMethods {
            let selector = NSSelectorFromString(name)
            let description = protocol_getMethodDescription(daemonProtocol, selector, true, true)
            XCTAssertEqual(description.types.map { String(cString: $0) }, types, name)
            XCTAssertEqual(extendedTypes(daemonProtocol, selector, true, true).map { String(cString: $0) }, extended, name)
        }
    }

    func testStatusCodesRevisionsAndIdentifiersArePinned() {
        XCTAssertEqual(ThermoFanXPC.protocolVersion, 9)
        XCTAssertEqual(ThermoFanXPC.stableRecoveryProtocolVersion, 9)
        XCTAssertEqual(ThermoFanXPC.implementationRevision, 10)
        XCTAssertEqual(ThermoFanXPC.recoveryRequiredStatus, 75)
        XCTAssertEqual(ThermoFanXPC.leaseLostStatus, 76)
        XCTAssertEqual(ThermoFanXPC.notConsoleUserStatus, 77)
        XCTAssertEqual(ThermoFanXPC.retiringStatus, 78)
        XCTAssertEqual(ThermoFanXPC.appIdentifier, "io.github.girginomer10.ThermoFan")
        XCTAssertEqual(ThermoFanXPC.helperIdentifier, "io.github.girginomer10.ThermoFan.helper")
        XCTAssertEqual(ThermoFanXPC.daemonPlistName, "io.github.girginomer10.ThermoFan.helper.plist")
    }

    private func selectors(_ proto: Protocol, required: Bool, instance: Bool) -> Set<String> {
        var count: UInt32 = 0
        guard let list = protocol_copyMethodDescriptionList(proto, required, instance, &count) else { return [] }
        defer { free(list) }
        return Set((0..<Int(count)).compactMap { list[$0].name.map(NSStringFromSelector) })
    }
}
