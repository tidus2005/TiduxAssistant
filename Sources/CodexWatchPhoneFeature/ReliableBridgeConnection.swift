import CodexWatchCore
import Foundation

public enum BridgeTransportRoute: Int, Sendable {
    case bluetooth, localNetwork, remoteHTTPS
    public var displayName: String {
        switch self { case .bluetooth: "蓝牙"; case .localNetwork: "局域网 Wi‑Fi"; case .remoteHTTPS: "远程 HTTPS" }
    }
}

public enum BridgeDeliveryError: Error, LocalizedError {
    case unavailable
    case rejected(String)
    case outcomeUnknown(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable: "尚未连接 Mac。请先在“设备”页添加 Mac；蓝牙优先，局域网和已配置的远程 HTTPS 自动备用。"
        case .rejected(let message): message
        case .outcomeUnknown(let id): "未取得操作回执，已尝试切换通道核实；请刷新核实任务（\(id)）。不会自动重复执行。"
        }
    }
}

@MainActor
public protocol BridgeTransporting: Sendable {
    var route: BridgeTransportRoute { get }
    var isAvailable: Bool { get }
    var serverIdentity: String? { get }
    var supportsCommandDeduplication: Bool { get }
    func fetchSnapshot() async throws -> BridgeState
    func send(command: BridgeCommand) async throws -> CommandResult
    func fetchReceipt(commandID: String) async throws -> CommandResult?
}

public extension BridgeTransporting {
    var serverIdentity: String? { nil }
    var supportsCommandDeduplication: Bool { false }
}

/// Ambiguous writes can only be retried unchanged on the same deduplicating server.
@MainActor
public final class ReliableBridgeConnection {
    private var transports: [any BridgeTransporting] = []
    private var retryAfter: [Int: Date] = [:]
    private var pinnedIdentity: String?
    private var generation = 0
    public private(set) var activeRoute: BridgeTransportRoute?
    private let now: () -> Date
    private let commandTimeout: Duration

    public init(now: @escaping () -> Date = Date.init, commandTimeout: Duration = .seconds(20)) {
        self.now = now; self.commandTimeout = commandTimeout
    }
    public func configure(_ transports: [any BridgeTransporting]) {
        self.transports = transports.sorted { $0.route.rawValue < $1.route.rawValue }
        retryAfter = [:]
        pinnedIdentity = nil
        generation += 1
    }

    public func fetchSnapshot() async throws -> BridgeState {
        let generation = generation
        var lastError: Error = BridgeDeliveryError.unavailable
        for (index, transport) in transports.enumerated() where transport.isAvailable {
            if let date = retryAfter[index], date > now() { continue }
            try Task.checkCancellation()
            do {
                let state = try await withThrowingTaskGroup(of: BridgeState.self) { group in
                    group.addTask { [transport] in try await transport.fetchSnapshot() }
                    group.addTask {
                        try await Task.sleep(for: .seconds(8))
                        throw URLError(.timedOut)
                    }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
                guard generation == self.generation else { throw CancellationError() }
                try acceptIdentity(state.bridgeIdentity)
                activeRoute = transport.route; retryAfter[index] = nil
                return state
            } catch is CancellationError { throw CancellationError() }
            catch { lastError = error; retryAfter[index] = now().addingTimeInterval(15) }
        }
        activeRoute = nil
        throw lastError
    }

    public func send(command: BridgeCommand) async throws -> CommandResult {
        try await withThrowingTaskGroup(of: CommandResult.self) { group in
            group.addTask { [self, command] in try await self.sendUsingTransports(command) }
            group.addTask { [commandTimeout] in
                try await Task.sleep(for: commandTimeout)
                throw BridgeDeliveryError.outcomeUnknown(command.id)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func sendUsingTransports(_ command: BridgeCommand) async throws -> CommandResult {
        let generation = generation
        var uncertain = false
        var retryIdentity: String?
        for (index, transport) in transports.enumerated() where transport.isAvailable {
            if let date = retryAfter[index], date > now() { continue }
            try Task.checkCancellation()
            guard generation == self.generation else { throw CancellationError() }
            if pinnedIdentity != nil, transport.serverIdentity == nil {
                do { _ = try await transport.fetchSnapshot() }
                catch is CancellationError { throw CancellationError() }
                catch { continue }
            }
            if let pinnedIdentity, transport.serverIdentity != pinnedIdentity { continue }
            if pinnedIdentity == nil { try acceptIdentity(transport.serverIdentity) }
            if uncertain {
                guard let retryIdentity, transport.serverIdentity == retryIdentity,
                      transport.supportsCommandDeduplication else { continue }
            }
            do {
                let result = try await transport.send(command: command)
                guard result.commandId == command.id else { throw BridgeDeliveryError.outcomeUnknown(command.id) }
                activeRoute = transport.route; retryAfter[index] = nil
                return result
            } catch BridgeDeliveryError.unavailable {
                retryAfter[index] = now().addingTimeInterval(15)
                continue // The adapter guarantees nothing was enqueued.
            } catch let error as BridgeDeliveryError {
                if case .rejected = error { throw error }
            } catch is CancellationError { throw CancellationError() }
            catch { /* A missing reply needs reconciliation before any safe retry. */ }

            uncertain = true
            if transport.supportsCommandDeduplication { retryIdentity = transport.serverIdentity }
            let queryOrder = Array(transports.enumerated()).filter { $0.offset != index } + [(index, transport)]
            for (_, query) in queryOrder where query.isAvailable {
                try Task.checkCancellation()
                guard generation == self.generation else { throw CancellationError() }
                if let expected = retryIdentity ?? pinnedIdentity {
                    if query.serverIdentity == nil { _ = try? await query.fetchSnapshot() }
                    guard query.serverIdentity == expected else { continue }
                }
                if let result = try? await query.fetchReceipt(commandID: command.id), result.commandId == command.id {
                    activeRoute = query.route
                    return result
                }
            }
            guard retryIdentity != nil else { throw BridgeDeliveryError.outcomeUnknown(command.id) }
        }
        if uncertain { throw BridgeDeliveryError.outcomeUnknown(command.id) }
        throw BridgeDeliveryError.unavailable
    }

    private func acceptIdentity(_ identity: String?) throws {
        if let pinnedIdentity, identity != pinnedIdentity {
            throw BridgeDeliveryError.rejected("备用链路连接的 Mac 身份不匹配，已停止切换。")
        }
        if pinnedIdentity == nil { pinnedIdentity = identity }
    }
}
