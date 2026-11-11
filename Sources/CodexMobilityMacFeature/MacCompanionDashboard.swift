import AppKit
import CodexMobilityCore
import Foundation

extension MacMobilityAppModel {
    func companionSnapshot() async -> CompanionDashboardSnapshot {
        var result = CompanionDashboardSnapshot(deviceID: store.status.deviceID)
        let session = closedLidSessionController
        result.mobileOfficeOn = session.isToggleOn
        result.mobileOfficeBusy = session.isBusy
        result.durationMinutes = Int(session.selectedDuration / 60)
        result.expiresAt = session.expiresAt
        result.mobileOfficeStatus = session.statusMessage
        result.baselineOn = session.isBaselineToggleOn
        result.baselineCanChange = session.isBaselineToggleEnabled
        result.caffeineOn = caffeineController.isActive
        result.caffeineStatus = caffeineController.status
        result.hotspotName = hotspotAutomationStore.reconnectTargetName ?? ""
        result.hotspotStatus = hotspotAutomationStore.statusText
        result.voiceStatus = voiceInputStore.statusMessage
        result.voiceRecording = voiceInputStore.phase == .recording
        result.inboxPath = fileSyncStore.directoryURL?.path ?? "尚未设置接收文件夹"
        result.modules = moduleStore.descriptors().map {
            CompanionModuleState(id: $0.id.rawValue, title: $0.title,
                enabled: moduleStore.isEnabled($0),
                canChange: $0.id != .deviceStatus && !session.isToggleOn)
        }
        result.fileHost = MacRemoteDashboardNetworkAddress.preferredLANIPv4Address()
        result.filePort = await syncthingSyncServer.listeningPort()
        return result
    }

    func handleCompanionRequest(_ request: CollaborationRequest) async -> CollaborationResponse {
        do {
            guard let body = request.body, body.count <= 4096 else {
                throw CollaborationTransportError.invalidResponse
            }
            let action = try JSONDecoder().decode(CompanionDashboardAction.self, from: body)
            if action == .snapshot {
                return try await companionResponse(request, ok: true, message: "状态已更新")
            }
            guard !companionOperationRunning else {
                return try await companionResponse(request, ok: false, message: "Mac 正在处理上一项操作，请稍后刷新。")
            }
            companionOperationRunning = true
            defer { companionOperationRunning = false }
            let message: String
            switch action {
            case .snapshot: message = "状态已更新"
            case .mobileOffice(let enabled, let minutes):
                guard MacClosedLidSessionController.durationMinutesChoices.contains(minutes) else {
                    throw CollaborationTransportError.rejected("请选择有效时长，最长 24 小时，或无限（手动结束）。")
                }
                if enabled && !closedLidSessionController.isToggleOn {
                    guard closedLidSessionController.setDuration(Double(minutes * 60)) else {
                        throw CollaborationTransportError.rejected("请先停止当前会话再调整时长。")
                    }
                }
                await closedLidSessionController.setEnabled(enabled, mobileOffice: true)
                guard closedLidSessionController.isToggleOn == enabled,
                      closedLidSessionController.lastErrorMessage == nil else {
                    throw CollaborationTransportError.rejected(closedLidSessionController.lastErrorMessage ?? closedLidSessionController.statusMessage)
                }
                message = enabled ? "移动办公已开启" : "移动办公已停止"
            case .baselineClosedLid(let enabled):
                guard closedLidSessionController.isBaselineToggleEnabled else {
                    throw CollaborationTransportError.rejected("临时会话期间不能调整基础合盖开关。")
                }
                await closedLidSessionController.setBaselineClosedLidEnabled(enabled)
                guard closedLidSessionController.isBaselineToggleOn == enabled else {
                    throw CollaborationTransportError.rejected(closedLidSessionController.lastErrorMessage ?? "请在 Mac 完成系统授权。")
                }
                message = "合盖运行设置已更新"
            case .caffeine(let enabled, let minutes):
                if let minutes, !MacCaffeineController.durationChoices.contains(minutes) {
                    throw CollaborationTransportError.rejected("不支持该咖啡因时长。")
                }
                if enabled && !caffeineController.isActive {
                    caffeineController.setMode(minutes == nil ? .indefinite : .timed)
                    if let minutes { caffeineController.setDurationMinutes(minutes) }
                }
                caffeineController.setEnabled(enabled)
                guard caffeineController.isActive == enabled else {
                    throw CollaborationTransportError.rejected(caffeineController.errorMessage ?? "咖啡因未生效")
                }
                message = caffeineController.status
            case .connectHotspot:
                let connected = try await hotspotAutomationStore.connectPreferredNetworkNow(
                    forcePreferredNetworkJoin: true, networkStatusProvider: { self.store.status.network })
                guard connected else {
                    throw CollaborationTransportError.rejected(hotspotAutomationStore.lastConnectionErrorMessage ?? "请在手机开启个人热点。")
                }
                message = "Mac 热点连接已就绪，正在建立加密文件通道"
            case .setHotspotName(let name):
                let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name.utf8.count <= 32, !name.contains("\n") else {
                    throw CollaborationTransportError.rejected("热点名称须为 1–32 字节。")
                }
                guard !closedLidSessionController.isToggleOn else {
                    throw CollaborationTransportError.rejected("请先停止移动办公再修改热点名称。")
                }
                hotspotAutomationStore.updatePreferredSSIDs(text: name)
                message = "已保存热点名称；密码仍由 macOS 钥匙串管理"
            case .setModule(let id, let enabled):
                guard let moduleID = MobilityModuleID(rawValue: id), moduleID != .deviceStatus,
                      let descriptor = moduleStore.catalog.descriptor(for: moduleID),
                      !closedLidSessionController.isToggleOn else {
                    throw CollaborationTransportError.rejected("此模块在当前会话中不可调整。")
                }
                if enabled && descriptor.tier == .experimental { moduleStore.setExperimentalModulesEnabled(true) }
                moduleStore.setModule(descriptor, selected: enabled)
                guard moduleStore.isEnabled(moduleID) == enabled else {
                    throw CollaborationTransportError.rejected(moduleStore.persistenceErrorMessage ?? "模块设置未生效")
                }
                message = "模块设置已更新"
            case .toggleMacDictation:
                guard moduleStore.isEnabled(.voiceInput) else {
                    throw CollaborationTransportError.rejected("Mac 语音输入模块已关闭。")
                }
                await voiceInputStore.toggleDictation()
                message = voiceInputStore.statusMessage
            case .prepareFileReceiver, .revealInbox:
                guard moduleStore.isEnabled(.fileSync) else {
                    throw CollaborationTransportError.rejected("请先在 Mac 控制台启用双向文件同步模块。")
                }
                if fileSyncStore.directoryURL == nil {
                    let inbox = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/随行收件箱", isDirectory: true)
                    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
                    try await fileSyncStore.selectDirectory(inbox)
                }
                fileSyncStore.setEnabled(true)
                if action == .revealInbox { fileSyncStore.revealDirectory() }
                message = action == .revealInbox ? "已在 Mac 打开接收文件夹" : "Mac 接收文件夹已就绪"
            case .showDashboard:
                onShowDashboard?()
                NSApp.activate(ignoringOtherApps: true)
                message = "已在 Mac 打开仪表盘"
            }
            store.refreshNow()
            return try await companionResponse(request, ok: true, message: message)
        } catch {
            return (try? await companionResponse(request, ok: false, message: error.localizedDescription))
                ?? CollaborationResponse(requestID: request.id, status: 500)
        }
    }

    private func companionResponse(_ request: CollaborationRequest, ok: Bool, message: String) async throws -> CollaborationResponse {
        let reply = CompanionDashboardReply(ok: ok, message: message, snapshot: await companionSnapshot())
        return CollaborationResponse(requestID: request.id, status: 200, body: try JSONEncoder().encode(reply))
    }
}
