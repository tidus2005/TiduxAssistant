import CodexMobilityCore
import Foundation

public enum MobilityPendingEffect: Equatable, Sendable {
    case setMode(enabled: Bool, profile: MobilityModeProfile)
    case updatePolicy(MobilityPolicy)
    case refreshOnly
}

public struct MobilityPendingCommand: Equatable, Sendable {
    public let id: UUID
    public let effect: MobilityPendingEffect
    public let sentAt: Date

    public init(id: UUID, effect: MobilityPendingEffect, sentAt: Date) {
        self.id = id
        self.effect = effect
        self.sentAt = sentAt
    }
}

public struct MobilityPhoneState: Equatable, Sendable {
    public var bluetoothAvailability: MobilityBluetoothAvailability
    public var connectionPhase: MobilityBLEConnectionPhase
    public var computers: [MobilityDiscoveredComputer]
    public var lastKnownStatus: MobilityDeviceStatus?
    public var lastStatusAt: Date?
    public var staleSince: Date?
    public var pendingCommands: [UUID: MobilityPendingCommand]
    public var lastErrorMessage: String?

    public init(
        bluetoothAvailability: MobilityBluetoothAvailability = .unknown,
        connectionPhase: MobilityBLEConnectionPhase = .idle,
        computers: [MobilityDiscoveredComputer] = [],
        lastKnownStatus: MobilityDeviceStatus? = nil,
        lastStatusAt: Date? = nil,
        staleSince: Date? = nil,
        pendingCommands: [UUID: MobilityPendingCommand] = [:],
        lastErrorMessage: String? = nil
    ) {
        self.bluetoothAvailability = bluetoothAvailability
        self.connectionPhase = connectionPhase
        self.computers = computers
        self.lastKnownStatus = lastKnownStatus
        self.lastStatusAt = lastStatusAt
        self.staleSince = staleSince
        self.pendingCommands = pendingCommands
        self.lastErrorMessage = lastErrorMessage
    }

    public var isStale: Bool {
        staleSince != nil
    }

    public var hasPendingModeCommand: Bool {
        pendingCommands.values.contains { command in
            if case .setMode = command.effect { true } else { false }
        }
    }

    public var hasPendingPolicyCommand: Bool {
        pendingCommands.values.contains { command in
            if case .updatePolicy = command.effect { true } else { false }
        }
    }
}

public enum MobilityPhoneStateReducer {
    public static func shouldRecoverConnectedLink(readyAt: Date?, lastStatusAt: Date?, now: Date) -> Bool {
        guard let readyAt else { return false }
        // Returning after hours away must get a full grace period to refresh the Mac.
        return now.timeIntervalSince(max(readyAt, lastStatusAt ?? readyAt)) > 90
    }

    public static func register(
        commandID: UUID,
        effect: MobilityPendingEffect,
        sentAt: Date,
        state: inout MobilityPhoneState
    ) {
        state.pendingCommands[commandID] = MobilityPendingCommand(id: commandID, effect: effect, sentAt: sentAt)
        state.lastErrorMessage = nil
        // Deliberately do not update lastKnownStatus here. The Mac ACK or a fresh status
        // notification is the source of truth for mode and policy changes.
    }

    public static func receive(status: MobilityDeviceStatus, at date: Date, state: inout MobilityPhoneState) {
        // Cached, duplicated or late notifications must not renew the live-status lease.
        if let previous = state.lastKnownStatus, previous.deviceID == status.deviceID,
           status.observedAt <= previous.observedAt { return }
        state.lastKnownStatus = status
        state.lastStatusAt = date
        state.staleSince = nil
        state.lastErrorMessage = nil
        state.pendingCommands = state.pendingCommands.filter { _, command in
            !statusSatisfies(effect: command.effect, status: status)
        }
    }

    public static func acknowledge(
        commandID: UUID,
        accepted: Bool,
        message: String?,
        state: inout MobilityPhoneState
    ) {
        guard let pending = state.pendingCommands.removeValue(forKey: commandID) else {
            return
        }
        guard accepted else {
            state.lastErrorMessage = message ?? "Mac 拒绝了这次操作。"
            return
        }
        guard var status = state.lastKnownStatus else { return }

        switch pending.effect {
        case .setMode(let enabled, let profile):
            status.mode.phase = enabled ? .active : .off
            status.mode.profile = profile
            if !enabled {
                status.mode.startedAt = nil
                status.mode.expiresAt = nil
            }
            state.lastKnownStatus = status
        case .updatePolicy(let policy):
            status.mode.policy = policy.normalized()
            state.lastKnownStatus = status
        case .refreshOnly:
            break
        }
        state.lastErrorMessage = nil
    }

    public static func disconnect(at date: Date, state: inout MobilityPhoneState) {
        if state.lastKnownStatus != nil, state.staleSince == nil {
            state.staleSince = date
        }
    }

    public static func expireStatus(at date: Date, timeout: TimeInterval = 90, state: inout MobilityPhoneState) {
        guard state.lastKnownStatus != nil, let receivedAt = state.lastStatusAt,
              state.staleSince == nil, date.timeIntervalSince(receivedAt) >= timeout else { return }
        state.staleSince = receivedAt.addingTimeInterval(timeout)
    }

    public static func fail(message: String, state: inout MobilityPhoneState) {
        state.lastErrorMessage = message
    }

    private static func statusSatisfies(effect: MobilityPendingEffect, status: MobilityDeviceStatus) -> Bool {
        switch effect {
        case .setMode(let enabled, let profile):
            status.mode.isEnabled == enabled && (!enabled || status.mode.profile == profile)
        case .updatePolicy(let policy):
            status.mode.policy == policy.normalized()
        case .refreshOnly:
            true
        }
    }
}
