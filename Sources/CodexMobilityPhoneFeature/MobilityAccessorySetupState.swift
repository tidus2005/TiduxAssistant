import CodexMobilityCore
import Foundation

public enum MobilityAccessorySetupConfiguration {
    public static let serviceUUID = MobilityBLEUUIDs.service
    public static let advertisedName = "Codex 随行"
}

/// Platform-neutral projection of the authorization information returned by
/// AccessorySetupKit. Keeping this model free of Apple-only framework types lets the
/// reducer and reconnect planning run in SwiftPM tests on macOS.
public enum MobilityAccessoryAuthorization: Equatable, Sendable {
    case unauthorized
    case awaitingAuthorization
    case authorized
}

public struct MobilityAccessorySnapshot: Equatable, Sendable {
    public var bluetoothIdentifier: UUID?
    public var displayName: String
    public var authorization: MobilityAccessoryAuthorization

    public init(
        bluetoothIdentifier: UUID?,
        displayName: String,
        authorization: MobilityAccessoryAuthorization
    ) {
        self.bluetoothIdentifier = bluetoothIdentifier
        self.displayName = displayName
        self.authorization = authorization
    }
}

public struct MobilitySystemAccessory: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var displayName: String

    public init(id: UUID, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public enum MobilityAccessorySessionPhase: Equatable, Sendable {
    case inactive
    case activating
    case active
    case invalidated
}

public struct MobilityAccessorySetupState: Equatable, Sendable {
    public var phase: MobilityAccessorySessionPhase
    public var authorizedAccessories: [MobilitySystemAccessory]
    public var isPickerRequestPending: Bool
    public var isPickerPresented: Bool
    public var lastErrorMessage: String?

    public init(
        phase: MobilityAccessorySessionPhase = .inactive,
        authorizedAccessories: [MobilitySystemAccessory] = [],
        isPickerRequestPending: Bool = false,
        isPickerPresented: Bool = false,
        lastErrorMessage: String? = nil
    ) {
        self.phase = phase
        self.authorizedAccessories = authorizedAccessories
        self.isPickerRequestPending = isPickerRequestPending
        self.isPickerPresented = isPickerPresented
        self.lastErrorMessage = lastErrorMessage
    }

    public var isSessionReady: Bool { phase == .active }

    public var isPickerBusy: Bool { isPickerRequestPending || isPickerPresented }
}

enum MobilityAccessorySetupInput: Equatable, Sendable {
    case activationStarted
    case activated([MobilityAccessorySnapshot])
    case pickerRequested
    case pickerPresented
    case pickerDismissed
    case accessoryAdded(MobilityAccessorySnapshot)
    case accessoryChanged(MobilityAccessorySnapshot)
    case accessoryRemoved(UUID?)
    case invalidated(String?)
    case failed(String)
    case clearError
}

struct MobilityAccessorySetupEffect: Equatable, Sendable {
    var accessoriesToRestore: [MobilitySystemAccessory] = []
    var preferredConnectionIdentifier: UUID?
    var removedIdentifiers: [UUID] = []

    static let none = MobilityAccessorySetupEffect()
}

enum MobilityAccessorySetupReducer {
    @discardableResult
    static func reduce(
        _ input: MobilityAccessorySetupInput,
        state: inout MobilityAccessorySetupState
    ) -> MobilityAccessorySetupEffect {
        let previousIdentifiers = Set(state.authorizedAccessories.map(\.id))

        switch input {
        case .activationStarted:
            state.phase = .activating
            state.lastErrorMessage = nil

        case .activated(let snapshots):
            state.phase = .active
            state.authorizedAccessories = normalize(snapshots)
            state.lastErrorMessage = nil

        case .pickerRequested:
            state.isPickerRequestPending = true
            state.lastErrorMessage = nil

        case .pickerPresented:
            state.isPickerRequestPending = false
            state.isPickerPresented = true

        case .pickerDismissed:
            state.isPickerRequestPending = false
            state.isPickerPresented = false

        case .accessoryAdded(let snapshot), .accessoryChanged(let snapshot):
            upsert(snapshot, in: &state.authorizedAccessories)
            state.lastErrorMessage = nil

        case .accessoryRemoved(let identifier):
            if let identifier {
                state.authorizedAccessories.removeAll { $0.id == identifier }
            }

        case .invalidated(let message):
            state.phase = .invalidated
            state.isPickerRequestPending = false
            state.isPickerPresented = false
            state.lastErrorMessage = message

        case .failed(let message):
            state.isPickerRequestPending = false
            state.lastErrorMessage = message

        case .clearError:
            state.lastErrorMessage = nil
        }

        let nextIdentifiers = Set(state.authorizedAccessories.map(\.id))
        let removed = previousIdentifiers.subtracting(nextIdentifiers).sorted(by: uuidSort)

        let preferredIdentifier: UUID?
        switch input {
        case .activated:
            preferredIdentifier = state.authorizedAccessories.first?.id
        case .accessoryAdded(let snapshot), .accessoryChanged(let snapshot):
            if snapshot.authorization == .authorized,
               let identifier = snapshot.bluetoothIdentifier,
               nextIdentifiers.contains(identifier) {
                preferredIdentifier = identifier
            } else {
                preferredIdentifier = nil
            }
        default:
            preferredIdentifier = nil
        }

        guard !state.authorizedAccessories.isEmpty || !removed.isEmpty else {
            return .none
        }
        return MobilityAccessorySetupEffect(
            accessoriesToRestore: state.authorizedAccessories,
            preferredConnectionIdentifier: preferredIdentifier,
            removedIdentifiers: removed
        )
    }

    private static func normalize(
        _ snapshots: [MobilityAccessorySnapshot]
    ) -> [MobilitySystemAccessory] {
        var accessoriesByIdentifier: [UUID: MobilitySystemAccessory] = [:]
        for snapshot in snapshots {
            guard
                snapshot.authorization == .authorized,
                let identifier = snapshot.bluetoothIdentifier
            else {
                continue
            }
            accessoriesByIdentifier[identifier] = MobilitySystemAccessory(
                id: identifier,
                displayName: normalizedName(snapshot.displayName)
            )
        }
        return sorted(Array(accessoriesByIdentifier.values))
    }

    private static func upsert(
        _ snapshot: MobilityAccessorySnapshot,
        in accessories: inout [MobilitySystemAccessory]
    ) {
        guard let identifier = snapshot.bluetoothIdentifier else { return }
        guard snapshot.authorization == .authorized else {
            accessories.removeAll { $0.id == identifier }
            return
        }

        let accessory = MobilitySystemAccessory(
            id: identifier,
            displayName: normalizedName(snapshot.displayName)
        )
        if let index = accessories.firstIndex(where: { $0.id == identifier }) {
            accessories[index] = accessory
        } else {
            accessories.append(accessory)
        }
        accessories = sorted(accessories)
    }

    private static func sorted(
        _ accessories: [MobilitySystemAccessory]
    ) -> [MobilitySystemAccessory] {
        accessories.sorted { lhs, rhs in
            let nameOrder = lhs.displayName.localizedStandardCompare(rhs.displayName)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return uuidSort(lhs.id, rhs.id)
        }
    }

    private static func normalizedName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Codex 随行 Mac" : trimmed
    }

    private static func uuidSort(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString < rhs.uuidString
    }
}
