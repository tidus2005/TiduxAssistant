import XCTest
import CoreBluetooth
import AccessorySetupKit
import CodexMobilityPhoneFeature

@MainActor
final class AccessoryDiscoveryTests: XCTestCase {
    func testMacDiscoveryWorksWithShortenedOrMissingLocalName() {
        let descriptor = MobilityAccessorySetupCoordinator.makeDiscoveryDescriptor()
        XCTAssertEqual(descriptor.bluetoothServiceUUID, CBUUID(nsuuid: MobilityAccessorySetupConfiguration.serviceUUID))
        XCTAssertNil(descriptor.bluetoothNameSubstring, "A shortened over-the-air name must not exclude a Mac that advertises our dedicated service")
    }
}
