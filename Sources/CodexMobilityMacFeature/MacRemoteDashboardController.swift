import CodexMobilityCore
import Combine
import Darwin
import Foundation
import Security

@MainActor
public final class MacRemoteDashboardController: ObservableObject {
    public static let defaultPort: UInt16 = 8788
    public static let defaultPublicURL: String? = nil

    @Published public private(set) var servicePhase: MacRemoteDashboardServicePhase = .stopped
    @Published public private(set) var localURL: String?
    @Published public private(set) var lanURL: String?
    @Published public private(set) var publicURL: String?
    @Published public private(set) var localShareURL: String?
    @Published public private(set) var lanShareURL: String?
    @Published public private(set) var publicShareURL: String?
    @Published public private(set) var shareURL: String?
    @Published public private(set) var publicAccessPhase: MacRemoteDashboardPublicAccessPhase = .disabled
    @Published public private(set) var lastErrorMessage: String?

    private let store: MacMobilityStore
    private let powerPolicyStore: MacSystemPowerPolicyStore
    private let closedLidSessionController: MacClosedLidSessionController
    private let lidCloseLockController: MacLidCloseLockController
    private let hotspotStore: MacHotspotAutomationStore
    private let fileSyncStore: MacFileSyncStore
    private let fileService: MacRemoteDashboardFileService
    private let screenLockService: MacRemoteDashboardScreenLockService
    private let port: UInt16
    private let accessStore: MacRemoteDashboardAccessStore
    private let configuredPublicURL: String?
    private let startedAt: Date
    private var networkConnectedAt: Date?
    private var lastNetworkWasConnected: Bool
    private var temperatureHistoryStore: MacTemperatureHistoryStore
    private var screenLockSettings = MacRemoteDashboardScreenLockSnapshot.unavailable(
        "正在读取 macOS 自动锁屏配置"
    )
    private var filesVersion: UInt64 = 1
    private var activities: [MacRemoteDashboardActivity] = []
    private var server: MacRemoteDashboardServer?
    private var publicAccessTask: Task<Void, Never>?
    private var webSocketBroadcastTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    public init(
        store: MacMobilityStore,
        powerPolicyStore: MacSystemPowerPolicyStore,
        closedLidSessionController: MacClosedLidSessionController,
        lidCloseLockController: MacLidCloseLockController,
        hotspotStore: MacHotspotAutomationStore,
        fileSyncStore: MacFileSyncStore,
        port: UInt16 = MacRemoteDashboardController.defaultPort,
        accessStore: MacRemoteDashboardAccessStore = MacRemoteDashboardAccessStore(),
        publicURL: String? = MacRemoteDashboardController.defaultPublicURL
    ) {
        self.store = store
        self.powerPolicyStore = powerPolicyStore
        self.closedLidSessionController = closedLidSessionController
        self.lidCloseLockController = lidCloseLockController
        self.hotspotStore = hotspotStore
        self.fileSyncStore = fileSyncStore
        self.fileService = MacRemoteDashboardFileService(store: fileSyncStore)
        self.screenLockService = MacRemoteDashboardScreenLockService(
            lidCloseLockController: lidCloseLockController
        )
        self.port = port
        self.accessStore = accessStore
        self.configuredPublicURL = MacRemoteDashboardLinkBuilder.normalizedPublicURL(publicURL)
        self.startedAt = Date()
        self.lastNetworkWasConnected = store.status.network.isConnected
        self.networkConnectedAt = store.status.network.isConnected ? Date() : nil
        var temperatureHistoryStore = MacTemperatureHistoryStore(now: store.status.observedAt)
        if let celsius = store.status.temperatureCelsius {
            temperatureHistoryStore.record(celsius: celsius, at: store.status.observedAt)
        }
        self.temperatureHistoryStore = temperatureHistoryStore
        observeStateChanges()
    }

    public func start() {
        guard server == nil else { return }
        servicePhase = .starting
        lastErrorMessage = nil

        do {
            let token = try accessStore.loadOrCreateToken()
            let server = MacRemoteDashboardServer(
                port: port,
                token: token,
                snapshotProvider: { [weak self] in
                    await self?.makeSnapshotRefreshingScreenLock()
                        ?? Self.unavailableSnapshot()
                },
                actionHandler: { [weak self] request in
                    await self?.perform(request) ?? MacRemoteDashboardActionResponse(
                        ok: false,
                        message: "Mac 控制台已经停止。",
                        snapshot: Self.unavailableSnapshot()
                    )
                },
                screenLockHandler: { [weak self] request in
                    await self?.handleScreenLockRequest(request)
                        ?? .jsonError("Mac 控制台已经停止。", status: 503)
                },
                fileHandler: { [fileService] request in
                    await fileService.response(for: request)
                },
                stateHandler: { [weak self] state in
                    Task { @MainActor in
                        self?.handleServerState(state)
                    }
                }
            )
            try server.start()
            self.server = server

            localURL = "http://127.0.0.1:\(port)/"
            lanURL = nil
            publishAccessLinks(token: token)
            startPublicAccessMonitoring()
            recordActivity(
                title: "手机 Web 控制台已启动",
                detail: publicURL ?? lanURL ?? localURL,
                accent: "healthy"
            )
        } catch {
            server = nil
            servicePhase = .failed
            lastErrorMessage = error.localizedDescription
        }
    }

    public func stop() {
        publicAccessTask?.cancel()
        publicAccessTask = nil
        webSocketBroadcastTask?.cancel()
        webSocketBroadcastTask = nil
        server?.stop()
        server = nil
        servicePhase = .stopped
        publicAccessPhase = .disabled
        localURL = nil
        lanURL = nil
        publicURL = nil
        localShareURL = nil
        lanShareURL = nil
        publicShareURL = nil
        shareURL = nil
    }

    public func rotateAccessLink() {
        do {
            let token = try accessStore.rotateToken()
            stop()
            servicePhase = .starting
            let server = MacRemoteDashboardServer(
                port: port,
                token: token,
                snapshotProvider: { [weak self] in
                    await self?.makeSnapshotRefreshingScreenLock()
                        ?? Self.unavailableSnapshot()
                },
                actionHandler: { [weak self] request in
                    await self?.perform(request) ?? MacRemoteDashboardActionResponse(
                        ok: false,
                        message: "Mac 控制台已经停止。",
                        snapshot: Self.unavailableSnapshot()
                    )
                },
                screenLockHandler: { [weak self] request in
                    await self?.handleScreenLockRequest(request)
                        ?? .jsonError("Mac 控制台已经停止。", status: 503)
                },
                fileHandler: { [fileService] request in
                    await fileService.response(for: request)
                },
                stateHandler: { [weak self] state in
                    Task { @MainActor in self?.handleServerState(state) }
                }
            )
            try server.start()
            self.server = server
            localURL = "http://127.0.0.1:\(port)/"
            lanURL = nil
            publishAccessLinks(token: token)
            startPublicAccessMonitoring()
            recordActivity(title: "手机控制台访问链接已更新", accent: "warning")
        } catch {
            servicePhase = .failed
            lastErrorMessage = error.localizedDescription
        }
    }

    public func refreshNetworkAddress() {
        guard server != nil else { return }
        lanURL = nil
        guard let token = try? accessStore.loadOrCreateToken() else { return }
        publishAccessLinks(token: token)
    }

    private func publishAccessLinks(token: String) {
        publicURL = configuredPublicURL
        localShareURL = MacRemoteDashboardLinkBuilder.tokenized(
            baseURL: localURL,
            token: token
        )
        lanShareURL = MacRemoteDashboardLinkBuilder.tokenized(
            baseURL: lanURL,
            token: token
        )
        publicShareURL = publicURL
        shareURL = publicShareURL ?? lanShareURL ?? localShareURL
    }

    private func startPublicAccessMonitoring() {
        publicAccessTask?.cancel()
        guard let publicURL,
              let healthURL = MacRemoteDashboardLinkBuilder.gatewayHealthURL(
                publicAppURL: publicURL
              ) else {
            publicAccessPhase = .disabled
            return
        }
        publicAccessPhase = .checking
        publicAccessTask = Task { [weak self] in
            while !Task.isCancelled {
                let isOnline = await Self.probePublicHealth(healthURL)
                guard let self, !Task.isCancelled else { return }
                self.publicAccessPhase = isOnline ? .online : .offline
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    nonisolated private static func probePublicHealth(_ url: URL) async -> Bool {
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 10
        )
        request.httpMethod = "GET"
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200,
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
                return false
            }
            return payload["service"] == "codex-watch-pet-web"
                && payload["status"] == "ok"
        } catch {
            return false
        }
    }

    func makeSnapshot(now: Date = Date()) -> MacRemoteDashboardSnapshot {
        let status = store.status
        let powerState = powerPolicyStore.snapshot.state(for: .closedLidContinuity)
        let baselineSource: String
        switch powerState {
        case .disabled:
            baselineSource = "macOS 普通睡眠"
        case .externallyEnabled:
            baselineSource = "外部策略"
        case .appManaged:
            baselineSource = "App 管理"
        case .unsupported(let message), .unknown(let message):
            baselineSource = message
        }

        let baselineStatus: String
        if let baseline = closedLidSessionController.baselineClosedLidEnabled {
            baselineStatus = baseline
                ? "临时模式结束后仍保持开启"
                : "当前被随行会话临时覆盖为开启"
        } else {
            baselineStatus = closedLidSessionController.isBaselineToggleOn
                ? "合盖后继续运行"
                : "使用 macOS 普通睡眠行为"
        }

        let batteryDisplay: String
        if let level = status.battery.levelPercent {
            if status.battery.isCharging {
                batteryDisplay = "\(level)% · 充电中"
            } else if status.battery.isOnExternalPower {
                batteryDisplay = "\(level)% · 外接电源"
            } else {
                batteryDisplay = "\(level)%"
            }
        } else {
            batteryDisplay = "暂不可用"
        }

        let thermalDisplay: String
        let thermalDetail: String
        switch status.thermalState {
        case .nominal:
            thermalDisplay = "正常"
            thermalDetail = "macOS 系统热压力正常"
        case .fair:
            thermalDisplay = "轻度"
            thermalDetail = "系统正在进行轻度热管理"
        case .serious:
            thermalDisplay = "严重"
            thermalDetail = "持续 2 分钟会触发安全停止"
        case .critical:
            thermalDisplay = "临界"
            thermalDetail = "会立即触发安全停止"
        case .unknown:
            thermalDisplay = "未知"
            thermalDetail = "macOS 暂未返回系统热压力"
        }
        let temperatureSourceDisplay: String?
        switch status.temperatureSource {
        case .chipMaximum:
            temperatureSourceDisplay = "芯片最高温"
        case .battery:
            temperatureSourceDisplay = "电池温度"
        case nil:
            temperatureSourceDisplay = nil
        }

        let networkDisplay: String
        switch status.network.kind {
        case .wifi: networkDisplay = "Wi‑Fi"
        case .ethernet: networkDisplay = "以太网"
        case .cellular: networkDisplay = "蜂窝网络"
        case .offline: networkDisplay = "离线"
        case .other: networkDisplay = "其他网络"
        case .unknown: networkDisplay = status.network.isConnected ? "网络可用" : "未知"
        }
        let networkDuration = networkConnectedAt.map { max(now.timeIntervalSince($0), 0) }
        let networkQualifiers = [
            status.network.isExpensive ? "计费网络" : nil,
            status.network.isConstrained ? "受限网络" : nil
        ].compactMap { $0 }.joined(separator: " · ")
        let networkDetail = status.network.isConnected
            ? (networkQualifiers.isEmpty ? "当前网络路径可用" : networkQualifiers)
            : "等待网络或手机热点恢复"

        let codexDetail: String
        if status.codex.isRunning {
            codexDetail = status.codex.activeTaskCount > 0
                ? "\(status.codex.activeTaskCount) 个活跃任务"
                : "桌面端正在运行"
        } else {
            codexDetail = status.codex.detail ?? "未检测到桌面端进程"
        }

        let remoteReadiness = closedLidSessionController.remoteControlReadiness
        return MacRemoteDashboardSnapshot(
            schemaVersion: 4,
            deviceName: status.deviceName,
            observedAt: now,
            appStartedAt: startedAt,
            appUptimeSeconds: max(now.timeIntervalSince(startedAt), 0),
            battery: MacRemoteDashboardBatterySnapshot(
                levelPercent: status.battery.levelPercent,
                isCharging: status.battery.isCharging,
                isOnExternalPower: status.battery.isOnExternalPower,
                estimatedMinutesRemaining: status.battery.estimatedMinutesRemaining,
                displayName: batteryDisplay
            ),
            thermal: MacRemoteDashboardThermalSnapshot(
                state: status.thermalState.rawValue,
                displayName: thermalDisplay,
                detail: thermalDetail,
                temperatureCelsius: status.temperatureCelsius,
                temperatureSource: temperatureSourceDisplay,
                history: temperatureHistoryStore.snapshot(now: now),
                historyWindowSeconds: MacTemperatureHistoryStore.historyWindowSeconds,
                sampleIntervalSeconds: MacTemperatureHistoryStore.sampleIntervalSeconds
            ),
            network: MacRemoteDashboardNetworkSnapshot(
                kind: status.network.kind.rawValue,
                displayName: networkDisplay,
                isConnected: status.network.isConnected,
                interfaceName: status.network.interfaceName,
                connectedAt: networkConnectedAt,
                connectedDurationSeconds: networkDuration,
                isExpensive: status.network.isExpensive,
                isConstrained: status.network.isConstrained,
                detail: networkDetail
            ),
            codex: MacRemoteDashboardCodexSnapshot(
                isRunning: status.codex.isRunning,
                activeTaskCount: status.codex.activeTaskCount,
                lastActivityAt: status.codex.lastActivityAt,
                detail: codexDetail
            ),
            baselineClosedLid: MacRemoteDashboardToggleSnapshot(
                isOn: closedLidSessionController.isBaselineToggleOn,
                isEnabled: closedLidSessionController.isBaselineToggleEnabled,
                isBusy: powerPolicyStore.isBusy,
                status: baselineStatus,
                source: baselineSource
            ),
            temporarySession: MacRemoteDashboardTemporarySessionSnapshot(
                phase: closedLidSessionController.phase.rawValue,
                isOn: closedLidSessionController.isToggleOn,
                isEnabled: closedLidSessionController.isToggleEnabled,
                isBusy: closedLidSessionController.isBusy,
                status: closedLidSessionController.statusMessage,
                expiresAt: closedLidSessionController.expiresAt,
                overridesBaseline: closedLidSessionController.baselineClosedLidEnabled != nil,
                durationSeconds: closedLidSessionController.selectedDuration
            ),
            hotspot: MacRemoteDashboardHotspotSnapshot(
                targetName: closedLidSessionController.hotspotTargetName,
                phase: hotspotStore.snapshot.phase.rawValue,
                status: hotspotStore.statusText,
                isNetworkAvailable: hotspotStore.snapshot.isNetworkAvailable,
                reconnectAttempt: hotspotStore.snapshot.reconnectAttempt,
                nextActionAt: hotspotStore.snapshot.nextActionAt
            ),
            remoteControl: MacRemoteDashboardRemoteControlSnapshot(
                isConnected: remoteReadiness.isConnected,
                status: remoteReadiness.displayName
            ),
            screenLock: screenLockSettings,
            filesVersion: filesVersion,
            activities: Array(activities.prefix(12))
        )
    }

    func perform(
        _ request: MacRemoteDashboardActionRequest
    ) async -> MacRemoteDashboardActionResponse {
        store.refreshNow()
        await powerPolicyStore.refreshNow()

        switch request.action {
        case .setBaselineClosedLid:
            guard closedLidSessionController.isBaselineToggleEnabled else {
                return actionFailure("定时临时覆盖活动中，基础开关已锁定。")
            }
            await closedLidSessionController.setBaselineClosedLidEnabled(request.enabled)
            await powerPolicyStore.refreshNow()
            let succeeded = closedLidSessionController.isBaselineToggleOn == request.enabled
                && closedLidSessionController.lastErrorMessage == nil
            let message = succeeded
                ? (request.enabled ? "合盖运行已开启。" : "合盖运行已关闭。")
                : (closedLidSessionController.lastErrorMessage
                    ?? "系统状态没有切换到目标值，请在 Mac 上检查管理员验证。")
            recordActivity(
                title: request.enabled ? "合盖运行已开启" : "合盖运行已关闭",
                detail: succeeded ? "来自手机 Web 控制台" : message,
                accent: succeeded ? "control" : "warning"
            )
            return MacRemoteDashboardActionResponse(
                ok: succeeded,
                message: message,
                snapshot: makeSnapshot()
            )

        case .setTemporaryTwoHourSession:
            guard closedLidSessionController.isToggleEnabled else {
                return actionFailure("当前存在待恢复配置，暂时不能切换随行会话。")
            }
            if request.enabled, let duration = request.durationSeconds {
                guard duration.isFinite,
                      (MobilityPolicy.minimumAllowedDurationSeconds...MobilityPolicy.maximumAllowedDurationSeconds).contains(duration),
                      closedLidSessionController.setDuration(duration) else {
                    return actionFailure("请在停止会话后设置 15 分钟至 4 小时的随行时长。")
                }
            }
            await closedLidSessionController.setEnabled(request.enabled,
                mobileOffice: request.mobileOffice == true)
            await powerPolicyStore.refreshNow()
            store.refreshNow()
            let succeeded = request.enabled
                ? closedLidSessionController.phase == .active
                : closedLidSessionController.phase == .off
            let message = succeeded
                ? (request.enabled ? "随行会话已启动，时长 \(closedLidSessionController.durationLabel)。" : "随行会话已停止，启动前配置已恢复。")
                : (closedLidSessionController.lastErrorMessage
                    ?? closedLidSessionController.statusMessage)
            recordActivity(
                title: request.enabled ? "合盖连热点已开启" : "合盖连热点已停止",
                detail: succeeded ? "来自手机 Web 控制台" : message,
                accent: succeeded ? "control" : "warning"
            )
            return MacRemoteDashboardActionResponse(
                ok: succeeded,
                message: message,
                snapshot: makeSnapshot()
            )
        }
    }

    private func makeSnapshotRefreshingScreenLock() async -> MacRemoteDashboardSnapshot {
        screenLockSettings = await screenLockService.load()
        return makeSnapshot()
    }

    private func handleScreenLockRequest(
        _ request: MacRemoteDashboardHTTPRequest
    ) async -> MacRemoteDashboardHTTPResponse {
        switch request.method {
        case "GET":
            screenLockSettings = await screenLockService.load()
            return .jsonEncodable(screenLockSettings)

        case "POST":
            let update: MacRemoteDashboardScreenLockUpdateRequest
            do {
                update = try MacRemoteDashboardJSON.decoder.decode(
                    MacRemoteDashboardScreenLockUpdateRequest.self,
                    from: request.body
                )
            } catch {
                return .jsonError("自动锁屏设置格式无效。", status: 400)
            }
            let result = await screenLockService.apply(update)
            screenLockSettings = result.settings
            recordActivity(
                title: result.ok ? "自动锁屏设置已更新" : "自动锁屏设置失败",
                detail: result.message,
                accent: result.ok ? "control" : "warning"
            )
            scheduleWebSocketBroadcast()
            return .jsonEncodable(result, status: result.ok ? 200 : 409)

        default:
            return .jsonError("不支持该自动锁屏操作。", status: 405)
        }
    }

    private func actionFailure(_ message: String) -> MacRemoteDashboardActionResponse {
        MacRemoteDashboardActionResponse(ok: false, message: message, snapshot: makeSnapshot())
    }

    private func observeStateChanges() {
        store.$status
            .dropFirst()
            .sink { [weak self] status in
                self?.observeStatus(status)
                self?.scheduleWebSocketBroadcast()
            }
            .store(in: &cancellables)

        closedLidSessionController.$phase
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] phase in
                self?.recordActivity(
                    title: "随行会话：\(Self.sessionPhaseName(phase))",
                    detail: self?.closedLidSessionController.statusMessage,
                    accent: phase == .failed ? "warning" : "control"
                )
            }
            .store(in: &cancellables)

        lidCloseLockController.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await Task.yield()
                    guard let self else { return }
                    self.screenLockSettings = self.screenLockSettings.merging(
                        lidCloseLock: self.lidCloseLockController.snapshot()
                    )
                    self.scheduleWebSocketBroadcast()
                }
            }
            .store(in: &cancellables)

        closedLidSessionController.objectWillChange
            .sink { [weak self] _ in
                self?.scheduleWebSocketBroadcast()
            }
            .store(in: &cancellables)

        hotspotStore.objectWillChange
            .sink { [weak self] _ in
                self?.scheduleWebSocketBroadcast()
            }
            .store(in: &cancellables)

        fileSyncStore.objectWillChange
            .sink { [weak self] _ in
                guard let self else { return }
                self.filesVersion &+= 1
                self.scheduleWebSocketBroadcast()
            }
            .store(in: &cancellables)

        powerPolicyStore.$snapshot
            .dropFirst()
            .map(\.sleepDisabled)
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let enabled else { return }
                self?.recordActivity(
                    title: enabled ? "系统合盖策略已开启" : "系统合盖策略已关闭",
                    accent: "control"
                )
            }
            .store(in: &cancellables)
    }

    private func observeStatus(_ status: MobilityDeviceStatus) {
        if let celsius = status.temperatureCelsius {
            temperatureHistoryStore.record(celsius: celsius, at: status.observedAt)
        }
        let isConnected = status.network.isConnected
        if isConnected, !lastNetworkWasConnected {
            networkConnectedAt = Date()
            refreshNetworkAddress()
            recordActivity(
                title: "网络路径已恢复",
                detail: status.network.interfaceName,
                accent: "healthy"
            )
        } else if !isConnected, lastNetworkWasConnected {
            networkConnectedAt = nil
            recordActivity(title: "网络路径中断", accent: "warning")
        }
        lastNetworkWasConnected = isConnected
    }

    private func recordActivity(
        title: String,
        detail: String? = nil,
        accent: String = "neutral"
    ) {
        if activities.first?.title == title, activities.first?.detail == detail {
            return
        }
        activities.insert(
            MacRemoteDashboardActivity(title: title, detail: detail, accent: accent),
            at: 0
        )
        if activities.count > 40 {
            activities.removeLast(activities.count - 40)
        }
        scheduleWebSocketBroadcast()
    }

    private func scheduleWebSocketBroadcast() {
        guard server != nil else { return }
        webSocketBroadcastTask?.cancel()
        webSocketBroadcastTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, !Task.isCancelled else { return }
            self.server?.broadcastSnapshot()
        }
    }

    private func handleServerState(_ state: MacRemoteDashboardServer.State) {
        switch state {
        case .ready:
            servicePhase = .online
            lastErrorMessage = nil
        case .failed(let message):
            servicePhase = .failed
            lastErrorMessage = message
        case .cancelled:
            if server != nil {
                servicePhase = .stopped
            }
        }
    }

    private static func sessionPhaseName(_ phase: MacClosedLidSessionPhase) -> String {
        switch phase {
        case .off: "关闭"
        case .preparing: "准备中"
        case .active: "运行中"
        case .stopping: "恢复中"
        case .failed: "失败"
        }
    }

    nonisolated private static func unavailableSnapshot() -> MacRemoteDashboardSnapshot {
        let now = Date()
        return MacRemoteDashboardSnapshot(
            schemaVersion: 4,
            deviceName: "Mac",
            observedAt: now,
            appStartedAt: now,
            appUptimeSeconds: 0,
            battery: .init(
                levelPercent: nil,
                isCharging: false,
                isOnExternalPower: false,
                estimatedMinutesRemaining: nil,
                displayName: "不可用"
            ),
            thermal: .init(state: "unknown", displayName: "未知", detail: "Mac 控制台已停止"),
            network: .init(
                kind: "offline",
                displayName: "离线",
                isConnected: false,
                interfaceName: nil,
                connectedAt: nil,
                connectedDurationSeconds: nil,
                isExpensive: false,
                isConstrained: false,
                detail: "Mac 控制台已停止"
            ),
            codex: .init(isRunning: false, activeTaskCount: 0, lastActivityAt: nil, detail: "不可用"),
            baselineClosedLid: .init(isOn: false, isEnabled: false, isBusy: false, status: "不可用", source: nil),
            temporarySession: .init(
                phase: "off",
                isOn: false,
                isEnabled: false,
                isBusy: false,
                status: "不可用",
                expiresAt: nil,
                overridesBaseline: false
            ),
            hotspot: .init(
                targetName: nil,
                phase: "stopped",
                status: "不可用",
                isNetworkAvailable: false,
                reconnectAttempt: 0,
                nextActionAt: nil
            ),
            remoteControl: .init(isConnected: false, status: "不可用"),
            screenLock: .unavailable("Mac 控制台已停止"),
            filesVersion: 0,
            activities: []
        )
    }
}

public struct MacRemoteDashboardAccessStore: Sendable {
    public static let defaultService = "com.tidux.codex-watch-pet.web-dashboard"
    public static let defaultSharedTokenURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CodexWatchPet", isDirectory: true)
        .appendingPathComponent("myapps-internal-token", isDirectory: false)
    private static let account = "myapps-internal-token-v1"

    public let service: String
    public let sharedTokenURL: URL

    public init(
        service: String = Self.defaultService,
        sharedTokenURL: URL = Self.defaultSharedTokenURL
    ) {
        self.service = service
        self.sharedTokenURL = sharedTokenURL
    }

    public func loadOrCreateToken() throws -> String {
        if let token = try loadSharedToken() {
            try saveToKeychain(token)
            return token
        }
        if let token = try loadKeychainToken() {
            try saveSharedToken(token)
            return token
        }
        let token = try Self.makeRandomToken()
        try save(token)
        return token
    }

    public func rotateToken() throws -> String {
        let token = try Self.makeRandomToken()
        try save(token)
        return token
    }

    private func loadKeychainToken() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else {
            throw MacRemoteDashboardAccessError.keychain(status)
        }
        return token
    }

    private func save(_ token: String) throws {
        try saveToKeychain(token)
        try saveSharedToken(token)
    }

    private func saveToKeychain(_ token: String) throws {
        let data = Data(token.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw MacRemoteDashboardAccessError.keychain(updateStatus)
        }
        var item = baseQuery
        item[kSecValueData as String] = data
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw MacRemoteDashboardAccessError.keychain(addStatus)
        }
    }

    private func loadSharedToken() throws -> String? {
        guard FileManager.default.fileExists(atPath: sharedTokenURL.path) else {
            return nil
        }
        let token = try String(contentsOf: sharedTokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    private func saveSharedToken(_ token: String) throws {
        let directory = sharedTokenURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data((token + "\n").utf8).write(to: sharedTokenURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: sharedTokenURL.path
        )
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account
        ]
    }

    private static func makeRandomToken(byteCount: Int = 32) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, byteCount, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw MacRemoteDashboardAccessError.randomGenerationFailed(status)
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public enum MacRemoteDashboardAccessError: LocalizedError, Sendable {
    case randomGenerationFailed(OSStatus)
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .randomGenerationFailed(let status):
            "无法生成手机控制台安全令牌（\(status)）。"
        case .keychain(let status):
            "无法访问手机控制台钥匙串令牌（\(status)）。"
        }
    }
}

enum MacRemoteDashboardLinkBuilder {
    static func normalizedPublicURL(_ rawValue: String?) -> String? {
        guard let rawValue,
              var components = URLComponents(string: rawValue),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false else {
            return nil
        }
        components.query = nil
        components.fragment = nil
        if components.path.isEmpty {
            components.path = "/"
        } else if !components.path.hasSuffix("/") {
            components.path += "/"
        }
        return components.url?.absoluteString
    }

    static func tokenized(baseURL: String?, token: String) -> String? {
        guard let baseURL,
              var components = URLComponents(string: baseURL),
              components.scheme != nil,
              components.host != nil else {
            return nil
        }
        components.fragment = "token=\(token)"
        return components.string
    }

    static func gatewayHealthURL(publicAppURL: String) -> URL? {
        guard var components = URLComponents(string: publicAppURL),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false else {
            return nil
        }
        components.path = "/api/platform/health"
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

enum MacRemoteDashboardNetworkAddress {
    static func preferredLANIPv4Address() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }

        var candidates: [(priority: Int, address: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = cursor?.pointee {
            defer { cursor = interface.ifa_next }
            guard let addressPointer = interface.ifa_addr,
                  addressPointer.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: interface.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addressPointer,
                socklen_t(addressPointer.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let bytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let value = String(decoding: bytes, as: UTF8.self)
            guard !value.hasPrefix("169.254.") else { continue }
            let priority = switch name {
            case "en0": 0
            case "en1": 1
            default: 10
            }
            candidates.append((priority, value))
        }
        return candidates.sorted { lhs, rhs in
            lhs.priority == rhs.priority
                ? lhs.address < rhs.address
                : lhs.priority < rhs.priority
        }.first?.address
    }
}
