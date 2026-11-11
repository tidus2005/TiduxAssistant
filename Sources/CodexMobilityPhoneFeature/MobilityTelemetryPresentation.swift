import CodexMobilityCore
import Foundation

/// Keeps numeric sensor readings distinct from macOS thermal pressure.
public enum MobilityTelemetryPresentation {
    public static func temperatureValue(_ status: MobilityDeviceStatus) -> String {
        guard let value = status.temperatureCelsius,
              value.isFinite, (0...125).contains(value) else { return "暂无读数" }
        return String(format: "%.1f°C", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    public static func temperatureSource(_ status: MobilityDeviceStatus) -> String {
        guard let value = status.temperatureCelsius,
              value.isFinite, (0...125).contains(value) else {
            return "未取得传感器温度"
        }
        switch status.temperatureSource {
        case .chipMaximum: return "芯片最高温"
        case .battery: return "电池温度"
        case nil: return "Mac 传感器"
        }
    }
}
