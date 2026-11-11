import Foundation

/// Tracks which paired credential authorized each live Core Bluetooth central.
///
/// The registry stores device identifiers only. Tokens remain in Keychain and are
/// never copied into connection state or presentation models.
public struct MobilityCentralAuthorizationRegistry: Equatable, Sendable {
    private var deviceByCentralID: [UUID: UUID] = [:]

    public init() {}

    public mutating func authorize(centralID: UUID, deviceID: UUID) {
        deviceByCentralID[centralID] = deviceID
    }

    public mutating func remove(centralID: UUID) {
        deviceByCentralID[centralID] = nil
    }

    @discardableResult
    public mutating func revoke(deviceID: UUID) -> Set<UUID> {
        let revokedCentralIDs = Set(
            deviceByCentralID.compactMap { centralID, authorizedDeviceID in
                authorizedDeviceID == deviceID ? centralID : nil
            }
        )
        for centralID in revokedCentralIDs {
            deviceByCentralID[centralID] = nil
        }
        return revokedCentralIDs
    }

    public func isAuthorized(centralID: UUID) -> Bool {
        deviceByCentralID[centralID] != nil
    }

    public func deviceID(for centralID: UUID) -> UUID? {
        deviceByCentralID[centralID]
    }

    public func authorizedCentralIDs<S: Sequence>(among centralIDs: S) -> [UUID]
    where S.Element == UUID {
        centralIDs.filter { deviceByCentralID[$0] != nil }
    }
}
