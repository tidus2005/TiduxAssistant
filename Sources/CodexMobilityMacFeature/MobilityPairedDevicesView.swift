import SwiftUI

/// Mac-local pairing management. It intentionally receives token-free metadata only.
public struct MobilityPairedDevicesView: View {
    private let devices: [MobilityMacPairedDevice]
    private let errorMessage: String?
    private let onRevoke: (UUID) -> Void

    @State private var pendingRevocation: MobilityMacPairedDevice?

    public init(
        devices: [MobilityMacPairedDevice],
        errorMessage: String?,
        onRevoke: @escaping (UUID) -> Void
    ) {
        self.devices = devices
        self.errorMessage = errorMessage
        self.onRevoke = onRevoke
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if devices.isEmpty {
                Label("还没有已配对的 iPhone", systemImage: "iphone.gen3.slash")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(devices) { device in
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "iphone.gen3")
                            .font(.title2)
                            .foregroundStyle(.blue)
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.deviceName)
                                .font(.headline)
                                .lineLimit(1)
                            Text("配对于 \(device.pairedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 12)

                        Button("撤销访问", role: .destructive) {
                            pendingRevocation = device
                        }
                    }

                    if device.id != devices.last?.id {
                        Divider()
                    }
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .confirmationDialog(
            "撤销这台 iPhone 的访问？",
            isPresented: Binding(
                get: { pendingRevocation != nil },
                set: { isPresented in
                    if !isPresented { pendingRevocation = nil }
                }
            ),
            presenting: pendingRevocation
        ) { device in
            Button("撤销 \(device.deviceName)", role: .destructive) {
                onRevoke(device.deviceID)
                pendingRevocation = nil
            }
            Button("取消", role: .cancel) {
                pendingRevocation = nil
            }
        } message: { device in
            Text("撤销后，这台设备的令牌会立即失效，并停止接收 Mac 状态和事件。若要恢复，需要重新配对“\(device.deviceName)”。")
        }
    }
}
