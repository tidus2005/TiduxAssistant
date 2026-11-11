import CodexMobilityCore
import Foundation

/// Small persistence seam kept separate from the runtime store so tests and
/// previews never need to mutate the app's real preferences domain.
public protocol MobilityPolicyPersisting: AnyObject {
    func loadPolicy() -> MobilityPolicy?
    func savePolicy(_ policy: MobilityPolicy)
}

public final class UserDefaultsMobilityPolicyPersistence: MobilityPolicyPersisting {
    public static let suiteName = "com.tidux.codex-mobility.mac-policy"
    public static let policyKey = "mobilityPolicy.v1"

    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public convenience init() {
        guard let defaults = UserDefaults(suiteName: Self.suiteName) else {
            preconditionFailure("Unable to create the Codex Mobility policy preferences suite")
        }
        self.init(defaults: defaults)
    }

    public init(
        defaults: UserDefaults,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.defaults = defaults
        self.encoder = encoder
        self.decoder = decoder
    }

    public func loadPolicy() -> MobilityPolicy? {
        guard let data = defaults.data(forKey: Self.policyKey),
              let policy = try? decoder.decode(MobilityPolicy.self, from: data) else {
            return nil
        }
        return policy.normalized()
    }

    public func savePolicy(_ policy: MobilityPolicy) {
        guard let data = try? encoder.encode(policy.normalized()) else { return }
        defaults.set(data, forKey: Self.policyKey)
    }
}
