import Foundation
import ApplicationServices
import CoreGraphics

enum PasswordAutotyperError: LocalizedError {
    case permissionDenied
    case invalidEncoding
    case eventSourceFailed
    case eventCreationFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Accessibility permission was not granted to this signed FaceLock build."
        case .invalidEncoding:
            return "The password could not be decoded for HID-style typing."
        case .eventSourceFailed:
            return "macOS would not create a HID system event source."
        case .eventCreationFailed:
            return "macOS would not create a keyboard event."
        }
    }
}

/// Uses the same shape as HasBrain/FaceUnlock's working injector: a HID-system
/// event source, one Unicode character per key event, and short key timing gaps.
struct PasswordAutotyper {
    private static let keyInterval: TimeInterval = 0.004

    static func requestPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func typePasswordAndSubmit(_ passwordData: inout Data) throws {
        guard AXIsProcessTrusted() else { throw PasswordAutotyperError.permissionDenied }
        defer { passwordData.resetBytes(in: passwordData.indices) }
        guard let password = String(data: passwordData, encoding: .utf8) else {
            throw PasswordAutotyperError.invalidEncoding
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw PasswordAutotyperError.eventSourceFailed
        }

        for character in password {
            try postUnicode(String(character), source: source)
        }
        try postReturn(source: source)
    }

    private func postUnicode(_ character: String, source: CGEventSource) throws {
        let utf16 = Array(character.utf16)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            throw PasswordAutotyperError.eventCreationFailed
        }
        utf16.withUnsafeBufferPointer { buffer in
            guard let address = buffer.baseAddress else { return }
            keyDown.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: address)
            keyUp.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: address)
        }
        keyDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: Self.keyInterval)
        keyUp.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: Self.keyInterval)
    }

    private func postReturn(source: CGEventSource) throws {
        let returnKey: CGKeyCode = 0x24
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false) else {
            throw PasswordAutotyperError.eventCreationFailed
        }
        keyDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: Self.keyInterval)
        keyUp.post(tap: .cghidEventTap)
    }
}
