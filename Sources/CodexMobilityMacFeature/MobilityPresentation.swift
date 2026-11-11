import CodexMobilityCore
import Foundation

public extension MobilityModePhase {
    var mobilityDisplayName: String {
        switch self {
        case .off: "已关闭"
        case .preflighting: "检查中"
        case .armed: "已就绪"
        case .active: "运行中"
        case .degraded: "降级运行"
        case .stopping: "正在停止"
        case .blocked: "已阻止"
        case .faulted: "发生故障"
        case .recovering: "正在恢复"
        }
    }

    var mobilitySymbolName: String {
        switch self {
        case .active: "bolt.shield.fill"
        case .armed, .preflighting, .recovering: "arrow.triangle.2.circlepath"
        case .degraded: "exclamationmark.shield.fill"
        case .blocked, .faulted: "xmark.shield.fill"
        case .stopping: "hourglass"
        case .off: "bolt.shield"
        }
    }
}

public extension MobilityThermalState {
    var mobilityDisplayName: String {
        switch self {
        case .nominal: "正常"
        case .fair: "升高"
        case .serious: "严重"
        case .critical: "临界"
        case .unknown: "未知"
        }
    }
}

public extension MobilityNetworkStatus {
    var mobilityDisplayName: String {
        guard isConnected else { return "未连接" }
        let base: String = switch kind {
        case .wifi: "Wi‑Fi"
        case .ethernet: "以太网"
        case .cellular: "蜂窝转接"
        case .other: "其他网络"
        case .offline: "未连接"
        case .unknown: "网络"
        }
        if isExpensive {
            return "\(base) · 计费/疑似热点"
        }
        if isConstrained {
            return "\(base) · 受限"
        }
        return base
    }
}

public extension MobilityBatteryStatus {
    var mobilityDisplayName: String {
        let level = levelPercent.map { "\($0)%" } ?? "未知"
        if isCharging { return "\(level) · 充电中" }
        if isOnExternalPower { return "\(level) · 外接电源" }
        return level
    }
}
