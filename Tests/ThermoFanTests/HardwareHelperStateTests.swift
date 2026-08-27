import XCTest
import FanControlXPC
import ObjectiveC.runtime
import ServiceManagement
@testable import ThermoFan

final class HardwareHelperStateTests: XCTestCase {
    func testOnlyAuthenticatedReadyHelperIsUsable() {
        XCTAssertFalse(HardwareHelperState.missing.isUsable)
        XCTAssertFalse(HardwareHelperState.legacyCleanupRequired.isUsable)
        XCTAssertFalse(HardwareHelperState.approvalRequired.isUsable)
        XCTAssertFalse(HardwareHelperState.updateRequired.isUsable)
        XCTAssertFalse(HardwareHelperState.recoveryBlocked.isUsable)
        XCTAssertTrue(HardwareHelperState.ready.isUsable)
    }

    func testSetuidLegacyFallbackIsRemovedInProtocolV9() {
        XCTAssertEqual(FanControlService.expectedHelperVersion, "9")
        XCTAssertNil(FanControlService.compatibleLegacyHelperVersion)
        XCTAssertEqual(FanControlService.recoveryRequiredExitCode, 75)
    }

    func testAdHocTestHostCannotConstructAPrivilegedPeerRequirement() {
        XCTAssertFalse(ThermoFanXPC.currentCodeIsDeveloperID(identifier: ThermoFanXPC.appIdentifier))
        XCTAssertNil(ThermoFanXPC.peerRequirement(
            identifier: ThermoFanXPC.helperIdentifier,
            currentIdentifier: ThermoFanXPC.appIdentifier
        ))
    }

    func testDeveloperIDRequirementPinsIdentityTeamAndDebugEntitlement() throws {
        let requirement = try XCTUnwrap(ThermoFanXPC.developerIDRequirement(
            identifier: ThermoFanXPC.appIdentifier,
            teamID: "ABCDE12345"
        ))

        XCTAssertTrue(requirement.contains("identifier \"io.github.girginomer10.ThermoFan\""))
        XCTAssertTrue(requirement.contains("certificate leaf[subject.OU] = \"ABCDE12345\""))
        XCTAssertTrue(requirement.contains("certificate leaf[field.1.2.840.113635.100.6.1.13] exists"))
        XCTAssertTrue(requirement.contains("! entitlement[\"com.apple.security.get-task-allow\"] exists"))
        XCTAssertNil(ThermoFanXPC.developerIDRequirement(identifier: "bad\"id", teamID: "ABCDE12345"))
        XCTAssertNil(ThermoFanXPC.developerIDRequirement(identifier: ThermoFanXPC.appIdentifier, teamID: "BAD TEAM"))
    }

    func testStableProtocolNineRemovalSelectorCannotDisappear() {
        XCTAssertEqual(ThermoFanXPC.protocolVersion, 9)
        XCTAssertEqual(ThermoFanXPC.stableRecoveryProtocolVersion, 9)
        XCTAssertEqual(ThermoFanXPC.implementationRevision, 9)

        let selector = NSSelectorFromString("prepareForServiceRemovalWithReply:")
        let description = protocol_getMethodDescription(
            ThermoFanDaemonProtocol.self,
            selector,
            true,
            true
        )
        XCTAssertNotNil(description.name)

        let handshakeSelector = NSSelectorFromString("recoveryHandshakeWithReply:")
        let handshakeDescription = protocol_getMethodDescription(
            ThermoFanDaemonProtocol.self,
            handshakeSelector,
            true,
            true
        )
        XCTAssertNotNil(handshakeDescription.name)
    }

    func testServiceStatusRequiresLiveCurrentHandshake() {
        let ready = PrivilegedFanClient.Handshake(
            protocolVersion: ThermoFanXPC.protocolVersion,
            implementationRevision: ThermoFanXPC.implementationRevision,
            status: 0,
            message: "ready"
        )
        let stale = PrivilegedFanClient.Handshake(
            protocolVersion: ThermoFanXPC.protocolVersion,
            implementationRevision: ThermoFanXPC.implementationRevision - 1,
            status: 0,
            message: "stale"
        )
        let blocked = PrivilegedFanClient.Handshake(
            protocolVersion: ThermoFanXPC.protocolVersion,
            implementationRevision: ThermoFanXPC.implementationRevision,
            status: ThermoFanXPC.recoveryRequiredStatus,
            message: "blocked"
        )

        XCTAssertEqual(state(.notRegistered, handshake: nil), .missing)
        XCTAssertEqual(state(.requiresApproval, handshake: nil), .approvalRequired)
        XCTAssertEqual(state(.enabled, handshake: nil), .updateRequired)
        XCTAssertEqual(state(.enabled, handshake: stale), .updateRequired)
        XCTAssertEqual(state(.enabled, handshake: blocked), .recoveryBlocked)
        XCTAssertEqual(state(.enabled, handshake: ready), .ready)
    }

    private func state(
        _ serviceStatus: SMAppService.Status,
        handshake: PrivilegedFanClient.Handshake?
    ) -> HardwareHelperState {
        PrivilegedFanClient.helperState(
            serviceStatus: serviceStatus,
            hasDeveloperIDTeam: true,
            isInApplications: true,
            bundleContainsDaemon: true,
            handshake: handshake
        )
    }
}
