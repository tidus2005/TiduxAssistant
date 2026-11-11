import CodexMobilityCore
import CoreFoundation
import Foundation
import IOKit

struct MacTemperatureReading: Equatable, Sendable {
    let celsius: Double
    let source: MobilityTemperatureSource
}

protocol MacTemperatureSampling: AnyObject, Sendable {
    func currentReading(now: Date) -> MacTemperatureReading?
}

/// Reads local Apple Silicon temperature sensors without starting a privileged
/// process. The highest valid die temperature is the most useful single value
/// for a remote safety dashboard. Battery temperature remains a public IOKit
/// fallback for Macs that do not expose die sensors through the HID service.
final class MacTemperatureSensor: MacTemperatureSampling, @unchecked Sendable {
    static let cacheInterval: TimeInterval = 10

    private let lock = NSLock()
    private var lastSampledAt: Date?
    private var cachedReading: MacTemperatureReading?

    func currentReading(now: Date = Date()) -> MacTemperatureReading? {
        lock.lock()
        if let lastSampledAt,
           now.timeIntervalSince(lastSampledAt) >= 0,
           now.timeIntervalSince(lastSampledAt) < Self.cacheInterval {
            let cachedReading = cachedReading
            lock.unlock()
            return cachedReading
        }
        lock.unlock()

        let reading = Self.readChipMaximum() ?? Self.readBatteryTemperature()

        lock.lock()
        lastSampledAt = now
        cachedReading = reading
        lock.unlock()
        return reading
    }

    static func maximumValidDieTemperature(
        from readings: [(name: String, celsius: Double)]
    ) -> Double? {
        readings.compactMap { reading -> Double? in
            guard reading.name.hasPrefix("PMU tdie"),
                  reading.celsius.isFinite,
                  (0 ... 125).contains(reading.celsius) else {
                return nil
            }
            return reading.celsius
        }.max()
    }

    private static func readChipMaximum() -> MacTemperatureReading? {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault),
              let services = IOHIDEventSystemClientCopyServices(client)
                as? [IOHIDServiceClientRef] else {
            return nil
        }

        var dieReadings: [(name: String, celsius: Double)] = []
        dieReadings.reserveCapacity(16)

        for service in services {
            let usagePage = IOHIDServiceClientCopyProperty(
                service,
                "PrimaryUsagePage" as CFString
            ) as? NSNumber
            let usage = IOHIDServiceClientCopyProperty(
                service,
                "PrimaryUsage" as CFString
            ) as? NSNumber
            guard usagePage?.intValue == 0xff00, usage?.intValue == 5 else {
                continue
            }

            guard let name = IOHIDServiceClientCopyProperty(
                service,
                "Product" as CFString
            ) as? String,
            name.hasPrefix("PMU tdie"),
            let event = IOHIDServiceClientCopyEvent(service, 15, 0, 0) else {
                continue
            }
            dieReadings.append(
                (name, IOHIDEventGetFloatValue(event, Int32(15 << 16)))
            )
        }

        guard let celsius = maximumValidDieTemperature(from: dieReadings) else {
            return nil
        }
        return MacTemperatureReading(celsius: celsius, source: .chipMaximum)
    }

    private static func readBatteryTemperature() -> MacTemperatureReading? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        guard let number = IORegistryEntryCreateCFProperty(
            service,
            "Temperature" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? NSNumber else {
            return nil
        }
        let rawValue = number.doubleValue
        let celsius = rawValue > 200 ? rawValue / 100 : rawValue
        guard celsius.isFinite, (0 ... 100).contains(celsius) else { return nil }
        return MacTemperatureReading(celsius: celsius, source: .battery)
    }
}

// These HID event symbols are exported by IOKit on Apple Silicon but are not
// declared by the public Swift overlay. Keep the bridge narrowly scoped to
// read-only temperature events and always retain the public battery fallback.
private typealias IOHIDEventSystemClientRef = CFTypeRef
private typealias IOHIDServiceClientRef = CFTypeRef
private typealias IOHIDEventRef = CFTypeRef

@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(
    _ allocator: CFAllocator?
) -> IOHIDEventSystemClientRef?

@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(
    _ client: IOHIDEventSystemClientRef
) -> CFArray?

@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(
    _ service: IOHIDServiceClientRef,
    _ property: CFString
) -> CFTypeRef?

@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(
    _ service: IOHIDServiceClientRef,
    _ type: Int64,
    _ options: Int32,
    _ timeout: Int64
) -> IOHIDEventRef?

@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(
    _ event: IOHIDEventRef,
    _ field: Int32
) -> Double
