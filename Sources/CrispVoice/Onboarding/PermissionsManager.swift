import AppKit
import ApplicationServices
import AVFoundation
import Speech

enum PermissionsManager {
    static func hasAccessibility() -> Bool {
        let trusted = AXIsProcessTrusted()
        DebugLog.write("PermissionsManager.hasAccessibility trusted=\(trusted)")
        return trusted
    }

    static func requestAccessibility() {
        DebugLog.write("PermissionsManager.requestAccessibility prompting")
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func requestMicrophone() async -> Bool {
        let granted: Bool

        if #available(macOS 14.0, *) {
            granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        } else {
            granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        }

        DebugLog.write("PermissionsManager.requestMicrophone granted=\(granted)")
        return granted
    }

    static func requestSpeechRecognition() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                DebugLog.write("PermissionsManager.requestSpeechRecognition status=\(status.rawValue)")
                continuation.resume(returning: status)
            }
        }
    }

    static func openAccessibilitySettings() {
        DebugLog.write("PermissionsManager.openAccessibilitySettings")
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
