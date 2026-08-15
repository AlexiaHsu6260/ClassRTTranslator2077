import AVFoundation
import Speech
import SwiftUI

/// 应用所需的两项系统权限状态。
enum PermissionStatus {
    case notDetermined
    case denied
    case restricted
    case granted
}

@MainActor
final class PermissionManager: ObservableObject {
    @Published private(set) var microphoneStatus: PermissionStatus = .notDetermined
    @Published private(set) var speechStatus: PermissionStatus = .notDetermined

    var allGranted: Bool {
        microphoneStatus == .granted && speechStatus == .granted
    }

    init() {
        refreshStatus()
    }

    func refreshStatus() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: microphoneStatus = .notDetermined
        case .denied: microphoneStatus = .denied
        case .restricted: microphoneStatus = .restricted
        case .authorized: microphoneStatus = .granted
        @unknown default: microphoneStatus = .notDetermined
        }

        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined: speechStatus = .notDetermined
        case .denied: speechStatus = .denied
        case .restricted: speechStatus = .restricted
        case .authorized: speechStatus = .granted
        @unknown default: speechStatus = .notDetermined
        }
    }

    /// 依次请求麦克风与语音识别权限，全部完成后刷新状态。
    func requestAll() async {
        if microphoneStatus != .granted {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        if speechStatus != .granted {
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { _ in
                    continuation.resume()
                }
            }
        }
        refreshStatus()
    }

    /// 权限不可用时的引导文案（例如被拒绝后的提示）。
    var denialHint: String? {
        if microphoneStatus == .denied {
            return "麦克风权限被拒绝，请在 系统设置 → 隐私与安全性 → 麦克风 中允许本应用。"
        }
        if speechStatus == .denied {
            return "语音识别权限被拒绝，请在 系统设置 → 隐私与安全性 → 语音识别 中允许本应用。"
        }
        return nil
    }
}
