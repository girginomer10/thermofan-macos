import XCTest
import FanControlXPC
import ObjectiveC.runtime
import ServiceManagement
@testable import ThermoFan

final class HardwareHelperStateTests: XCTestCase {
    private static let allStates: [HardwareHelperState] = [
        .missing, .legacyCleanupRequired, .approvalRequired, .updateRequired, .recoveryBlocked,
        .ready, .monitoringOnly, .wrongLocation, .inactiveSession, .unreachable
    ]

    func testOnlyAuthenticatedReadyHelperIsUsable() {
        for state in Self.allStates {
            XCTAssertEqual(state.isUsable, state == .ready, "\(state)")
        }
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
        XCTAssertEqual(ThermoFanXPC.implementationRevision, 10)

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

    func testBuildLevelStatesDoNotDependOnLaunchdOrTheDaemon() {
        let ready = Self.handshake(status: 0)

        XCTAssertEqual(state(isDeveloperID: false, handshake: .success(ready)), .monitoringOnly)
        XCTAssertEqual(state(isDeveloperID: false, isInApplications: false), .monitoringOnly)
        XCTAssertEqual(state(bundleContainsDaemon: false, handshake: .success(ready)), .monitoringOnly)
        XCTAssertEqual(state(bundleContainsDaemon: false, isInApplications: false), .monitoringOnly)
        XCTAssertEqual(state(isInApplications: false, handshake: .success(ready)), .wrongLocation)
    }

    func testRegistrationStatesFollowServiceManagement() {
        XCTAssertEqual(state(.notRegistered), .missing)
        XCTAssertEqual(state(.requiresApproval), .approvalRequired)
        XCTAssertEqual(state(.notFound), .monitoringOnly)
    }

    func testEnabledServiceRequiresALiveVersionCurrentHandshake() {
        let staleRevision = Self.handshake(revision: ThermoFanXPC.implementationRevision - 1, status: 0)
        let otherProtocol = Self.handshake(protocolVersion: ThermoFanXPC.protocolVersion + 1, status: 0)
        let staleAndBlocked = Self.handshake(
            revision: ThermoFanXPC.implementationRevision - 1,
            status: ThermoFanXPC.recoveryRequiredStatus
        )

        XCTAssertEqual(state(.enabled, handshake: .success(Self.handshake(status: 0))), .ready)
        XCTAssertEqual(state(.enabled, handshake: nil), .unreachable)
        XCTAssertEqual(state(.enabled, handshake: .success(staleRevision)), .updateRequired)
        XCTAssertEqual(state(.enabled, handshake: .success(otherProtocol)), .updateRequired)
        XCTAssertEqual(state(.enabled, handshake: .success(staleAndBlocked)), .updateRequired)
    }

    func testEnabledServiceMapsDaemonStatuses() {
        XCTAssertEqual(
            state(.enabled, handshake: .success(Self.handshake(status: ThermoFanXPC.recoveryRequiredStatus))),
            .recoveryBlocked
        )
        XCTAssertEqual(
            state(.enabled, handshake: .success(Self.handshake(status: ThermoFanXPC.notConsoleUserStatus))),
            .inactiveSession
        )
        XCTAssertEqual(
            state(.enabled, handshake: .success(Self.handshake(status: ThermoFanXPC.retiringStatus))),
            .updateRequired
        )
        XCTAssertEqual(state(.enabled, handshake: .success(Self.handshake(status: 1))), .unreachable)
    }

    func testEnabledServiceWithoutAnAnswerIsUnreachable() {
        let timeout = PrivilegedFanClient.TransportError.timeout("timed out")
        let connection = PrivilegedFanClient.TransportError.connection("interrupted")

        XCTAssertEqual(state(.enabled, handshake: .failure(timeout)), .unreachable)
        XCTAssertEqual(state(.enabled, handshake: .failure(connection)), .unreachable)
    }

    func testLegacyHelperOnlyOverridesStatesRegistrationCanResolve() {
        for state in Self.allStates {
            XCTAssertEqual(FanControlService.resolvedState(state, hasLegacyHelper: false), state)
        }
        for state: HardwareHelperState in [.missing, .approvalRequired, .updateRequired, .ready, .unreachable] {
            XCTAssertEqual(
                FanControlService.resolvedState(state, hasLegacyHelper: true),
                .legacyCleanupRequired,
                "\(state)"
            )
        }
        for state: HardwareHelperState in [.recoveryBlocked, .monitoringOnly, .wrongLocation, .inactiveSession] {
            XCTAssertEqual(FanControlService.resolvedState(state, hasLegacyHelper: true), state, "\(state)")
        }
    }

    private func state(
        _ serviceStatus: SMAppService.Status = .enabled,
        isDeveloperID: Bool = true,
        bundleContainsDaemon: Bool = true,
        isInApplications: Bool = true,
        handshake: Swift.Result<PrivilegedFanClient.Handshake, Error>? = nil
    ) -> HardwareHelperState {
        PrivilegedFanClient.deriveState(
            bundleContainsDaemon: bundleContainsDaemon,
            isRunningFromApplications: isInApplications,
            isDeveloperID: isDeveloperID,
            status: serviceStatus,
            handshake: handshake
        )
    }

    private static func handshake(
        protocolVersion: Int = ThermoFanXPC.protocolVersion,
        revision: Int = ThermoFanXPC.implementationRevision,
        status: Int
    ) -> PrivilegedFanClient.Handshake {
        PrivilegedFanClient.Handshake(
            protocolVersion: protocolVersion,
            implementationRevision: revision,
            status: status,
            message: "status \(status)"
        )
    }
}
