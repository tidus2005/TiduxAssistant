import AppKit
import Foundation

/// Observes a standalone press-and-release of the hardware Function/Globe key.
///
/// AppKit's global key monitor is available to an Accessibility-trusted app,
/// whereas a listen-only CGEvent tap may additionally fall under Input
/// Monitoring. A matching local monitor covers events while this App itself is
/// active. Local events are always returned unchanged.
@MainActor
public final class FunctionKeyMonitor {
    public enum MonitorError: Error, LocalizedError, Sendable {
        case globalMonitorUnavailable
        case localMonitorUnavailable

        public var errorDescription: String? {
            switch self {
            case .globalMonitorUnavailable:
                return "无法创建全局 Fn 监听器，请检查辅助功能权限。"
            case .localMonitorUnavailable:
                return "无法创建 App 内部 Fn 监听器。"
            }
        }
    }

    public typealias ToggleHandler = @MainActor @Sendable () async -> Void

    private let onStandaloneFunctionKey: ToggleHandler
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var functionKeyIsDown = false
    private var functionKeyWasChorded = false

    public init(onToggle: @escaping ToggleHandler) {
        onStandaloneFunctionKey = onToggle
    }

    public var isRunning: Bool {
        globalMonitor != nil && localMonitor != nil
    }

    /// Starts matching global and local monitors. Calling this repeatedly is
    /// safe.
    public func start() throws {
        guard !isRunning else {
            return
        }

        // Clear a partially-created monitor left by an earlier failed start.
        stop()

        let interestedEvents: NSEvent.EventTypeMask = [
            .flagsChanged,
            .keyDown,
            .systemDefined,
        ]

        guard let newGlobalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: interestedEvents,
            handler: { [weak self] event in
                self?.receive(event)
            }
        ) else {
            throw MonitorError.globalMonitorUnavailable
        }
        globalMonitor = newGlobalMonitor

        guard let newLocalMonitor = NSEvent.addLocalMonitorForEvents(
            matching: interestedEvents,
            handler: { [weak self] event in
                self?.receive(event)
                return event
            }
        ) else {
            NSEvent.removeMonitor(newGlobalMonitor)
            globalMonitor = nil
            throw MonitorError.localMonitorUnavailable
        }
        localMonitor = newLocalMonitor
    }

    /// Removes both monitors. Calling this repeatedly is safe.
    public func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        functionKeyIsDown = false
        functionKeyWasChorded = false
    }

    isolated deinit {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
    }

    private func receive(_ event: NSEvent) {
        guard process(event) else {
            return
        }

        let handler = onStandaloneFunctionKey
        Task { @MainActor in
            await handler()
        }
    }

    /// Returns true only on the release completing a plain Fn tap.
    private func process(_ event: NSEvent) -> Bool {
        switch event.type {
        case .flagsChanged:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let functionKeyIsCurrentlyDown = flags.contains(.function)

            if functionKeyIsCurrentlyDown, !functionKeyIsDown {
                functionKeyIsDown = true
                functionKeyWasChorded = Self.hasNonFunctionModifier(in: flags)
                return false
            }

            if functionKeyIsCurrentlyDown, functionKeyIsDown {
                if Self.hasNonFunctionModifier(in: flags) {
                    functionKeyWasChorded = true
                }
                return false
            }

            guard functionKeyIsDown else {
                return false
            }

            let shouldToggle = !functionKeyWasChorded
            functionKeyIsDown = false
            functionKeyWasChorded = false
            return shouldToggle

        case .keyDown, .systemDefined:
            if functionKeyIsDown {
                functionKeyWasChorded = true
            }
            return false

        default:
            return false
        }
    }

    private static func hasNonFunctionModifier(in flags: NSEvent.ModifierFlags) -> Bool {
        let chordModifiers: NSEvent.ModifierFlags = [
            .capsLock,
            .shift,
            .control,
            .option,
            .command,
            .help,
        ]
        return !flags.intersection(chordModifiers).isEmpty
    }
}
