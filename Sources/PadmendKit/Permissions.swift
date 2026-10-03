import ApplicationServices
import Foundation
import IOKit.hid

public enum Permission: Sendable {
    case granted
    case denied
    case unknown

    public var symbol: String {
        switch self {
        case .granted: return "\u{1B}[32mgranted\u{1B}[0m"
        case .denied: return "\u{1B}[31mnot granted\u{1B}[0m"
        case .unknown: return "unknown"
        }
    }
}

public enum Permissions {
    /// Needed to create the event tap that suppresses the trackpad's own input.
    public static var accessibility: Permission {
        AXIsProcessTrusted() ? .granted : .denied
    }

    /// Needed to read the raw contact stream.
    ///
    /// Note that both permissions are granted to the binary that asks, which
    /// for a command-line tool means the terminal it was launched from. The
    /// same build run from a different terminal, or from an app bundle, is a
    /// different subject as far as the system is concerned.
    public static var inputMonitoring: Permission {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .unknown
        }
    }

    public static func requestAccessibility() {
        // The constant is imported as a mutable global, which Swift 6 will
        // not let a concurrent context touch; the string it holds is stable.
        let key = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    @discardableResult
    public static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }
}
