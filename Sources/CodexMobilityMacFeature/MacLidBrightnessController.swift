import CoreGraphics
import Darwin
import Foundation
import IOKit
import IOKit.graphics

@MainActor
protocol MacLidBrightnessControlling: AnyObject {
    func prepare() throws
    func dim() throws
    func restore() throws
}

enum MacLidBrightnessError: LocalizedError {
    case unavailable, readFailed, writeFailed
    var errorDescription: String? {
        switch self {
        case .unavailable: "没有找到可控制亮度的内置屏幕；请开盖后重试。"
        case .readFailed: "无法保存内屏原亮度，未执行调暗。"
        case .writeFailed: "无法确认内屏亮度已调整；未请求熄屏或锁屏。"
        }
    }
}

/// Saves one built-in panel's brightness, dims it without display sleep, and
/// restores it on opening the lid or ending the session. External panels are
/// never changed. DisplayServices is an optional runtime fallback for Apple
/// Silicon panels whose brightness isn't exposed by IODisplayConnect.
@MainActor
final class SystemMacLidBrightnessController: MacLidBrightnessControlling {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL)
    private var displayID: CGDirectDisplayID?
    private var baseline: Float?
    private var isDimmed = false

    func prepare() throws {
        guard baseline == nil else { return }
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count) == .success,
              let display = displays.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
            throw MacLidBrightnessError.unavailable
        }
        guard let value = read(display), value.isFinite, (0...1).contains(value) else {
            throw MacLidBrightnessError.readFailed
        }
        displayID = display
        baseline = value
    }

    func dim() throws {
        guard !isDimmed else { return }
        guard let displayID, baseline != nil else { throw MacLidBrightnessError.readFailed }
        guard write(displayID, value: 0) else { throw MacLidBrightnessError.writeFailed }
        // Mark ownership even if readback fails, so cleanup still restores it.
        isDimmed = true
        guard let actual = read(displayID), actual <= 0.02 else { throw MacLidBrightnessError.writeFailed }
    }

    func restore() throws {
        if isDimmed, let displayID, let baseline {
            guard write(displayID, value: baseline),
                  let actual = read(displayID), abs(actual - baseline) < 0.03 else {
                throw MacLidBrightnessError.writeFailed
            }
        }
        isDimmed = false
        baseline = nil
        displayID = nil
    }

    private func read(_ display: CGDirectDisplayID) -> Float? {
        var value: Float = 0
        if let handle, let symbol = dlsym(handle, "DisplayServicesGetBrightness"),
           unsafeBitCast(symbol, to: GetBrightness.self)(display, &value) == 0 {
            return value
        }
        return withBuiltInService { service in
            IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &value) == kIOReturnSuccess
                ? value : nil
        }
    }

    private func write(_ display: CGDirectDisplayID, value: Float) -> Bool {
        if let handle, let symbol = dlsym(handle, "DisplayServicesSetBrightness"),
           unsafeBitCast(symbol, to: SetBrightness.self)(display, value) == 0 {
            return true
        }
        return withBuiltInService { service in
            IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, value) == kIOReturnSuccess
        } ?? false
    }

    private func withBuiltInService<T>(_ body: (io_service_t) -> T?) -> T? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"), &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let info = IODisplayCreateInfoDictionary(service, 0)?.takeRetainedValue() as? [String: Any],
                  (info["DisplayBuiltIn"] as? Bool) == true else { continue }
            if let result = body(service) { return result }
        }
        return nil
    }
}
