import SwiftUI

#if os(iOS) && !targetEnvironment(macCatalyst) && canImport(AccessorySetupKit)
/// App-facing container for the iPhone companion experience.
///
/// The production app injects a process-owned runtime so AccessorySetupKit and Core Bluetooth
/// restoration share one lifetime. The no-argument initializer remains useful for previews.
@MainActor
public struct MobilityPhoneContainerView: View {
    @ObservedObject private var runtime: MobilityPhoneAppRuntime

    public init() {
        self.runtime = MobilityPhoneAppRuntime()
    }

    public init(runtime: MobilityPhoneAppRuntime) {
        self.runtime = runtime
    }

    public init(store: MobilityPhoneStore) {
        self.runtime = MobilityPhoneAppRuntime(store: store)
    }

    public var body: some View {
        MobilityPhoneRootView(
            store: runtime.store,
            accessorySetupCoordinator: runtime.accessorySetupCoordinator
        )
        .task {
            runtime.start()
        }
    }
}
#else
/// Cross-platform container retained for SwiftPM compilation and previews on macOS.
@MainActor
public struct MobilityPhoneContainerView: View {
    @StateObject private var store: MobilityPhoneStore

    public init() {
        _store = StateObject(wrappedValue: MobilityPhoneStore())
    }

    public init(store: MobilityPhoneStore) {
        _store = StateObject(wrappedValue: store)
    }

    public var body: some View {
        MobilityPhoneRootView(store: store)
            .task {
                store.start()
            }
    }
}
#endif
