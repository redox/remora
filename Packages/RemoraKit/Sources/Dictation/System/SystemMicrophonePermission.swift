import AVFoundation

/// Microphone authorization through `AVCaptureDevice` (what `AVAudioEngine` input is gated by).
public struct SystemMicrophonePermission: MicrophonePermission {
    public init() {}

    public func status() -> MicrophoneStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    public func request() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}
