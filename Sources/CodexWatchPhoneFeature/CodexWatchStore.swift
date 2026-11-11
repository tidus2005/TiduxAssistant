import CodexWatchCore
import Foundation

@MainActor
public final class CodexWatchStore: ObservableObject {
    @Published public private(set) var state: BridgeState
    @Published public var selectedSnapshot: TaskSnapshot?
    @Published public private(set) var lastCommandResult: CommandResult?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var connectionStatus = "尚未连接"

    private var client: BridgeClient?
    private var remoteClient: BridgeClient?
    private var preferredTransports: [any BridgeTransporting] = []
    private let connection = ReliableBridgeConnection()
    @Published public private(set) var isRefreshing = false
    private let watchSync: WatchSyncService
    private let notificationCoordinator: NotificationCoordinator

    public init(
        initialState: BridgeState = BridgeState(snapshots: [], events: [], unreadHighUrgencyCount: 0, bridgeOnline: false, pairStatus: PairStatus(paired: false)),
        client: BridgeClient? = nil,
        watchSync: WatchSyncService = WatchSyncService(),
        notificationCoordinator: NotificationCoordinator = NotificationCoordinator()
    ) {
        self.state = initialState
        self.client = client
        self.watchSync = watchSync
        self.notificationCoordinator = notificationCoordinator
        self.selectedSnapshot = initialState.snapshots.first
        rebuildConnection()
        self.watchSync.onCommand = { [weak self] command in
            self?.send(command)
        }
        self.watchSync.onCommandWithResult = { [weak self] command in
            guard let self else {
                return CommandResult(commandId: command.id, accepted: false, message: "手机连接已关闭，请刷新任务。")
            }
            return await self.sendCommand(command)
        }
        self.watchSync.onRefreshRequest = { [weak self] in
            Task {
                await self?.refresh()
            }
        }
        self.notificationCoordinator.onCommand = { [weak self] command in
            self?.send(command)
        }
    }

    public func configure(client: BridgeClient?) {
        self.client = client
        rebuildConnection()
    }

    public func configure(preferredTransports: [any BridgeTransporting]) {
        self.preferredTransports = preferredTransports
        rebuildConnection()
    }

    public func configure(remoteClient: BridgeClient?) {
        self.remoteClient = remoteClient
        rebuildConnection()
    }

    private func rebuildConnection() {
        var transports = preferredTransports
        if let client { transports.append(client) }
        if let remoteClient { transports.append(remoteClient) }
        connection.configure(transports)
    }

    public func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        // Account handoff settings also sync when the Mac bridge is unavailable.
        try? await watchSync.sync(state: state)
        do {
            let nextState = try await connection.fetchSnapshot()
            state = nextState
            selectedSnapshot = selectedSnapshot.flatMap { selected in
                nextState.snapshots.first { $0.threadId == selected.threadId }
            } ?? nextState.snapshots.first
            try? await watchSync.sync(state: nextState)
            notificationCoordinator.scheduleNotifications(for: nextState)
            errorMessage = nil
            connectionStatus = connection.activeRoute?.displayName ?? "已连接"
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            connectionStatus = "等待重连"
            state.bridgeOnline = false
            try? await watchSync.sync(state: state)
        }
    }

    public func syncWatchSettings() async { try? await watchSync.sync(state: state) }

    public func send(_ command: BridgeCommand) {
        Task {
            await sendCommand(command)
        }
    }

    @discardableResult
    public func sendCommand(_ command: BridgeCommand) async -> CommandResult {
        do {
            let result = try await connection.send(command: command)
            lastCommandResult = result
            await refresh()
            return result
        } catch {
            errorMessage = error.localizedDescription
            let result = CommandResult(commandId: command.id, accepted: false, message: "未取得执行回执，请刷新任务后核实：\(error.localizedDescription)")
            lastCommandResult = result
            return result
        }
    }

    public func runAutoRefresh(every seconds: UInt64 = 10) async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
        }
    }

    public static var preview: CodexWatchStore {
        CodexWatchStore(
            initialState: BridgeState(
                snapshots: [.sampleInput, .sampleApproval, .sampleActive],
                events: [
                    BridgeEvent(
                        sequence: 1,
                        threadId: "thread-approval",
                        type: .approvalRequested,
                        title: "Approve command",
                        summary: "A Codex command is waiting for approval.",
                        urgency: .high,
                        petMood: .needsApproval,
                        actions: []
                    ),
                    BridgeEvent(
                        sequence: 2,
                        threadId: "thread-input",
                        type: .inputRequested,
                        title: "Missing input",
                        summary: "Choose whether to prioritize the Watch app, complication, or Mac bridge.",
                        urgency: .high,
                        petMood: .needsInput,
                        actions: []
                    )
                ],
                unreadHighUrgencyCount: 2,
                bridgeOnline: true,
                pairStatus: PairStatus(paired: true, deviceName: "Preview Watch", tokenPreview: "preview...")
            )
        )
    }
}
