import AVFoundation
import SwiftUI

/// 一个可选的麦克风输入设备。
struct AudioDevice: Identifiable, Hashable {
    let id: String      // uniqueID
    let name: String

    var captureDevice: AVCaptureDevice? {
        AVCaptureDevice(uniqueID: id)
    }
}

@MainActor
final class AudioDeviceManager: ObservableObject {
    @Published private(set) var devices: [AudioDevice] = []
    @Published var selectedDeviceID: String?

    /// 枚举系统当前可用的音频输入设备（内置 / 外置麦克风）。
    func refresh() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        devices = discovery.devices
            .filter { $0.isConnected && !$0.isSuspended }
            .map { AudioDevice(id: $0.uniqueID, name: $0.localizedName) }

        // 保持当前选择：优先保留已有选择，否则回退到系统默认输入设备。
        if let selectedDeviceID, devices.contains(where: { $0.id == selectedDeviceID }) {
            return
        }
        if let defaultDevice = AVCaptureDevice.default(for: .audio) {
            selectedDeviceID = defaultDevice.uniqueID
        } else {
            selectedDeviceID = devices.first?.id
        }
    }
}
