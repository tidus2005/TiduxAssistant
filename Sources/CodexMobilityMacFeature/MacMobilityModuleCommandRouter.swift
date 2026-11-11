import CodexMobilityCore
import Foundation

/// Applies the same module gates to commands arriving from a paired iPhone as
/// the Mac UI applies locally. This prevents a disabled module from being
/// reactivated remotely through an older phone build.
@MainActor
final class MacMobilityModuleCommandRouter: MobilityMacCommandHandling {
    private let moduleStore: MobilityModuleConfigurationStore
    private let downstream: any MobilityMacCommandHandling

    init(
        moduleStore: MobilityModuleConfigurationStore,
        downstream: any MobilityMacCommandHandling
    ) {
        self.moduleStore = moduleStore
        self.downstream = downstream
    }

    var allowsStatusPublication: Bool {
        moduleStore.isEnabled(.deviceStatus)
    }

    var allowsFileSync: Bool {
        moduleStore.isEnabled(.fileSync)
    }

    func allowsStatusPublication(in configuration: MobilityModuleConfiguration) -> Bool {
        isEnabled(.deviceStatus, in: configuration)
    }

    func allowsFileSync(in configuration: MobilityModuleConfiguration) -> Bool {
        isEnabled(.fileSync, in: configuration)
    }

    /// File-sync commands use a dedicated BLE response channel, so they do not
    /// pass through `handleMobilityAction`. Keep the module gate at this shared
    /// boundary to ensure the visible module switch also controls that path.
    func handleFileSyncMessage(
        _ message: SyncWireMessage,
        from phoneDeviceID: UUID,
        downstream: @MainActor (SyncWireMessage, UUID) async -> [SyncWireMessage]
    ) async -> [SyncWireMessage] {
        guard allowsFileSync else {
            return [
                .failure(
                    SyncFailure(
                        transferID: message.transferID,
                        code: .unavailable,
                        message: moduleDisabledMessage(for: .fileSync),
                        retryable: false
                    )
                )
            ]
        }
        return await downstream(message, phoneDeviceID)
    }

    func handleMobilityAction(_ action: Action) async throws -> MobilityMacCommandOutcome {
        let requiredModule: MobilityModuleID
        switch action {
        case .requestStatus:
            requiredModule = .deviceStatus
        case .setMode(_, profile: .closedLidLabs):
            requiredModule = .closedLidLabs
        case .setMode, .updatePolicy:
            requiredModule = .travelRuntime
        case .collaboration:
            return MobilityMacCommandOutcome(accepted: false, message: "AI 协作消息应由已鉴权的通信服务处理。")
        case .fileSync:
            requiredModule = .fileSync
        }

        guard moduleStore.isEnabled(requiredModule) else {
            return MobilityMacCommandOutcome(
                accepted: false,
                message: moduleDisabledMessage(for: requiredModule)
            )
        }
        return try await downstream.handleMobilityAction(action)
    }

    private func moduleDisabledMessage(for moduleID: MobilityModuleID) -> String {
        let title = moduleStore.catalog.descriptor(for: moduleID)?.title
            ?? moduleID.rawValue
        return "Mac 设置中的“\(title)”模块已关闭。"
    }

    private func isEnabled(
        _ moduleID: MobilityModuleID,
        in configuration: MobilityModuleConfiguration
    ) -> Bool {
        guard let descriptor = moduleStore.catalog.descriptor(for: moduleID) else {
            return false
        }
        return configuration.isEnabled(descriptor, on: moduleStore.platform)
    }
}
