import Foundation

public struct QuietModeStore {
    public static let key = "codexWatchPet.quietModeEnabled"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isEnabled: Bool {
        defaults.bool(forKey: Self.key)
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool) -> Bool {
        defaults.set(enabled, forKey: Self.key)
        defaults.synchronize()
        return enabled
    }

    @discardableResult
    public func toggle() -> Bool {
        setEnabled(!isEnabled)
    }
}
