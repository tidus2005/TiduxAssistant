@testable import CodexMobilityMacFeature
import Foundation
import Testing

@Suite("Mac temperature sensor")
struct MacTemperatureSensorTests {
    @Test("The dashboard uses the hottest valid die sensor")
    func hottestValidDieTemperature() {
        let value = MacTemperatureSensor.maximumValidDieTemperature(
            from: [
                ("PMU tdie1", 72.4),
                ("PMU tdie2", 81.25),
                ("gas gauge battery", 36.7),
                ("PMU tdev1", -9_199),
                ("PMU tdie3", .nan),
                ("PMU tdie4", 151)
            ]
        )
        #expect(value == 81.25)
    }

    @Test("Invalid or unrelated sensors do not become a chip temperature")
    func rejectsInvalidSensors() {
        #expect(
            MacTemperatureSensor.maximumValidDieTemperature(
                from: [
                    ("gas gauge battery", 37),
                    ("NAND CH0 temp", 41),
                    ("PMU tdie1", -1)
                ]
            ) == nil
        )
    }
}
